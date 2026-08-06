# This educational client implements Convex's documented JSON HTTP API and the
# pinned unversioned /api/sync profile directly in PowerShell. .NET supplies
# ordinary HTTP, TLS, JSON, and WebSocket primitives only.
Set-StrictMode -Version Latest

$script:ConvexJsonDepth = 64
$script:ConvexMaxHttpBytes = 8MB
$script:ConvexMaxLiveBytes = 4MB
$script:ConvexPerSubscriptionItems = 16
$script:ConvexGlobalQueueItems = 64
$script:ConvexGlobalQueueBytes = 8MB
$script:ConvexQueueItemOverhead = 512
$script:ConvexConnectTimeoutMilliseconds = 3000
$script:ConvexSendTimeoutMilliseconds = 3000
$script:ConvexControlTimeoutMilliseconds = 4000

function ConvertTo-ConvexJson {
    param([Parameter(Mandatory)] $Value)
    $Value | ConvertTo-Json -Depth $script:ConvexJsonDepth -Compress
}

function ConvertFrom-ConvexJson {
    param([Parameter(Mandatory)][string] $Text)
    $Text | ConvertFrom-Json -AsHashtable -Depth $script:ConvexJsonDepth
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
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $document = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($Bytes))
    try {
        ConvertFrom-ConvexJsonElement $document.RootElement
    }
    finally {
        $document.Dispose()
    }
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
    $http.Timeout = [TimeSpan]::FromSeconds(30)
    [pscustomobject]@{
        Url     = $uri.AbsoluteUri.TrimEnd('/')
        Token   = ''
        Version = $ClientVersion
        Closed  = $false
        Http    = $http
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
        [hashtable] $FunctionArgs = @{}
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
    try {
        $response = $Client.Http.Send($request)
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($bytes.Length -gt $script:ConvexMaxHttpBytes) {
            Throw-ConvexError (
                New-ConvexError -Name TransportError -Message 'Convex HTTP response exceeds 8 MiB' -Operation $Operation
            )
        }
        # Parse UTF-8 directly. Converting an 8 MiB response to one giant
        # UTF-16 string first would duplicate the payload inside the final
        # adapter's 128 MiB cgroup before the result can be emitted.
        $decoded = ConvertFrom-ConvexJsonBytes $bytes
    }
    catch {
        Throw-ConvexError (Get-ConvexError $_.Exception $Operation)
    }
    finally {
        $request.Dispose()
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
    [string[]] $logs = @()
    if ($decoded.ContainsKey('logLines')) {
        [string[]] $logs = @($decoded['logLines'] | ForEach-Object { [string] $_ })
    }
    if ($decoded['status'] -eq 'success' -and $decoded.ContainsKey('value')) {
        return [pscustomobject]@{ Value = $decoded['value']; Logs = [string[]]$logs }
    }
    if ($decoded['status'] -eq 'error') {
        $message = if ($decoded.ContainsKey('errorMessage')) {
            [string]$decoded['errorMessage']
        }
        else {
            'Convex function failed'
        }
        Throw-ConvexError (
            New-ConvexError -Name FunctionError -Message $message -Data $decoded['errorData'] -Logs $logs -Operation $Operation
        )
    }
    Throw-ConvexError (
        New-ConvexError -Name ProtocolError -Message "Convex $Operation response had unexpected status" -Operation $Operation
    )
}

function Get-ConvexQuery {
    param($Client, [string] $Path, [hashtable] $FunctionArgs = @{})
    Invoke-ConvexFunction -Client $Client -Operation query -Path $Path -FunctionArgs $FunctionArgs
}

function Invoke-ConvexMutation {
    param($Client, [string] $Path, [hashtable] $FunctionArgs = @{})
    Invoke-ConvexFunction -Client $Client -Operation mutation -Path $Path -FunctionArgs $FunctionArgs
}

function Invoke-ConvexAction {
    param($Client, [string] $Path, [hashtable] $FunctionArgs = @{})
    Invoke-ConvexFunction -Client $Client -Operation action -Path $Path -FunctionArgs $FunctionArgs
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
            Buffer              = [byte[]]::new(4096)
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
        $ConnectTimeoutMilliseconds,
        $SendTimeoutMilliseconds
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

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

    function Send-Frame($Value) {
        $socket = $State.Owner.Socket
        if ($null -eq $socket) {
            throw (New-WorkerFailure 'TransportError' 'Live WebSocket is not connected')
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress))
        $deadline = [Threading.CancellationTokenSource]::new()
        try {
            $deadline.CancelAfter($SendTimeoutMilliseconds)
            $socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                $deadline.Token
            ).GetAwaiter().GetResult() | Out-Null
        }
        catch {
            throw (New-WorkerFailure 'TransportError' "Live send failed: $($_.Exception.Message)")
        }
        finally {
            $deadline.Dispose()
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
        $State.Owner.Version = New-ZeroVersion
        $State.Owner.QuerySet = 0
        if ($null -ne $oldSocket) {
            try { $oldSocket.Abort() } catch {}
            if ($null -ne $oldReceive) {
                try { $oldReceive.Wait(500) | Out-Null } catch {}
            }
            $oldSocket.Dispose()
            $State.ConnectionCount++
        }
        $State.LastCloseReason = $Reason
        if (-not $Intentional -and $FailureKind) {
            Emit-Failure $FailureKind $FailureMessage
        }
        $State.Owner.NextConnectAt = [datetime]::UtcNow.AddMilliseconds($State.Owner.BackoffMilliseconds)
        $State.Owner.BackoffMilliseconds = [Math]::Min($State.Owner.BackoffMilliseconds * 2, 15000)
    }

    function Add-Modification($Record) {
        @{
            type    = 'Add'
            queryId = $Record.QueryId
            udfPath = $Record.Path
            args    = @($Record.FunctionArgs)
        }
    }

    function Send-Modify([object[]] $Changes) {
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
        }
        $State.Owner.QuerySet = $newVersion
    }

    function Connect-Socket {
        $candidate = [Net.WebSockets.ClientWebSocket]::new()
        # HttpListener and several WebSocket proxies require an explicit offered
        # protocol. Convex may either select it or leave the response unnegotiated.
        $candidate.Options.AddSubProtocol('convex-1.0.0')
        $candidate.Options.SetRequestHeader('Convex-Client', $State.Version)
        $deadline = [Threading.CancellationTokenSource]::new()
        try {
            $deadline.CancelAfter($ConnectTimeoutMilliseconds)
            $candidate.ConnectAsync([Uri]$State.Endpoint, $deadline.Token).GetAwaiter().GetResult() | Out-Null
        }
        catch {
            $candidate.Dispose()
            throw (New-WorkerFailure 'TransportError' "Live connect failed: $($_.Exception.Message)")
        }
        finally {
            $deadline.Dispose()
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
        Send-Frame $connect
        [object[]] $adds = @(
            $State.Subscriptions.Values |
                Sort-Object QueryId |
                ForEach-Object { Add-Modification $_ }
        )
        Send-Modify $adds
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
                [string[]] $logs = @($modification['logLines'] | ForEach-Object { [string] $_ })
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
                $failureMessage = if ($modification.ContainsKey('errorMessage')) {
                    [string]$modification['errorMessage']
                }
                else {
                    'query failed'
                }
                $error = @{ name = 'FunctionError'; message = $failureMessage }
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
                Connect-Socket
            }

            $command = $null
            if ($State.Commands.TryTake([ref]$command, 20)) {
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
                                # Connect synchronously on the sole owner. The
                                # caller's acknowledgement barrier below then
                                # waits for every rehydrated transition to apply.
                                Connect-Socket
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
                                Send-Modify $changes.ToArray()
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
            $State.Owner.Frame.Write($State.Owner.Buffer, 0, $result.Count)
            if ($State.Owner.Frame.Length -gt $MaxFrameBytes) {
                throw (New-WorkerFailure 'ProtocolError' 'Live frame exceeds 4 MiB')
            }
            if (-not $result.EndOfMessage) {
                continue
            }
            $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
            try {
                $text = $strictUtf8.GetString(
                    $State.Owner.Frame.GetBuffer(),
                    0,
                    [int]$State.Owner.Frame.Length
                )
                $message = $text | ConvertFrom-Json -AsHashtable -Depth 64
            }
            catch {
                throw (New-WorkerFailure 'ProtocolError' "invalid Live UTF-8 or JSON: $($_.Exception.Message)")
            }
            finally {
                $State.Owner.Frame.SetLength(0)
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
    [void]$powerShell.AddArgument($script:ConvexConnectTimeoutMilliseconds)
    [void]$powerShell.AddArgument($script:ConvexSendTimeoutMilliseconds)
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

function Wait-ConvexControl {
    param($Command, [string] $Operation)
    if (-not $Command.Done.Wait($script:ConvexControlTimeoutMilliseconds)) {
        throw "Live $Operation exceeded the bounded control deadline"
    }
    if ($null -ne $Command.Failure) {
        throw $Command.Failure
    }
}

function Add-ConvexSubscription {
    param($Live, [string] $Id, [string] $Path, [hashtable] $FunctionArgs)
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
    $command = [pscustomobject]@{
        Kind    = 'Subscribe'
        Record  = $record
        Done    = [Threading.ManualResetEventSlim]::new($false)
        Failure = $null
    }
    if (-not $Live.Commands.TryAdd($command, 1000)) {
        throw 'Live command queue is full'
    }
    Wait-ConvexControl $command 'subscribe'
    $record
}

function Remove-ConvexSubscription {
    param($Live, [string] $Id)
    if ($Live.Closed) {
        return
    }
    $command = [pscustomobject]@{
        Kind    = 'Unsubscribe'
        Id      = $Id
        Done    = [Threading.ManualResetEventSlim]::new($false)
        Failure = $null
    }
    if (-not $Live.Commands.TryAdd($command, 1000)) {
        throw 'Live command queue is full'
    }
    Wait-ConvexControl $command 'unsubscribe'
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
    $command = [pscustomobject]@{
        Kind    = 'DebugDisconnect'
        Done    = [Threading.ManualResetEventSlim]::new($false)
        Failure = $null
    }
    if (-not $Live.Commands.TryAdd($command, 1000)) {
        throw 'Live command queue is full'
    }
    Wait-ConvexControl $command 'debug disconnect'
    if (-not $Live.Owner.HydrationApplied.Wait($script:ConvexControlTimeoutMilliseconds)) {
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
    $command = [pscustomobject]@{
        Kind    = 'Stop'
        Done    = [Threading.ManualResetEventSlim]::new($false)
        Failure = $null
    }
    if ($null -ne $Live.Worker) {
        if ($Live.Commands.TryAdd($command, 1000)) {
            $command.Done.Wait($script:ConvexControlTimeoutMilliseconds) | Out-Null
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
