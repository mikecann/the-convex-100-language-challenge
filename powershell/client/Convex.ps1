# This educational client implements Convex's documented JSON HTTP API and the
# pinned unversioned /api/sync profile directly in PowerShell. .NET supplies
# ordinary HTTP, TLS, JSON, and WebSocket primitives only.
Set-StrictMode -Version Latest

$script:ConvexJsonDepth = 64
$script:ConvexMaxHttpBytes = 8MB
$script:ConvexHttpReadBufferBytes = 16KB
$script:ConvexHttpTimeoutMilliseconds = 30000
$script:ConvexMaxLiveBytes = 4MB
$script:ConvexPerSubscriptionItems = 16
$script:ConvexGlobalQueueItems = 64
$script:ConvexGlobalQueueBytes = 8MB
$script:ConvexQueueItemOverhead = 512
# One cumulative, cancellable budget covers everything the sole owner does for a
# single operation: DNS, TCP connect, TLS, the 101 upgrade, the initial Connect
# frame, and the replayed ModifyQuerySet. Separate per-step timeouts would let a
# slow peer consume a multiple of this budget and delay the next control command.
$script:ConvexOwnerDeadlineMilliseconds = 3000
# The caller's cumulative acknowledgement budget. It is deliberately longer than
# the owner budget so a stalled peer surfaces as a structured owner failure
# rather than as a bare caller timeout.
$script:ConvexControlTimeoutMilliseconds = 4000
# An absolute deadline for assembling one WebSocket message, armed by its first
# byte. It is never extended by later fragments, so a peer that dribbles bytes
# forever fails exactly like a peer that stops halfway through a frame. Against
# the 4 MiB frame cap it asks for roughly 820 KiB/s, so a legal maximum message
# still arrives comfortably while an endless trickle cannot outlast it. Commands
# are polled between fragments, so this budget never delays close or unsubscribe.
$script:ConvexMessageDeadlineMilliseconds = 5000

function ConvertTo-ConvexJson {
    param([Parameter(Mandatory)] $Value)
    $Value | ConvertTo-Json -Depth $script:ConvexJsonDepth -Compress
}

function ConvertFrom-ConvexJson {
    param([Parameter(Mandatory)][string] $Text)
    # The built-in ConvertFrom-Json cmdlet silently substitutes U+FFFD for an
    # unpaired UTF-16 surrogate that decoded out of a \uXXXX escape. That would
    # let a lone-surrogate adapter command id slip past the surrogate-pair walk
    # in Assert-AdapterCommand as a valid (replaced) character instead of
    # failing it as a structured ProtocolError. Route through the same
    # System.Text.Json parser already used for HTTP bodies (ConvertFrom-ConvexJsonBytes),
    # which preserves an ill-formed lone surrogate exactly as decoded.
    $document = [Text.Json.JsonDocument]::Parse($Text)
    try {
        ConvertFrom-ConvexJsonElement $document.RootElement
    }
    finally {
        $document.Dispose()
    }
}

function ConvertFrom-ConvexJsonElement {
    param([Parameter(Mandatory)][Text.Json.JsonElement] $Element)
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = @{}
            foreach ($property in $Element.EnumerateObject()) {
                $value[$property.Name] = ConvertFrom-ConvexJsonElement $property.Value
            }
            return $value
        }
        'Array' {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-ConvexJsonElement $item))
            }
            return , ([object[]]$items.ToArray())
        }
        'String' { return $Element.GetString() }
        'Number' {
            [int64]$integer = 0
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            [decimal]$decimal = 0
            if ($Element.TryGetDecimal([ref]$decimal)) { return $decimal }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw "unsupported JSON value kind $($Element.ValueKind)" }
    }
}

function ConvertFrom-ConvexJsonBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [int] $Length = $Bytes.Length
    )
    $document = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($Bytes, 0, $Length))
    try {
        ConvertFrom-ConvexJsonElement $document.RootElement
    }
    finally {
        $document.Dispose()
    }
}

function Read-ConvexHttpBody {
    param(
        [Parameter(Mandatory)][Net.Http.HttpContent] $Content,
        [Parameter(Mandatory)][Threading.CancellationToken] $CancellationToken
    )
    $declaredLength = $Content.Headers.ContentLength
    if ($null -ne $declaredLength -and $declaredLength -gt $script:ConvexMaxHttpBytes) {
        Throw-ConvexError (
            New-ConvexError -Name TransportError -Message 'Convex HTTP response exceeds 8 MiB'
        )
    }

    $input = $null
    $output = [IO.MemoryStream]::new()
    try {
        $input = $Content.ReadAsStreamAsync($CancellationToken).GetAwaiter().GetResult()
        [byte[]]$buffer = [byte[]]::new($script:ConvexHttpReadBufferBytes)
        while ($true) {
            $read = $input.ReadAsync(
                $buffer,
                0,
                $buffer.Length,
                $CancellationToken
            ).GetAwaiter().GetResult()
            if ($read -eq 0) {
                break
            }
            if (($output.Length + $read) -gt $script:ConvexMaxHttpBytes) {
                Throw-ConvexError (
                    New-ConvexError -Name TransportError -Message 'Convex HTTP response exceeds 8 MiB'
                )
            }
            $output.Write($buffer, 0, $read)
        }
        [pscustomobject]@{
            Bytes  = $output.GetBuffer()
            Length = [int]$output.Length
        }
    }
    finally {
        if ($null -ne $input) {
            $input.Dispose()
        }
        $output.Dispose()
    }
}

function Test-ConvexHttpSuccessStatus {
    param([int] $StatusCode)
    $StatusCode -ge 200 -and $StatusCode -lt 300
}

# A body that never identified itself as a Convex envelope cannot be judged a
# protocol violation when the peer also returned a failing status: a proxy error
# page on 502 is a transport fault, not a Convex one. Report the status in that
# case and keep ProtocolError for unparseable bodies that arrived on 2xx, where
# the peer claimed success and then failed to speak the protocol.
function Throw-ConvexHttpBodyError {
    param([string] $Operation, [int] $StatusCode, [string] $Message)
    if (Test-ConvexHttpSuccessStatus $StatusCode) {
        Throw-ConvexError (
            New-ConvexError -Name ProtocolError -Message $Message -Operation $Operation
        )
    }
    Throw-ConvexError (
        New-ConvexError -Name TransportError -Message "Convex HTTP request failed with status $StatusCode" -Operation $Operation
    )
}

# Convex reports a failed function as a complete error envelope carried on a
# non-2xx status: 560 for a developer error, and 400 or 500 for other server
# rejections. Classifying on the status first would discard errorData and
# logLines and mislabel an ordinary function failure as a transport fault, so
# the envelope is always parsed before the status is consulted. The status then
# decides only what the envelope itself cannot: a body that is not a Convex
# envelope at all, and a body that contradicts the status by claiming success.
function ConvertFrom-ConvexHttpEnvelope {
    param($Decoded, [string] $Operation, [int] $StatusCode = 200)
    if ($Decoded -isnot [hashtable]) {
        Throw-ConvexHttpBodyError $Operation $StatusCode "Convex $Operation response root must be an object"
    }
    if (-not $Decoded.ContainsKey('status') -or $Decoded['status'] -isnot [string]) {
        Throw-ConvexHttpBodyError $Operation $StatusCode "Convex $Operation response status must be a string"
    }
    if ($Decoded['status'] -notin @('success', 'error')) {
        Throw-ConvexHttpBodyError $Operation $StatusCode "Convex $Operation response had unexpected status"
    }

    # Past this point the body is a recognizable Convex envelope, so a remaining
    # violation is a protocol fault in its own right and the HTTP status no
    # longer changes the classification. A broken backend returning a malformed
    # error envelope on 560 must not be laundered into a transport failure.
    #
    # Append into a list rather than growing a [string[]] one element at a time.
    # A near-8 MiB body can declare hundreds of thousands of log lines, and
    # repeated array reallocation would cost quadratic copying inside the final
    # adapter's 128 MiB cgroup.
    $logLines = [Collections.Generic.List[string]]::new()
    if ($Decoded.ContainsKey('logLines')) {
        if ($Decoded['logLines'] -isnot [array]) {
            Throw-ConvexError (
                New-ConvexError -Name ProtocolError -Message "Convex $Operation response logLines must be an array" -Operation $Operation
            )
        }
        foreach ($line in $Decoded['logLines']) {
            if ($line -isnot [string]) {
                Throw-ConvexError (
                    New-ConvexError -Name ProtocolError -Message "Convex $Operation response logLines must contain strings" -Operation $Operation
                )
            }
            $logLines.Add($line)
        }
    }
    [string[]]$logs = $logLines.ToArray()

    if ($Decoded['status'] -eq 'error') {
        if (-not $Decoded.ContainsKey('errorMessage') -or $Decoded['errorMessage'] -isnot [string]) {
            Throw-ConvexError (
                New-ConvexError -Name ProtocolError -Message "Convex $Operation error response requires a string errorMessage" -Operation $Operation
            )
        }
        $errorData = if ($Decoded.ContainsKey('errorData')) { $Decoded['errorData'] } else { $null }
        Throw-ConvexError (
            New-ConvexError -Name FunctionError -Message $Decoded['errorMessage'] -Data $errorData -Logs $logs -Operation $Operation
        )
    }

    # A success envelope contradicts a failing status. Trust the status: the
    # body most likely came from something other than the function that was
    # called, so it must never be handed back as a value.
    if (-not (Test-ConvexHttpSuccessStatus $StatusCode)) {
        Throw-ConvexError (
            New-ConvexError -Name TransportError -Message "Convex HTTP request failed with status $StatusCode" -Operation $Operation
        )
    }
    if (-not $Decoded.ContainsKey('value')) {
        Throw-ConvexError (
            New-ConvexError -Name ProtocolError -Message "Convex $Operation success response omitted value" -Operation $Operation
        )
    }
    [pscustomobject]@{ Value = $Decoded['value']; Logs = [string[]]$logs }
}

function New-ConvexError {
    param(
        [ValidateSet('FunctionError', 'ProtocolError', 'TransportError', 'ClosedError')][string] $Name,
        [string] $Message,
        $Data,
        [string[]] $Logs = @(),
        [string] $Operation = ''
    )
    [pscustomobject]@{
        Name      = $Name
        Message   = $Message
        Data      = $Data
        Logs      = [string[]]@($Logs)
        Operation = $Operation
    }
}

function Throw-ConvexError {
    param($Error)
    $exception = [System.Exception]::new($Error.Message)
    $exception.Data['convex'] = $Error
    throw $exception
}

function Get-ConvexError {
    param([Parameter(Mandatory)] $Exception, [string] $Operation = '')
    if ($Exception.Data.Contains('convex')) {
        return $Exception.Data['convex']
    }
    New-ConvexError -Name TransportError -Message $Exception.Message -Operation $Operation
}

function Assert-ConvexPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -lt 3) {
        Throw-ConvexError (New-ConvexError -Name ProtocolError -Message 'Convex function path is required')
    }
}

function New-ConvexClient {
    param(
        [Parameter(Mandatory)][string] $DeploymentUrl,
        [string] $ClientVersion = 'powershell-0.2.0'
    )
    $uri = $null
    if (
        -not [uri]::TryCreate($DeploymentUrl.TrimEnd('/'), [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)
    ) {
        Throw-ConvexError (
            New-ConvexError -Name ProtocolError -Message 'Convex deployment URL must be an absolute http(s) URL without user info'
        )
    }
    $http = [System.Net.Http.HttpClient]::new()
    # ResponseHeadersRead makes HttpClient.Timeout stop at the headers. Keep one
    # explicit cancellation deadline across headers and every body read instead.
    $http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    [pscustomobject]@{
        Url                     = $uri.AbsoluteUri.TrimEnd('/')
        Token                   = ''
        Version                 = $ClientVersion
        Closed                  = $false
        Http                    = $http
        HttpTimeoutMilliseconds = $script:ConvexHttpTimeoutMilliseconds
    }
}

function Set-ConvexAuth {
    param($Client, [AllowEmptyString()][string] $Token)
    $Client.Token = $Token
}

function Close-ConvexClient {
    param($Client)
    if (-not $Client.Closed) {
        $Client.Closed = $true
        $Client.Http.Dispose()
    }
}

function Invoke-ConvexFunction {
    param(
        [Parameter(Mandatory)] $Client,
        [ValidateSet('query', 'mutation', 'action')][string] $Operation,
        [Parameter(Mandatory)][string] $Path,
        [hashtable] $FunctionArgs = @{},
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    if ($Client.Closed) {
        Throw-ConvexError (New-ConvexError -Name ClosedError -Message 'Convex client is closed')
    }
    Assert-ConvexPath $Path
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "$($Client.Url)/api/$Operation"
    )
    $request.Headers.TryAddWithoutValidation('Convex-Client', $Client.Version) | Out-Null
    if ($Client.Token) {
        $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Client.Token)") | Out-Null
    }
    $body = ConvertTo-ConvexJson @{ path = $Path; args = $FunctionArgs; format = 'json' }
    $request.Content = [System.Net.Http.StringContent]::new(
        $body,
        [System.Text.Encoding]::UTF8,
        'application/json'
    )
    $response = $null
    $statusCode = 0
    $decoded = $null
    $deadline = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    try {
        $deadline.CancelAfter([int]$Client.HttpTimeoutMilliseconds)
        $response = $Client.Http.Send(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $deadline.Token
        )
        # The status is captured but not acted on yet. Convex carries a complete
        # function-error envelope on 560, 500, and 400, so the body is read and
        # parsed first and the status only classifies what the body cannot. The
        # 8 MiB streaming bound below applies to failing responses too, so a
        # hostile error body is no cheaper to send than a successful one.
        $statusCode = [int]$response.StatusCode
        $bodyBytes = Read-ConvexHttpBody $response.Content $deadline.Token
        # Parse UTF-8 directly. Converting an 8 MiB response to one giant
        # UTF-16 string first would duplicate the payload inside the final
        # adapter's 128 MiB cgroup before the result can be emitted.
        try {
            $decoded = ConvertFrom-ConvexJsonBytes $bodyBytes.Bytes $bodyBytes.Length
        }
        catch {
            Throw-ConvexHttpBodyError $Operation $statusCode "Convex $Operation response was not valid JSON: $($_.Exception.Message)"
        }
    }
    catch [OperationCanceledException] {
        $message = if ($CancellationToken.IsCancellationRequested) {
            'Convex HTTP request was cancelled'
        }
        else {
            'Convex HTTP request exceeded its deadline'
        }
        Throw-ConvexError (New-ConvexError -Name TransportError -Message $message -Operation $Operation)
    }
    catch {
        Throw-ConvexError (Get-ConvexError $_.Exception $Operation)
    }
    finally {
        $request.Dispose()
        if ($null -ne $response) {
            $response.Dispose()
        }
        $deadline.Dispose()
    }
    ConvertFrom-ConvexHttpEnvelope $decoded $Operation $statusCode
}

function Get-ConvexQuery {
    param(
        $Client,
        [string] $Path,
        [hashtable] $FunctionArgs = @{},
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    Invoke-ConvexFunction -Client $Client -Operation query -Path $Path -FunctionArgs $FunctionArgs -CancellationToken $CancellationToken
}

function Invoke-ConvexMutation {
    param(
        $Client,
        [string] $Path,
        [hashtable] $FunctionArgs = @{},
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    Invoke-ConvexFunction -Client $Client -Operation mutation -Path $Path -FunctionArgs $FunctionArgs -CancellationToken $CancellationToken
}

function Invoke-ConvexAction {
    param(
        $Client,
        [string] $Path,
        [hashtable] $FunctionArgs = @{},
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    Invoke-ConvexFunction -Client $Client -Operation action -Path $Path -FunctionArgs $FunctionArgs -CancellationToken $CancellationToken
}

function New-ConvexLiveState {
    param(
        [Parameter(Mandatory)][string] $DeploymentUrl,
        [string] $ClientVersion = 'powershell-0.2.0'
    )
    $uri = $null
    if (
        -not [uri]::TryCreate($DeploymentUrl.TrimEnd('/'), [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -notin @('http', 'https')
    ) {
        Throw-ConvexError (New-ConvexError -Name ProtocolError -Message 'Live deployment URL must use http or https')
    }
    $scheme = if ($uri.Scheme -eq 'https') { 'wss' } else { 'ws' }
    $endpoint = "${scheme}://$($uri.Authority)$($uri.AbsolutePath.TrimEnd('/'))/api/sync"
    [pscustomobject]@{
        Endpoint                  = $endpoint
        Version                   = $ClientVersion
        Commands                  = [System.Collections.Concurrent.BlockingCollection[object]]::new(128)
        Subscriptions             = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        QueueGate                 = [object]::new()
        PendingCount              = 0
        PendingBytes              = 0L
        NextSequence              = 0L
        Closed                    = $false
        Worker                    = $null
        NextQueryId               = 0
        ConnectionCount           = 0
        LastCloseReason           = 'InitialConnect'
        MaxObservedTimestamp      = $null
        MaxObservedTimestampValue = $null
        Owner                     = [pscustomobject]@{
            Socket              = $null
            Version             = @{ querySet = 0; identity = 0; ts = 'AAAAAAAAAAA=' }
            QuerySet            = 0
            BackoffMilliseconds = 100
            NextConnectAt       = [datetime]::UtcNow
            ReceiveTask         = $null
            Frame               = [IO.MemoryStream]::new()
            # Absolute expiry for the message currently being assembled in Frame.
            MessageDeadline     = $null
            # One receive holds a whole ordinary transition, so a near-maximum
            # frame assembles in tens of fragments rather than a thousand. The
            # per-message deadline below has to be achievable for legal frames.
            Buffer              = [byte[]]::new(64KB)
            # Adapter-only disconnect uses this barrier to acknowledge only after
            # every active query has applied its replacement-socket hydration.
            HydrationQueryIds   = [System.Collections.Generic.HashSet[uint32]]::new()
            HydrationApplied    = [Threading.ManualResetEventSlim]::new($true)
        }
    }
}

$script:ConvexLiveWorker = {
    param(
        $State,
        $PerSubscriptionItems,
        $GlobalQueueItems,
        $GlobalQueueBytes,
        $QueueItemOverhead,
        $MaxFrameBytes,
        $OwnerDeadlineMilliseconds,
        $MessageDeadlineMilliseconds
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function ConvertFrom-LiveJsonElement {
        param([Parameter(Mandatory)][Text.Json.JsonElement] $Element)
        switch ($Element.ValueKind.ToString()) {
            'Object' {
                $value = @{}
                foreach ($property in $Element.EnumerateObject()) {
                    $value[$property.Name] = ConvertFrom-LiveJsonElement $property.Value
                }
                return $value
            }
            'Array' {
                $items = [Collections.Generic.List[object]]::new()
                foreach ($item in $Element.EnumerateArray()) {
                    $items.Add((ConvertFrom-LiveJsonElement $item))
                }
                return , ([object[]]$items.ToArray())
            }
            'String' { return $Element.GetString() }
            'Number' {
                [int64]$integer = 0
                if ($Element.TryGetInt64([ref]$integer)) {
                    return $integer
                }
                [decimal]$decimal = 0
                if ($Element.TryGetDecimal([ref]$decimal)) {
                    return $decimal
                }
                return $Element.GetDouble()
            }
            'True' { return $true }
            'False' { return $false }
            'Null' { return $null }
            default { throw "unsupported JSON value kind $($Element.ValueKind)" }
        }
    }

    function ConvertFrom-LiveJsonBytes([byte[]] $Bytes, [int] $Length) {
        # Parse the bounded WebSocket frame directly as UTF-8. A whole-frame
        # UTF-16 string doubles transient memory and can cross the adapter's
        # 128 MiB cgroup even for an ordinary hosted Transition.
        $document = [Text.Json.JsonDocument]::Parse(
            [ReadOnlyMemory[byte]]::new($Bytes, 0, $Length)
        )
        try {
            ConvertFrom-LiveJsonElement $document.RootElement
        }
        finally {
            $document.Dispose()
        }
    }

    function ConvertTo-ConvexUInt32($Value, [string] $Label) {
        if ($Value -is [bool] -or $Value -isnot [ValueType]) {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be an unsigned 32-bit integer")
        }
        try {
            $decimal = [decimal]$Value
        }
        catch {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be an unsigned 32-bit integer")
        }
        if (
            $decimal -ne [math]::Truncate($decimal) -or
            $decimal -lt 0 -or
            $decimal -gt [decimal][uint32]::MaxValue
        ) {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be an unsigned 32-bit integer")
        }
        [uint32]$decimal
    }

    function ConvertFrom-ConvexTimestamp([string] $Timestamp, [string] $Label) {
        if ([string]::IsNullOrEmpty($Timestamp) -or $Timestamp.Length -ne 12) {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be canonical base64 for eight timestamp bytes")
        }
        try {
            $bytes = [Convert]::FromBase64String($Timestamp)
        }
        catch {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be canonical base64 for eight timestamp bytes")
        }
        if ($bytes.Length -ne 8 -or [Convert]::ToBase64String($bytes) -cne $Timestamp) {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be canonical base64 for eight timestamp bytes")
        }
        [uint64]$value = 0
        for ($index = 0; $index -lt 8; $index++) {
            $value = $value -bor ([uint64]$bytes[$index] -shl (8 * $index))
        }
        $value
    }

    function ConvertTo-ConvexVersion($Value, [string] $Label) {
        if ($Value -isnot [hashtable]) {
            throw (New-WorkerFailure 'ProtocolError' "$Label must be an object")
        }
        foreach ($field in @('querySet', 'identity', 'ts')) {
            if (-not $Value.ContainsKey($field)) {
                throw (New-WorkerFailure 'ProtocolError' "$Label omitted $field")
            }
        }
        $timestamp = [string]$Value['ts']
        @{
            querySet       = ConvertTo-ConvexUInt32 $Value['querySet'] "$Label querySet"
            identity       = ConvertTo-ConvexUInt32 $Value['identity'] "$Label identity"
            ts             = $timestamp
            timestampValue = ConvertFrom-ConvexTimestamp $timestamp "$Label ts"
        }
    }

    function New-ZeroVersion {
        ConvertTo-ConvexVersion @{ querySet = 0; identity = 0; ts = 'AAAAAAAAAAA=' } 'zero version'
    }

    function Test-SameVersion($Left, $Right) {
        $Left -is [hashtable] -and
        $Right -is [hashtable] -and
        $Left['querySet'] -eq $Right['querySet'] -and
        $Left['identity'] -eq $Right['identity'] -and
        $Left['ts'] -eq $Right['ts']
    }

    function New-WorkerFailure([string] $Kind, [string] $Message) {
        $failure = [System.Exception]::new($Message)
        $failure.Data['convexKind'] = $Kind
        $failure
    }

    function New-OwnerDeadline {
        # A background reconnect has no caller to abandon it, so it owns the same
        # cumulative budget on its own cancellation source.
        $source = [Threading.CancellationTokenSource]::new()
        $source.CancelAfter($OwnerDeadlineMilliseconds)
        $source
    }

    function Send-Frame($Value, $Deadline) {
        $socket = $State.Owner.Socket
        if ($null -eq $socket) {
            throw (New-WorkerFailure 'TransportError' 'Live WebSocket is not connected')
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress))
        try {
            # No private timeout here. The send spends whatever remains of the
            # operation's one cumulative deadline.
            $socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                $Deadline.Token
            ).GetAwaiter().GetResult() | Out-Null
        }
        catch {
            throw (New-WorkerFailure 'TransportError' "Live send failed: $($_.Exception.Message)")
        }
    }

    function Clear-RecordQueue($Record) {
        while ($Record.Updates.Count -gt 0) {
            $removed = $Record.Updates.Dequeue()
            $State.PendingCount--
            $State.PendingBytes -= $removed.Bytes
        }
        $Record.QueuedBytes = 0L
    }

    function Remove-OldestGlobalUpdate {
        $oldestRecord = $null
        $oldestSequence = [long]::MaxValue
        foreach ($candidate in $State.Subscriptions.Values) {
            if ($candidate.Updates.Count -gt 0) {
                $sequence = $candidate.Updates.Peek().Sequence
                if ($sequence -lt $oldestSequence) {
                    $oldestSequence = $sequence
                    $oldestRecord = $candidate
                }
            }
        }
        if ($null -eq $oldestRecord) {
            return $false
        }
        $removed = $oldestRecord.Updates.Dequeue()
        $oldestRecord.QueuedBytes -= $removed.Bytes
        $State.PendingCount--
        $State.PendingBytes -= $removed.Bytes
        $true
    }

    function Offer-Update($Record, [hashtable] $Update, [bool] $ResetDedupe) {
        $encodedBytes = [Text.Encoding]::UTF8.GetByteCount(($Update | ConvertTo-Json -Depth 64 -Compress))
        $accountedBytes = [long]$encodedBytes + $QueueItemOverhead
        [Threading.Monitor]::Enter($State.QueueGate)
        try {
            if (-not $Record.Active) {
                return
            }
            if ($ResetDedupe) {
                $Record.LastValue = $null
            }
            if ($Update.ContainsKey('value')) {
                $canonical = $Update['value'] | ConvertTo-Json -Depth 64 -Compress
                if ($Record.LastValue -eq $canonical) {
                    return
                }
                $Record.LastValue = $canonical
            }
            while ($Record.Updates.Count -ge $PerSubscriptionItems) {
                $removed = $Record.Updates.Dequeue()
                $Record.QueuedBytes -= $removed.Bytes
                $State.PendingCount--
                $State.PendingBytes -= $removed.Bytes
            }
            while (
                $State.PendingCount -ge $GlobalQueueItems -or
                ($State.PendingBytes + $accountedBytes) -gt $GlobalQueueBytes
            ) {
                if (-not (Remove-OldestGlobalUpdate)) {
                    break
                }
            }
            if ($accountedBytes -gt $GlobalQueueBytes) {
                return
            }
            $State.NextSequence++
            $entry = [pscustomobject]@{
                Bytes    = $accountedBytes
                Sequence = $State.NextSequence
                Event    = $Update
            }
            $Record.Updates.Enqueue($entry)
            $Record.QueuedBytes += $accountedBytes
            $State.PendingCount++
            $State.PendingBytes += $accountedBytes
        }
        finally {
            [Threading.Monitor]::Exit($State.QueueGate)
        }
    }

    function Emit-Failure([string] $Kind, [string] $Message) {
        foreach ($record in $State.Subscriptions.Values) {
            Offer-Update $record @{ error = @{ name = $Kind; message = $Message }; logs = [string[]]@() } $true
        }
    }

    function Retire-Socket(
        [string] $Reason,
        [string] $FailureKind,
        [string] $FailureMessage,
        [bool] $Intentional
    ) {
        $oldSocket = $State.Owner.Socket
        $oldReceive = $State.Owner.ReceiveTask
        # Every mutable owner field lives on State.Owner. Nested PowerShell
        # functions therefore cannot accidentally shadow the socket or parser state.
        $State.Owner.Socket = $null
        $State.Owner.ReceiveTask = $null
        $State.Owner.Frame.SetLength(0)
        $State.Owner.MessageDeadline = $null
        $State.Owner.Version = New-ZeroVersion
        $State.Owner.QuerySet = 0
        if ($null -ne $oldSocket) {
            try { $oldSocket.Abort() } catch {}
            if ($null -ne $oldReceive) {
                try { $oldReceive.Wait(500) | Out-Null } catch {}
            }
            $oldSocket.Dispose()
            # Disposal already closed the transport. Hint that the retired
            # wrappers are collectable, but never block and never wait on
            # finalizers: this runs inside a caller's cumulative deadline, and an
            # unbounded pause here would silently spend someone else's budget.
            [GC]::Collect(2, [GCCollectionMode]::Optimized, $false, $false)
            $State.ConnectionCount++
        }
        $State.LastCloseReason = $Reason
        if (-not $Intentional -and $FailureKind) {
            Emit-Failure $FailureKind $FailureMessage
        }
        $State.Owner.NextConnectAt = [datetime]::UtcNow.AddMilliseconds($State.Owner.BackoffMilliseconds)
        $State.Owner.BackoffMilliseconds = [Math]::Min($State.Owner.BackoffMilliseconds * 2, 15000)
    }

    function Assert-MessageDeadline {
        # The deadline is absolute, so a peer that keeps trickling bytes cannot
        # postpone it. Failing here retires the socket, publishes a structured
        # TransportError, and lets the ordinary reconnect replay the active Adds.
        if (
            $State.Owner.Frame.Length -gt 0 -and
            $null -ne $State.Owner.MessageDeadline -and
            [datetime]::UtcNow -ge $State.Owner.MessageDeadline
        ) {
            throw (
                New-WorkerFailure 'TransportError' 'Live message assembly exceeded its absolute deadline'
            )
        }
    }

    function Add-Modification($Record) {
        @{
            type    = 'Add'
            queryId = $Record.QueryId
            udfPath = $Record.Path
            args    = @($Record.FunctionArgs)
        }
    }

    function Send-Modify([object[]] $Changes, $Deadline) {
        if ($Changes.Count -eq 0) {
            return
        }
        if ([uint64]$State.Owner.QuerySet -ge [uint64][uint32]::MaxValue) {
            throw (New-WorkerFailure 'ProtocolError' 'Live query-set version exceeded uint32 range')
        }
        $newVersion = [uint32]([uint64]$State.Owner.QuerySet + 1)
        Send-Frame @{
            type          = 'ModifyQuerySet'
            baseVersion   = $State.Owner.QuerySet
            newVersion    = $newVersion
            modifications = @($Changes)
        } $Deadline
        $State.Owner.QuerySet = $newVersion
    }

    function Connect-Socket($Deadline) {
        $candidate = [Net.WebSockets.ClientWebSocket]::new()
        # HttpListener and several WebSocket proxies require an explicit offered
        # protocol. Convex may either select it or leave the response unnegotiated.
        $candidate.Options.AddSubProtocol('convex-1.0.0')
        $candidate.Options.SetRequestHeader('Convex-Client', $State.Version)
        try {
            # DNS, TCP, TLS, and the 101 upgrade all draw on the same budget the
            # Connect and ModifyQuerySet frames below must still fit inside.
            $candidate.ConnectAsync([Uri]$State.Endpoint, $Deadline.Token).GetAwaiter().GetResult() | Out-Null
        }
        catch {
            $candidate.Dispose()
            throw (New-WorkerFailure 'TransportError' "Live connect failed: $($_.Exception.Message)")
        }
        $State.Owner.Socket = $candidate
        $State.Owner.Version = New-ZeroVersion
        $State.Owner.QuerySet = 0
        $State.Owner.BackoffMilliseconds = 100
        $connect = @{
            type            = 'Connect'
            sessionId       = [guid]::NewGuid().ToString()
            connectionCount = [uint32]$State.ConnectionCount
            lastCloseReason = $State.LastCloseReason
            clientTs        = 0
        }
        if ($null -ne $State.MaxObservedTimestamp) {
            $connect['maxObservedTimestamp'] = $State.MaxObservedTimestamp
        }
        Send-Frame $connect $Deadline
        [object[]] $adds = @(
            $State.Subscriptions.Values |
                Sort-Object QueryId |
                ForEach-Object { Add-Modification $_ }
        )
        Send-Modify $adds $Deadline
    }

    function Validate-Transition([hashtable] $Message) {
        if ($Message['type'] -ne 'Transition') {
            throw (New-WorkerFailure 'ProtocolError' "unsupported Live message $($Message['type'])")
        }
        if (-not $Message.ContainsKey('startVersion') -or -not $Message.ContainsKey('endVersion')) {
            throw (New-WorkerFailure 'ProtocolError' 'Live transition omitted a version')
        }
        $startVersion = ConvertTo-ConvexVersion $Message['startVersion'] 'startVersion'
        if (-not (Test-SameVersion $startVersion $State.Owner.Version)) {
            throw (New-WorkerFailure 'ProtocolError' 'invalid or out-of-order Live transition')
        }
        $endVersion = ConvertTo-ConvexVersion $Message['endVersion'] 'endVersion'
        if (
            $endVersion['querySet'] -lt $startVersion['querySet'] -or
            $endVersion['identity'] -lt $startVersion['identity'] -or
            $endVersion['timestampValue'] -lt $startVersion['timestampValue']
        ) {
            throw (New-WorkerFailure 'ProtocolError' 'Live transition version moved backwards')
        }
        if (-not $Message.ContainsKey('modifications') -or $Message['modifications'] -isnot [array]) {
            throw (New-WorkerFailure 'ProtocolError' 'Live transition modifications must be an array')
        }
        $updates = [System.Collections.Generic.List[object]]::new()
        foreach ($modification in @($Message['modifications'])) {
            if ($modification -isnot [hashtable] -or -not $modification.ContainsKey('type')) {
                throw (New-WorkerFailure 'ProtocolError' 'Live transition contains an invalid modification')
            }
            $kind = [string]$modification['type']
            if ($kind -notin @('QueryRemoved', 'QueryUpdated', 'QueryFailed')) {
                throw (New-WorkerFailure 'ProtocolError' "unsupported Live modification $kind")
            }
            if (-not $modification.ContainsKey('queryId')) {
                throw (New-WorkerFailure 'ProtocolError' "$kind omitted queryId")
            }
            $queryId = ConvertTo-ConvexUInt32 $modification['queryId'] "$kind queryId"
            if ($kind -eq 'QueryRemoved') {
                continue
            }
            $record = @(
                $State.Subscriptions.Values |
                    Where-Object { [uint32]$_.QueryId -eq $queryId } |
                    Select-Object -First 1
            )
            if ($record.Count -eq 0) {
                continue
            }
            [string[]] $logs = @()
            if ($modification.ContainsKey('logLines')) {
                # Match the HTTP envelope exactly. Coercing with [string] would
                # turn a nested object into its type name and publish a
                # schema-invalid log line instead of rejecting the transition.
                if ($modification['logLines'] -isnot [array]) {
                    throw (New-WorkerFailure 'ProtocolError' "$kind logLines must be an array")
                }
                foreach ($line in $modification['logLines']) {
                    if ($line -isnot [string]) {
                        throw (New-WorkerFailure 'ProtocolError' "$kind logLines must contain strings")
                    }
                }
                [string[]] $logs = @($modification['logLines'])
            }
            if ($kind -eq 'QueryUpdated') {
                if (-not $modification.ContainsKey('value')) {
                    throw (New-WorkerFailure 'ProtocolError' 'QueryUpdated omitted value')
                }
                $updates.Add([pscustomobject]@{
                        Record      = $record[0]
                        Update      = @{ value = $modification['value']; logs = [string[]]$logs }
                        ResetDedupe = $false
                    })
            }
            elseif ($kind -eq 'QueryFailed') {
                # A missing or non-string errorMessage is a malformed transition,
                # not a function that failed. Substituting placeholder text would
                # publish a FunctionError the Convex function never raised and
                # hide the protocol defect behind a plausible application error.
                if (
                    -not $modification.ContainsKey('errorMessage') -or
                    $modification['errorMessage'] -isnot [string]
                ) {
                    throw (New-WorkerFailure 'ProtocolError' 'QueryFailed requires a string errorMessage')
                }
                $error = @{ name = 'FunctionError'; message = [string]$modification['errorMessage'] }
                if ($modification.ContainsKey('errorData')) {
                    $error['data'] = $modification['errorData']
                }
                $updates.Add([pscustomobject]@{
                        Record      = $record[0]
                        Update      = @{ error = $error; logs = [string[]]$logs }
                        ResetDedupe = $true
                    })
            }
        }
        [pscustomobject]@{ EndVersion = $endVersion; Updates = $updates }
    }

    function Commit-Transition($Candidate) {
        # No queue or version changes happen until every modification validates.
        $State.Owner.Version = $Candidate.EndVersion
        if (
            $null -eq $State.MaxObservedTimestampValue -or
            $Candidate.EndVersion['timestampValue'] -gt $State.MaxObservedTimestampValue
        ) {
            $State.MaxObservedTimestamp = [string]$Candidate.EndVersion['ts']
            $State.MaxObservedTimestampValue = [uint64]$Candidate.EndVersion['timestampValue']
        }
        $State.Owner.BackoffMilliseconds = 100
        foreach ($candidateUpdate in $Candidate.Updates) {
            Offer-Update $candidateUpdate.Record $candidateUpdate.Update $candidateUpdate.ResetDedupe
            $State.Owner.HydrationQueryIds.Remove([uint32]$candidateUpdate.Record.QueryId) | Out-Null
        }
        if ($State.Owner.HydrationQueryIds.Count -eq 0) {
            $State.Owner.HydrationApplied.Set() | Out-Null
        }
    }

    function Complete-Command($Command, [System.Exception] $Failure) {
        if ($null -ne $Failure) {
            $Command.Failure = $Failure
        }
        if ($null -ne $Command.Done) {
            $Command.Done.Set() | Out-Null
        }
    }

    while (-not $State.Closed) {
        try {
            if (
                $null -eq $State.Owner.Socket -and
                [datetime]::UtcNow -ge $State.Owner.NextConnectAt -and
                $State.Subscriptions.Count -gt 0
            ) {
                $reconnectDeadline = New-OwnerDeadline
                try {
                    Connect-Socket $reconnectDeadline
                }
                finally {
                    $reconnectDeadline.Dispose()
                }
            }

            # Poll idly for commands, but never sleep between the fragments of a
            # message: the assembly deadline must be spent receiving, not
            # waiting on an empty command queue. Commands are still inspected
            # between every fragment, so close and unsubscribe stay bounded while
            # the peer streams.
            $commandWait = if ($State.Owner.Frame.Length -gt 0) { 0 } else { 20 }
            $command = $null
            if ($State.Commands.TryTake([ref]$command, $commandWait)) {
                # The caller already stopped waiting at its cumulative deadline.
                # Failing this command immediately keeps the sole owner available
                # for the control work queued behind it instead of spending a
                # fresh budget on abandoned socket work. Stop is exempt: shutdown
                # must run even when its caller has given up waiting for it.
                if ($command.Kind -ne 'Stop' -and $command.Cancellation.IsCancellationRequested) {
                    Complete-Command $command (
                        New-WorkerFailure 'TransportError' 'Live command was abandoned at its cumulative deadline'
                    )
                    continue
                }
                $commandFailure = $null
                try {
                    switch ($command.Kind) {
                        'Stop' {
                            $State.Closed = $true
                            Retire-Socket 'ClientClosed' '' '' $true
                        }
                        'DebugDisconnect' {
                            Retire-Socket 'DebugDisconnect' '' '' $true
                            $State.Owner.HydrationQueryIds.Clear()
                            foreach ($record in $State.Subscriptions.Values) {
                                $State.Owner.HydrationQueryIds.Add([uint32]$record.QueryId) | Out-Null
                            }
                            $State.Owner.HydrationApplied.Reset()
                            if ($State.Owner.HydrationQueryIds.Count -eq 0) {
                                $State.Owner.HydrationApplied.Set() | Out-Null
                            }
                            else {
                                # Connect synchronously on the sole owner, inside
                                # the caller's own cumulative deadline. Retirement
                                # and reconnect scheduling therefore cannot outlive
                                # the acknowledgement the caller is waiting for.
                                Connect-Socket $command.Cancellation
                            }
                        }
                        'Subscribe' {
                            $changes = [System.Collections.Generic.List[object]]::new()
                            $old = $null
                            if ($State.Subscriptions.TryRemove($command.Record.Id, [ref]$old)) {
                                [Threading.Monitor]::Enter($State.QueueGate)
                                try {
                                    $old.Active = $false
                                    Clear-RecordQueue $old
                                }
                                finally {
                                    [Threading.Monitor]::Exit($State.QueueGate)
                                }
                                $changes.Add(@{ type = 'Remove'; queryId = $old.QueryId })
                            }
                            $State.Subscriptions[$command.Record.Id] = $command.Record
                            $changes.Add((Add-Modification $command.Record))
                            if ($null -ne $State.Owner.Socket) {
                                Send-Modify $changes.ToArray() $command.Cancellation
                            }
                        }
                        'Unsubscribe' {
                            $old = $null
                            if ($State.Subscriptions.TryRemove($command.Id, [ref]$old)) {
                                [Threading.Monitor]::Enter($State.QueueGate)
                                try {
                                    $old.Active = $false
                                    Clear-RecordQueue $old
                                }
                                finally {
                                    [Threading.Monitor]::Exit($State.QueueGate)
                                }
                                if ($null -ne $State.Owner.Socket) {
                                    # Retiring here makes unsubscribe bounded even
                                    # if the peer stopped midway through a frame.
                                    # Remaining subscriptions rehydrate in stable
                                    # query-id order on the replacement socket.
                                    Retire-Socket 'Unsubscribe' '' '' $true
                                    $State.Owner.NextConnectAt = [datetime]::UtcNow.AddMilliseconds(100)
                                }
                            }
                        }
                    }
                }
                catch {
                    $commandFailure = $_.Exception
                    $kind = if ($commandFailure.Data.Contains('convexKind')) {
                        [string]$commandFailure.Data['convexKind']
                    }
                    else {
                        'TransportError'
                    }
                    Retire-Socket $kind $kind $commandFailure.Message $false
                }
                finally {
                    Complete-Command $command $commandFailure
                }
                continue
            }

            if ($null -eq $State.Owner.Socket) {
                continue
            }
            if ($null -eq $State.Owner.ReceiveTask) {
                $State.Owner.ReceiveTask = $State.Owner.Socket.ReceiveAsync(
                    [ArraySegment[byte]]::new($State.Owner.Buffer),
                    [Threading.CancellationToken]::None
                )
            }
            if (-not $State.Owner.ReceiveTask.Wait(1)) {
                # A peer that stops halfway through a frame expires here.
                Assert-MessageDeadline
                continue
            }
            $result = $State.Owner.ReceiveTask.GetAwaiter().GetResult()
            $State.Owner.ReceiveTask = $null
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw (New-WorkerFailure 'TransportError' 'Live peer closed the WebSocket')
            }
            if ($result.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) {
                throw (New-WorkerFailure 'ProtocolError' 'Live server sent a non-text data message')
            }
            if ($State.Owner.Frame.Length -eq 0) {
                # Arm the assembly deadline from the first byte of the message.
                $State.Owner.MessageDeadline = [datetime]::UtcNow.AddMilliseconds($MessageDeadlineMilliseconds)
            }
            $State.Owner.Frame.Write($State.Owner.Buffer, 0, $result.Count)
            if ($State.Owner.Frame.Length -gt $MaxFrameBytes) {
                throw (New-WorkerFailure 'ProtocolError' 'Live frame exceeds 4 MiB')
            }
            if (-not $result.EndOfMessage) {
                # Bytes arriving continuously do not reset the deadline, so an
                # endless dribble expires at the same instant a stall would.
                Assert-MessageDeadline
                continue
            }
            try {
                $message = ConvertFrom-LiveJsonBytes -Bytes $State.Owner.Frame.GetBuffer() -Length ([int]$State.Owner.Frame.Length)
            }
            catch {
                throw (New-WorkerFailure 'ProtocolError' "invalid Live UTF-8 or JSON: $($_.Exception.Message)")
            }
            finally {
                $State.Owner.Frame.SetLength(0)
                $State.Owner.MessageDeadline = $null
            }
            # A byte-native parse accepts any JSON root. Reject non-object roots
            # here, exactly as the HTTP envelope does, so a scalar or array frame
            # is a ProtocolError instead of an indexing failure reclassified as
            # a TransportError that would then drive a reconnect.
            if ($message -isnot [hashtable]) {
                throw (New-WorkerFailure 'ProtocolError' 'Live message root must be an object')
            }
            if ($message['type'] -in @('Ping', 'MutationResponse', 'ActionResponse')) {
                continue
            }
            $candidate = Validate-Transition $message
            Commit-Transition $candidate
        }
        catch {
            $failure = $_.Exception
            $kind = if ($failure.Data.Contains('convexKind')) {
                [string]$failure.Data['convexKind']
            }
            else {
                'TransportError'
            }
            Retire-Socket $kind $kind $failure.Message $false
        }
    }
    Retire-Socket 'ClientClosed' '' '' $true
}

function Start-ConvexLive {
    param($State)
    if ($null -ne $State.Worker) {
        return
    }
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($script:ConvexLiveWorker)
    [void]$powerShell.AddArgument($State)
    [void]$powerShell.AddArgument($script:ConvexPerSubscriptionItems)
    [void]$powerShell.AddArgument($script:ConvexGlobalQueueItems)
    [void]$powerShell.AddArgument($script:ConvexGlobalQueueBytes)
    [void]$powerShell.AddArgument($script:ConvexQueueItemOverhead)
    [void]$powerShell.AddArgument($script:ConvexMaxLiveBytes)
    [void]$powerShell.AddArgument($script:ConvexOwnerDeadlineMilliseconds)
    [void]$powerShell.AddArgument($script:ConvexMessageDeadlineMilliseconds)
    $State.Worker = [pscustomobject]@{
        PowerShell = $powerShell
        Handle     = $powerShell.BeginInvoke()
    }
}

function New-ConvexSubscriptionRecord {
    param(
        [string] $Id,
        [uint32] $QueryId,
        [string] $Path,
        [hashtable] $FunctionArgs
    )
    [pscustomobject]@{
        Id                   = $Id
        QueryId              = $QueryId
        Path                 = $Path
        FunctionArgs         = $FunctionArgs
        Active               = $true
        Updates              = [System.Collections.Generic.Queue[object]]::new()
        QueuedBytes          = 0L
        LastValue            = $null
        # Language-local fixtures may install these internal barriers to pause
        # after dequeue and prove an unsubscribe acknowledgement wins the race.
        RelayDequeuedForTest = $null
        RelayResumeForTest   = $null
    }
}

function New-ConvexLiveCommand {
    param([string] $Kind, [string] $Id = '', $Record = $null)
    $cancellation = [Threading.CancellationTokenSource]::new()
    # The owner's socket work and the caller's wait share this one source, so a
    # caller that gives up also retires the operation it started.
    $cancellation.CancelAfter($script:ConvexOwnerDeadlineMilliseconds)
    [pscustomobject]@{
        Kind         = $Kind
        Id           = $Id
        Record       = $Record
        Done         = [Threading.ManualResetEventSlim]::new($false)
        Failure      = $null
        Cancellation = $cancellation
    }
}

function Get-ConvexRemainingMilliseconds {
    param([datetime] $Deadline)
    $remaining = [int][Math]::Ceiling(($Deadline - [datetime]::UtcNow).TotalMilliseconds)
    if ($remaining -lt 0) { 0 } else { $remaining }
}

function Add-ConvexLiveCommand {
    param($Live, $Command, [datetime] $Deadline)
    # Queueing spends the same budget as the acknowledgement, so a full command
    # queue cannot silently add a second full timeout to a public call.
    if (-not $Live.Commands.TryAdd($Command, (Get-ConvexRemainingMilliseconds $Deadline))) {
        $Command.Cancellation.Cancel()
        throw 'Live command queue is full'
    }
}

function Wait-ConvexControl {
    param($Command, [string] $Operation, [datetime] $Deadline)
    if (-not $Command.Done.Wait((Get-ConvexRemainingMilliseconds $Deadline))) {
        # Cancel rather than abandon. The owner drops the timed-out operation
        # instead of finishing it and delaying the next control command.
        $Command.Cancellation.Cancel()
        throw "Live $Operation exceeded the bounded control deadline"
    }
    # The owner completes a command only after its socket work has finished, so
    # the shared cancellation source and its timer can be released here.
    $Command.Cancellation.Dispose()
    if ($null -ne $Command.Failure) {
        throw $Command.Failure
    }
}

function Add-ConvexSubscription {
    param($Live, [string] $Id, [string] $Path, [hashtable] $FunctionArgs)
    # One cumulative deadline covers queueing and acknowledgement together.
    $deadline = [datetime]::UtcNow.AddMilliseconds($script:ConvexControlTimeoutMilliseconds)
    Assert-ConvexPath $Path
    if ($Live.Closed) {
        Throw-ConvexError (New-ConvexError -Name ClosedError -Message 'Live client is closed')
    }
    Start-ConvexLive $Live
    if ([uint64]$Live.NextQueryId -gt [uint64][uint32]::MaxValue) {
        Throw-ConvexError (New-ConvexError -Name ProtocolError -Message 'Live query ID exceeded uint32 range')
    }
    $queryId = [uint32]$Live.NextQueryId
    $Live.NextQueryId = [uint64]$queryId + 1
    $recordArguments = @{
        Id           = $Id
        QueryId      = $queryId
        Path         = $Path
        FunctionArgs = [hashtable]$FunctionArgs
    }
    $record = New-ConvexSubscriptionRecord @recordArguments
    $command = New-ConvexLiveCommand 'Subscribe' $Id $record
    Add-ConvexLiveCommand $Live $command $deadline
    Wait-ConvexControl $command 'subscribe' $deadline
    $record
}

function Remove-ConvexSubscription {
    param($Live, [string] $Id)
    if ($Live.Closed) {
        return
    }
    $deadline = [datetime]::UtcNow.AddMilliseconds($script:ConvexControlTimeoutMilliseconds)
    $command = New-ConvexLiveCommand 'Unsubscribe' $Id
    Add-ConvexLiveCommand $Live $command $deadline
    Wait-ConvexControl $command 'unsubscribe' $deadline
}

function Receive-ConvexSubscription {
    param($Live, $Record, [int] $TimeoutMilliseconds = 10000)
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $item = $null
        [Threading.Monitor]::Enter($Live.QueueGate)
        try {
            if ($Record.Updates.Count -gt 0) {
                $item = $Record.Updates.Dequeue()
                $Record.QueuedBytes -= $item.Bytes
                $Live.PendingCount--
                $Live.PendingBytes -= $item.Bytes
            }
            elseif (-not $Record.Active) {
                throw 'Live subscription is closed'
            }
        }
        finally {
            [Threading.Monitor]::Exit($Live.QueueGate)
        }
        if ($null -ne $item) {
            if ($null -ne $Record.RelayDequeuedForTest) {
                $Record.RelayDequeuedForTest.Set() | Out-Null
                if (-not $Record.RelayResumeForTest.Wait($script:ConvexControlTimeoutMilliseconds)) {
                    throw 'test relay pause exceeded the bounded control deadline'
                }
            }
            [Threading.Monitor]::Enter($Live.QueueGate)
            try {
                if (-not $Record.Active) {
                    throw 'Live subscription is closed'
                }
                return $item.Event
            }
            finally {
                [Threading.Monitor]::Exit($Live.QueueGate)
            }
        }
        Start-Sleep -Milliseconds 5
    }
    $socketState = if ($null -eq $Live.Owner.Socket) { 'Disconnected' } else { [string]$Live.Owner.Socket.State }
    throw "timed out waiting for Live update id=$($Record.Id) active=$($Record.Active) socket=$socketState connections=$($Live.ConnectionCount) close=$($Live.LastCloseReason)"
}

function Disconnect-ConvexLiveForAdapter {
    param($Live)
    if ($Live.Closed) {
        Throw-ConvexError (New-ConvexError -Name ClosedError -Message 'Live client is closed')
    }
    # Retirement, reconnect scheduling, the acknowledgement, and the rehydration
    # barrier all draw on this single budget. Charging each step its own timeout
    # would let one debug disconnect hold the owner for a multiple of it.
    $deadline = [datetime]::UtcNow.AddMilliseconds($script:ConvexControlTimeoutMilliseconds)
    $command = New-ConvexLiveCommand 'DebugDisconnect'
    Add-ConvexLiveCommand $Live $command $deadline
    Wait-ConvexControl $command 'debug disconnect' $deadline
    if (-not $Live.Owner.HydrationApplied.Wait((Get-ConvexRemainingMilliseconds $deadline))) {
        throw 'Live debug disconnect exceeded the rehydration transition deadline'
    }
    if (
        $Live.Subscriptions.Count -gt 0 -and
        ($null -eq $Live.Owner.Socket -or $Live.Owner.Socket.State -ne [Net.WebSockets.WebSocketState]::Open)
    ) {
        throw 'Live debug disconnect acknowledged without an open replacement owner'
    }
}

function Close-ConvexLive {
    param($Live)
    if ($Live.Closed) {
        return
    }
    $deadline = [datetime]::UtcNow.AddMilliseconds($script:ConvexControlTimeoutMilliseconds)
    $command = New-ConvexLiveCommand 'Stop'
    if ($null -ne $Live.Worker) {
        if ($Live.Commands.TryAdd($command, (Get-ConvexRemainingMilliseconds $deadline))) {
            $command.Done.Wait((Get-ConvexRemainingMilliseconds $deadline)) | Out-Null
        }
        if (-not $Live.Worker.Handle.IsCompleted) {
            $Live.Worker.PowerShell.Stop()
        }
        try {
            $Live.Worker.PowerShell.EndInvoke($Live.Worker.Handle) | Out-Null
        }
        catch {}
        $Live.Worker.PowerShell.Dispose()
    }
    $Live.Closed = $true
    [Threading.Monitor]::Enter($Live.QueueGate)
    try {
        foreach ($record in $Live.Subscriptions.Values) {
            $record.Active = $false
            $record.Updates.Clear()
            $record.QueuedBytes = 0L
        }
        $Live.Subscriptions.Clear()
        $Live.PendingCount = 0
        $Live.PendingBytes = 0L
    }
    finally {
        [Threading.Monitor]::Exit($Live.QueueGate)
    }
}
