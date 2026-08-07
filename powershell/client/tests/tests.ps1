Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Convex.ps1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) {
        throw "$Message. expected=$Expected actual=$Actual"
    }
}

function Assert-Array {
    param($Value, [string] $Message)
    Assert-True ($Value -is [array]) $Message
}

function ConvertFrom-FixtureTimestamp([string] $Timestamp) {
    $bytes = [Convert]::FromBase64String($Timestamp)
    if ($bytes.Length -ne 8) { throw 'fixture timestamp did not contain eight bytes' }
    [uint64]$value = 0
    for ($index = 0; $index -lt 8; $index++) {
        $value = $value -bor ([uint64]$bytes[$index] -shl (8 * $index))
    }
    $value
}

function Start-Fixture {
    param([int] $Port)
    $ready = "/tmp/powershell-fixture-$Port.ready"
    [IO.File]::Delete($ready)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixture-server.ps1'),
        '-Port', [string]$Port, '-ReadyFile', $ready
    )
    $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($ready) -and [datetime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "fixture exited early with $($process.ExitCode)"
        }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ([IO.File]::Exists($ready)) 'fixture did not become ready'
    [pscustomobject]@{ Process = $process; Url = "http://127.0.0.1:$Port" }
}

function Stop-Fixture {
    param($Fixture, $Client)
    try {
        Invoke-ConvexFunction $Client query 'fixture:shutdown' @{} | Out-Null
    }
    catch {}
    if (-not $Fixture.Process.WaitForExit(5000)) {
        $Fixture.Process.Kill($true)
        throw 'fixture did not stop after EOF/shutdown deadline'
    }
}

function Start-HttpFixture {
    param([int] $Port)
    $ready = "/tmp/powershell-http-fixture-$Port.ready"
    [IO.File]::Delete($ready)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'http-fixture-server.ps1'),
        '-Port', [string]$Port, '-ReadyFile', $ready
    )
    $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($ready) -and [datetime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "HTTP fixture exited early with $($process.ExitCode)"
        }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ([IO.File]::Exists($ready)) 'HTTP fixture did not become ready'
    [pscustomobject]@{ Process = $process; Url = "http://127.0.0.1:$Port" }
}

function Stop-HttpFixture {
    param($Fixture, $Client)
    try {
        Invoke-ConvexFunction $Client query 'fixture:httpShutdown' @{} | Out-Null
    }
    catch {}
    if (-not $Fixture.Process.WaitForExit(5000)) {
        $Fixture.Process.Kill($true)
        throw 'HTTP fixture did not stop after shutdown deadline'
    }
}

# A raw WebSocket peer that accepts immediately, delays only the 101 upgrade,
# and then never drains the connection. It is deliberately not the ordinary
# fixture: HttpListener completes the upgrade as soon as it accepts and keeps
# reading, so it cannot hold the owner inside connect and send at all.
$slowPeerWorker = {
    param($Listener, [int] $DelayMilliseconds, $State)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    try {
        while (-not $State.Stop) {
            if (-not $Listener.Pending()) {
                Start-Sleep -Milliseconds 20
                continue
            }
            $client = $Listener.AcceptTcpClient()
            $State.Clients.Add($client)
            $client.ReceiveBufferSize = 512
            $stream = $client.GetStream()
            $request = [Text.StringBuilder]::new()
            while (-not $request.ToString().EndsWith("`r`n`r`n")) {
                $value = $stream.ReadByte()
                if ($value -lt 0) {
                    break
                }
                [void]$request.Append([char]$value)
            }
            $key = ''
            foreach ($line in ($request.ToString() -split "`r`n")) {
                if ($line -match '^Sec-WebSocket-Key:\s*(.+)$') {
                    $key = $Matches[1].Trim()
                }
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
            $sha = [Security.Cryptography.SHA1]::Create()
            try {
                $accept = [Convert]::ToBase64String(
                    $sha.ComputeHash(
                        [Text.Encoding]::ASCII.GetBytes("$key258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                    )
                )
            }
            finally {
                $sha.Dispose()
            }
            $response = @(
                'HTTP/1.1 101 Switching Protocols'
                'Upgrade: websocket'
                'Connection: Upgrade'
                "Sec-WebSocket-Accept: $accept"
                'Sec-WebSocket-Protocol: convex-1.0.0'
                ''
                ''
            ) -join "`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            # No read follows. The client's next frame fills the closed window.
        }
    }
    catch {
        # Stopping the listener interrupts the accept loop by design; anything
        # else is a genuine fixture fault worth reporting.
        if (-not $State.Stop) {
            [Console]::Error.WriteLine("slow peer stopped: $($_.Exception.Message)")
        }
    }
    finally {
        foreach ($client in $State.Clients) {
            try { $client.Dispose() } catch {}
        }
    }
}

function Assert-HttpFailure {
    param($Client, [string] $Path, [string] $ExpectedName)
    $caught = $null
    try {
        Get-ConvexQuery $Client $Path @{} | Out-Null
    }
    catch {
        $caught = $_.Exception
    }
    Assert-True ($null -ne $caught) "$Path unexpectedly succeeded"
    $failure = Get-ConvexError $caught
    Assert-Equal $failure.Name $ExpectedName "$Path error classification"
    $failure
}

# Exercise the HTTP parser against a raw peer. These cases cannot be represented
# by the ordinary Convex fixture because HttpListener normalizes framing and
# status behaviour before the client sees it.
$httpFixture = Start-HttpFixture 43144
$httpClient = New-ConvexClient $httpFixture.Url
try {
    foreach ($path in @('fixture:http4xxSuccess', 'fixture:http5xxSuccess')) {
        Assert-HttpFailure $httpClient $path 'TransportError' | Out-Null
    }
    foreach ($path in @(
            'fixture:httpScalar',
            'fixture:httpArray',
            'fixture:httpNull',
            'fixture:httpMalformed',
            'fixture:httpMissingStatus',
            'fixture:httpStatusType',
            'fixture:httpUnknownStatus',
            'fixture:httpMissingValue',
            'fixture:httpMissingErrorMessage',
            'fixture:httpErrorMessageType',
            'fixture:httpLogLinesType',
            'fixture:httpLogLineType'
        )) {
        Assert-HttpFailure $httpClient $path 'ProtocolError' | Out-Null
    }

    $functionFailure = Assert-HttpFailure $httpClient 'fixture:httpFunctionError' 'FunctionError'
    Assert-Equal $functionFailure.Message 'expected raw failure' 'raw FunctionError message'
    Assert-Equal $functionFailure.Data.code 'RAW' 'raw FunctionError data'
    Assert-Array $functionFailure.Logs 'raw FunctionError logs must remain an array'
    Assert-Equal $functionFailure.Logs.Count 1 'raw FunctionError log count'
    Assert-True (Get-ConvexQuery $httpClient 'fixture:httpRecovery' @{}).Value.recovered 'HTTP parser did not recover after invalid envelopes'

    # Convex delivers a failed function as a complete error envelope carried on
    # a non-2xx status: 560 for a developer error, 400 and 500 for other server
    # rejections. Each must stay a FunctionError with its errorData and its
    # logLines intact, and the client must keep serving the next call. Reading
    # the status before the body would turn all three into TransportError and
    # silently drop everything the function reported about its own failure.
    foreach ($code in @('560', '500', '400')) {
        $path = "fixture:http${code}FunctionError"
        $statusFailure = Assert-HttpFailure $httpClient $path 'FunctionError'
        Assert-Equal $statusFailure.Message "expected $code failure" "$path FunctionError message"
        Assert-Equal $statusFailure.Data.code $code "$path FunctionError data"
        Assert-True $statusFailure.Data.detail.nested "$path FunctionError nested data"
        Assert-Array $statusFailure.Logs "$path logs must remain an array"
        Assert-Equal $statusFailure.Logs.Count 2 "$path log count"
        Assert-Equal $statusFailure.Logs[0] "$code first log" "$path first log"
        Assert-Equal $statusFailure.Logs[1] "$code second log" "$path second log"
        Assert-True (Get-ConvexQuery $httpClient 'fixture:httpRecovery' @{}).Value.recovered "HTTP client did not recover after a $code function error"
    }

    # A body that already identified itself as a Convex error envelope and then
    # broke the envelope contract is a protocol fault even on 560. A broken
    # backend must not be laundered into a transport failure.
    foreach ($path in @(
            'fixture:http560MissingErrorMessage',
            'fixture:http560ErrorMessageType',
            'fixture:http560LogLinesType'
        )) {
        Assert-HttpFailure $httpClient $path 'ProtocolError' | Out-Null
    }

    # A body that never claimed to be a Convex envelope cannot be a protocol
    # violation when the status already reports a failure. Each must name the
    # status so the caller can tell a proxy page from a Convex response.
    foreach ($path in @(
            'fixture:http560Malformed',
            'fixture:http560UnknownStatus',
            'fixture:http560NonObject'
        )) {
        $statusFailure = Assert-HttpFailure $httpClient $path 'TransportError'
        Assert-True ($statusFailure.Message.Contains('status 560')) "$path must report its HTTP status"
    }
    $gatewayFailure = Assert-HttpFailure $httpClient 'fixture:http502Html' 'TransportError'
    Assert-True ($gatewayFailure.Message.Contains('status 502')) 'proxy error page must report its HTTP status'

    # The 8 MiB streaming bound has to hold on the error path too, now that a
    # failing response is read instead of rejected from its status line. This
    # peer declares no Content-Length, so the client must stop mid-stream.
    $overLimitOnError = Assert-HttpFailure $httpClient 'fixture:http560OverLimit' 'TransportError'
    Assert-True ($overLimitOnError.Message.Contains('8 MiB')) 'oversize non-2xx body must stop at the streaming bound'
    Assert-True (Get-ConvexQuery $httpClient 'fixture:httpRecovery' @{}).Value.recovered 'HTTP client did not recover after non-2xx envelope failures'

    $boundary = Get-ConvexQuery $httpClient 'fixture:httpExactBoundary' @{}
    Assert-Equal $boundary.Value.blob.Length (8MB - 40) 'exact 8 MiB HTTP response was not accepted completely'
    $boundary = $null
    [GC]::Collect()

    foreach ($path in @(
            'fixture:httpFixedOverLimit',
            'fixture:httpDishonestLength',
            'fixture:httpChunkedOverLimit',
            'fixture:httpNoLengthOverLimit',
            'fixture:httpSlowOverLimit'
        )) {
        Assert-HttpFailure $httpClient $path 'TransportError' | Out-Null
    }

    $httpClient.HttpTimeoutMilliseconds = 200
    $deadlineTimer = [Diagnostics.Stopwatch]::StartNew()
    $deadlineFailure = Assert-HttpFailure $httpClient 'fixture:httpSlow' 'TransportError'
    $deadlineTimer.Stop()
    Assert-True ($deadlineFailure.Message.Contains('deadline')) 'slow HTTP response was not reported as a deadline'
    Assert-True ($deadlineTimer.ElapsedMilliseconds -lt 900) 'slow HTTP response exceeded its deterministic deadline'

    $httpClient.HttpTimeoutMilliseconds = 5000
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.CancelAfter(150)
        $cancelTimer = [Diagnostics.Stopwatch]::StartNew()
        $caught = $null
        try {
            Get-ConvexQuery $httpClient 'fixture:httpSlow' @{} $cancellation.Token | Out-Null
        }
        catch {
            $caught = $_.Exception
        }
        $cancelTimer.Stop()
        Assert-True ($null -ne $caught) 'cancelled HTTP response unexpectedly succeeded'
        $cancelFailure = Get-ConvexError $caught
        Assert-Equal $cancelFailure.Name 'TransportError' 'HTTP cancellation classification'
        Assert-True ($cancelFailure.Message.Contains('cancelled')) 'HTTP cancellation message'
        Assert-True ($cancelTimer.ElapsedMilliseconds -lt 900) 'HTTP cancellation exceeded its deterministic deadline'
    }
    finally {
        $cancellation.Dispose()
    }
    $httpClient.HttpTimeoutMilliseconds = 30000
    Assert-True (Get-ConvexQuery $httpClient 'fixture:httpRecovery' @{}).Value.recovered 'HTTP client did not recover after streaming failures'
}
finally {
    Stop-HttpFixture $httpFixture $httpClient
    Close-ConvexClient $httpClient
}

$fixture = Start-Fixture 43137
$client = New-ConvexClient $fixture.Url
$live = New-ConvexLiveState $fixture.Url
$queryIdLive = $null
try {
    $echo = Get-ConvexQuery $client 'demo:echo' @{ value = @{ unicode = 'Καλημέρα 🦘' } }
    Assert-Equal $echo.Value.unicode 'Καλημέρα 🦘' 'HTTP UTF-8 round trip'
    Assert-Array $echo.Logs 'single HTTP log must remain an array'
    Assert-Equal $echo.Logs.Count 1 'single HTTP log count'

    # Allocate the maximum protocol query ID through the public subscription
    # path. The record, map lookup, and Add message must retain uint32 rather
    # than narrowing it to Int32. The following allocation must fail before it
    # mutates either allocator state or the subscription map.
    $queryIdLive = New-ConvexLiveState $fixture.Url
    $queryIdLive.NextQueryId = [uint64][uint32]::MaxValue
    $maximumIdSubscription = Add-ConvexSubscription $queryIdLive 'maximum-query-id' 'demo:state' @{ room = 'maximum-query-id' }
    Assert-Equal $maximumIdSubscription.QueryId ([uint32]::MaxValue) 'maximum uint32 query ID was not retained by the record'
    Assert-Equal $maximumIdSubscription.QueryId.GetType().FullName 'System.UInt32' 'subscription record narrowed query ID type'
    Assert-Equal $queryIdLive.NextQueryId ([uint64][uint32]::MaxValue + 1) 'maximum query ID did not advance allocator'
    Assert-Equal (Receive-ConvexSubscription $queryIdLive $maximumIdSubscription 5000).value.count 0 'maximum query ID subscription did not receive its initial value'
    try {
        Add-ConvexSubscription $queryIdLive 'overflow-query-id' 'demo:state' @{ room = 'overflow-query-id' } | Out-Null
        throw 'query ID overflow was not rejected'
    }
    catch {
        $queryIdFailure = Get-ConvexError $_.Exception
        Assert-Equal $queryIdFailure.Name 'ProtocolError' 'query ID overflow classification'
    }
    Assert-Equal $queryIdLive.NextQueryId ([uint64][uint32]::MaxValue + 1) 'rejected query ID advanced allocator state'
    Assert-True (-not $queryIdLive.Subscriptions.ContainsKey('overflow-query-id')) 'rejected query ID entered subscription map'
    Remove-ConvexSubscription $queryIdLive 'maximum-query-id'

    # Convex timestamps are little-endian uint64 values. Cross 255 -> 256 on a
    # real reconnect so raw-byte ordering cannot accidentally pass this suite.
    $timestampBoundary = Add-ConvexSubscription $live 'timestamp-boundary' 'demo:state' @{
        room = 'timestamp-boundary'
        mode = 'timestampBoundary'
    }
    Assert-Equal (Receive-ConvexSubscription $live $timestampBoundary 5000).value.count 0 'timestamp boundary initial value'
    Assert-True (Receive-ConvexSubscription $live $timestampBoundary 5000).value.boundary 'timestamp boundary transition was not applied'
    Disconnect-ConvexLiveForAdapter $live
    $boundaryDeadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        $boundaryMetadata = (Get-ConvexQuery $client 'fixture:metadata' @{}).Value
        $boundaryConnects = @($boundaryMetadata.connectMessages | Where-Object { $_.lastCloseReason -eq 'DebugDisconnect' })
        if ($boundaryConnects.Count -eq 0) { Start-Sleep -Milliseconds 20 }
    } while ($boundaryConnects.Count -eq 0 -and [datetime]::UtcNow -lt $boundaryDeadline)
    Assert-True ($boundaryConnects.Count -gt 0) 'timestamp boundary reconnect was not observed'
    Assert-True ((ConvertFrom-FixtureTimestamp $boundaryConnects[-1].maxObservedTimestamp) -ge [uint64]256) 'little-endian timestamp max did not cross 255 -> 256'
    Remove-ConvexSubscription $live 'timestamp-boundary'

    try {
        Get-ConvexQuery $client 'demo:fail' @{ code = 'EXPECTED' } | Out-Null
        throw 'structured function error was not raised'
    }
    catch {
        $errorValue = Get-ConvexError $_.Exception
        Assert-Equal $errorValue.Name 'FunctionError' 'HTTP failure classification'
        Assert-Equal $errorValue.Data.code 'EXPECTED' 'HTTP structured error data'
        Assert-Array $errorValue.Logs 'single failure log must remain an array'
    }

    # A fragmented UTF-8 transition proves parser state survives polling while a
    # multi-byte value crosses WebSocket message fragments.
    $fragmented = Add-ConvexSubscription $live 'fragmented' 'demo:state' @{
        room = 'fragmented'
        mode = 'fragmented'
    }
    $initial = Receive-ConvexSubscription $live $fragmented 5000
    Assert-Equal $initial.value.count 0 'fragmented initial value'
    Assert-Equal $initial.value.text 'café 🦘' 'fragmented UTF-8 value'
    Assert-Array $initial.logs 'single Live log must remain an array'
    Invoke-ConvexMutation $client 'demo:increment' @{ room = 'fragmented'; runId = 'one' } | Out-Null
    $external = Receive-ConvexSubscription $live $fragmented 5000
    Assert-Equal $external.value.count 1 'external Live update'
    Remove-ConvexSubscription $live 'fragmented'

    # QueryFailed clears value dedupe. Recovery with the exact same value must be
    # observable rather than disappearing as an unchanged hydration.
    $same = Add-ConvexSubscription $live 'same-value' 'demo:state' @{ room = 'same' }
    $sameInitial = Receive-ConvexSubscription $live $same 5000
    Assert-Equal $sameInitial.value.count 1 'same-value initial result'
    Get-ConvexQuery $client 'fixture:failSame' @{} | Out-Null
    $sameFailure = Receive-ConvexSubscription $live $same 5000
    Assert-Equal $sameFailure.error.name 'FunctionError' "QueryFailed classification ($($sameFailure.error.message))"
    Assert-Array $sameFailure.logs 'single QueryFailed log must remain an array'
    $sameRecovery = Receive-ConvexSubscription $live $same 5000
    Assert-Equal $sameRecovery.value.count 1 'same-value recovery is emitted'
    Assert-Array $sameRecovery.logs 'single recovery log must remain an array'
    Remove-ConvexSubscription $live 'same-value'

    # The valid first modification must not publish when a later modification in
    # the same transition is invalid. The only event is the ProtocolError.
    $invalid = Add-ConvexSubscription $live 'invalid-tail' 'demo:state' @{
        room = 'invalid'
        mode = 'invalidTail'
    }
    $protocolFailure = Receive-ConvexSubscription $live $invalid 5000
    Assert-Equal $protocolFailure.error.name 'ProtocolError' 'transaction failure classification'
    Assert-True (-not $protocolFailure.ContainsKey('value')) 'invalid transition leaked a partial value'
    Remove-ConvexSubscription $live 'invalid-tail'

    $invalidId = Add-ConvexSubscription $live 'invalid-query-id' 'demo:state' @{
        room = 'invalid-query-id'
        mode = 'invalidQueryId'
    }
    $invalidIdFailure = Receive-ConvexSubscription $live $invalidId 5000
    Assert-Equal $invalidIdFailure.error.name 'ProtocolError' 'out-of-range query ID classification'
    Remove-ConvexSubscription $live 'invalid-query-id'

    $invalidTimestamp = Add-ConvexSubscription $live 'invalid-timestamp' 'demo:state' @{
        room = 'invalid-timestamp'
        mode = 'invalidTimestamp'
    }
    $invalidTimestampFailure = Receive-ConvexSubscription $live $invalidTimestamp 5000
    Assert-Equal $invalidTimestampFailure.error.name 'ProtocolError' 'invalid timestamp classification'
    Remove-ConvexSubscription $live 'invalid-timestamp'

    # Live validates logLines exactly like the HTTP envelope. Coercing each
    # element with [string] would publish a type name as a log line instead of
    # rejecting the transition.
    $logLineType = Add-ConvexSubscription $live 'log-line-type' 'demo:state' @{
        room = 'log-line-type'
        mode = 'logLineType'
    }
    $logLineTypeFailure = Receive-ConvexSubscription $live $logLineType 5000
    Assert-Equal $logLineTypeFailure.error.name 'ProtocolError' 'non-string Live log line classification'
    Remove-ConvexSubscription $live 'log-line-type'

    $logLinesType = Add-ConvexSubscription $live 'log-lines-type' 'demo:state' @{
        room = 'log-lines-type'
        mode = 'logLinesType'
    }
    $logLinesTypeFailure = Receive-ConvexSubscription $live $logLinesType 5000
    Assert-Equal $logLinesTypeFailure.error.name 'ProtocolError' 'non-array Live logLines classification'
    Remove-ConvexSubscription $live 'log-lines-type'

    # A byte-native parse accepts any JSON root, so a non-object frame must be a
    # ProtocolError rather than an indexing failure reclassified as a transport
    # fault that would drive a reconnect.
    $nonObjectRoot = Add-ConvexSubscription $live 'non-object-root' 'demo:state' @{
        room = 'non-object-root'
        mode = 'nonObjectRoot'
    }
    $nonObjectRootFailure = Receive-ConvexSubscription $live $nonObjectRoot 5000
    Assert-Equal $nonObjectRootFailure.error.name 'ProtocolError' 'non-object Live root classification'
    Remove-ConvexSubscription $live 'non-object-root'

    # QueryFailed carries the Convex function's own message. A missing or
    # non-string errorMessage is a malformed transition, so it must surface as a
    # ProtocolError instead of a FunctionError invented from placeholder text.
    # The same subscription then recovers on the replacement connection.
    foreach ($failureMode in @('queryFailedNoMessage', 'queryFailedMessageType')) {
        $malformed = Add-ConvexSubscription $live $failureMode 'demo:state' @{
            room = $failureMode
            mode = $failureMode
        }
        $malformedFailure = Receive-ConvexSubscription $live $malformed 5000
        Assert-Equal $malformedFailure.error.name 'ProtocolError' "$failureMode classification"
        $malformedRecovery = Receive-ConvexSubscription $live $malformed 10000
        Assert-True ($malformedRecovery.ContainsKey('value')) "$failureMode did not recover on the same subscription"
        Remove-ConvexSubscription $live $failureMode
    }

    # This peer never stops sending, but never finishes its message either. An
    # inactivity timer would be reset by every byte it trickles out, so only an
    # absolute per-message deadline can end the frame. The failure is a
    # TransportError and the reconnect replays the Add for the same subscription.
    $dribbleTimer = [Diagnostics.Stopwatch]::StartNew()
    $dribble = Add-ConvexSubscription $live 'dribble' 'demo:state' @{
        room = 'dribble'
        mode = 'dribble'
    }
    $dribbleFailure = Receive-ConvexSubscription $live $dribble 12000
    $dribbleTimer.Stop()
    Assert-Equal $dribbleFailure.error.name 'TransportError' 'continuous dribble classification'
    Assert-True ($dribbleTimer.ElapsedMilliseconds -lt 8000) 'dribbled message outlived its absolute assembly deadline'
    $dribbleRecovery = Receive-ConvexSubscription $live $dribble 10000
    Assert-True ($dribbleRecovery.ContainsKey('value')) 'dribbled subscription did not recover after reconnect'
    Remove-ConvexSubscription $live 'dribble'

    # The same absolute deadline retires a peer that stops permanently halfway
    # through a frame rather than trickling.
    $partial = Add-ConvexSubscription $live 'partial-frame' 'demo:state' @{
        room = 'partial-frame'
        mode = 'stalledFrameOnce'
    }
    $partialFailure = Receive-ConvexSubscription $live $partial 12000
    Assert-Equal $partialFailure.error.name 'TransportError' 'permanently partial frame classification'
    $partialRecovery = Receive-ConvexSubscription $live $partial 10000
    Assert-True ($partialRecovery.ContainsKey('value')) 'partially framed subscription did not recover after reconnect'
    Remove-ConvexSubscription $live 'partial-frame'

    # A peer stalled halfway through a frame cannot prevent unsubscribe or close
    # because the owner retains the outstanding ReceiveAsync and polls commands.
    $stalled = Add-ConvexSubscription $live 'stalled' 'demo:state' @{
        room = 'stalled'
        mode = 'stalledFrame'
    }
    Start-Sleep -Milliseconds 100
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Remove-ConvexSubscription $live 'stalled'
    $timer.Stop()
    Assert-True ($timer.ElapsedMilliseconds -lt 4000) 'stalled-frame unsubscribe exceeded deadline'

    # Same-id replacement retires and drains the old generation before returning.
    $old = Add-ConvexSubscription $live 'replacement' 'demo:state' @{ room = 'old' }
    Start-Sleep -Milliseconds 100
    $replacement = Add-ConvexSubscription $live 'replacement' 'demo:state' @{ room = 'new' }
    Assert-True (-not $old.Active) 'same-id replacement left the old generation active'
    Assert-Equal $old.Updates.Count 0 'same-id replacement left stale queued events'
    $replacementInitial = Receive-ConvexSubscription $live $replacement 5000
    Assert-Equal $replacementInitial.value.count 1 'replacement generation initial value'
    Remove-ConvexSubscription $live 'replacement'

    # Pause the real receive relay after dequeue. Unsubscribe must invalidate
    # that generation before acknowledging, so resuming cannot publish stale data.
    $barrier = Add-ConvexSubscription $live 'barrier' 'demo:state' @{ room = 'barrier' }
    $barrier.RelayDequeuedForTest = [Threading.ManualResetEventSlim]::new($false)
    $barrier.RelayResumeForTest = [Threading.ManualResetEventSlim]::new($false)
    $receivePowerShell = [PowerShell]::Create()
    $receiveDefinition = (Get-Item function:Receive-ConvexSubscription).Definition
    [void]$receivePowerShell.AddScript("`$script:ConvexControlTimeoutMilliseconds = 4000; function Receive-ConvexSubscription { $receiveDefinition }; Receive-ConvexSubscription `$args[0] `$args[1] 5000")
    [void]$receivePowerShell.AddArgument($live)
    [void]$receivePowerShell.AddArgument($barrier)
    $receiveHandle = $receivePowerShell.BeginInvoke()
    Assert-True ($barrier.RelayDequeuedForTest.Wait(5000)) 'relay did not reach deterministic dequeue barrier'
    Remove-ConvexSubscription $live 'barrier'
    $barrier.RelayResumeForTest.Set() | Out-Null
    Assert-True ($receiveHandle.AsyncWaitHandle.WaitOne(5000)) 'paused stale relay did not finish'
    $stalePublished = $false
    try {
        $stalePublished = @($receivePowerShell.EndInvoke($receiveHandle)).Count -gt 0
    }
    catch {}
    $receivePowerShell.Dispose()
    Assert-True (-not $stalePublished) 'stale relay crossed unsubscribe acknowledgement'

    # The same barrier applies when subscribe replaces an existing ID. The old
    # generation cannot cross the replacement ack even after it already dequeued.
    $oldBarrier = Add-ConvexSubscription $live 'replace-barrier' 'demo:state' @{ room = 'replace-barrier-old' }
    $oldBarrier.RelayDequeuedForTest = [Threading.ManualResetEventSlim]::new($false)
    $oldBarrier.RelayResumeForTest = [Threading.ManualResetEventSlim]::new($false)
    $replacementPowerShell = [PowerShell]::Create()
    [void]$replacementPowerShell.AddScript("`$script:ConvexControlTimeoutMilliseconds = 4000; function Receive-ConvexSubscription { $receiveDefinition }; Receive-ConvexSubscription `$args[0] `$args[1] 5000")
    [void]$replacementPowerShell.AddArgument($live)
    [void]$replacementPowerShell.AddArgument($oldBarrier)
    $replacementHandle = $replacementPowerShell.BeginInvoke()
    Assert-True ($oldBarrier.RelayDequeuedForTest.Wait(5000)) 'replacement relay did not reach dequeue barrier'
    $newBarrier = Add-ConvexSubscription $live 'replace-barrier' 'demo:state' @{ room = 'replace-barrier-new' }
    $oldBarrier.RelayResumeForTest.Set() | Out-Null
    Assert-True ($replacementHandle.AsyncWaitHandle.WaitOne(5000)) 'paused replacement relay did not finish'
    $oldGenerationPublished = $false
    try {
        $oldGenerationPublished = @($replacementPowerShell.EndInvoke($replacementHandle)).Count -gt 0
    }
    catch {}
    $replacementPowerShell.Dispose()
    Assert-True (-not $oldGenerationPublished) 'stale relay crossed same-ID replacement acknowledgement'
    Assert-Equal (Receive-ConvexSubscription $live $newBarrier 5000).value.count 1 'new replacement generation did not deliver'
    Remove-ConvexSubscription $live 'replace-barrier'

    # A real WebSocket close control frame is a TransportError, then the same
    # subscription reconnects and delivers a valid value without being stranded.
    $control = Add-ConvexSubscription $live 'control-close' 'demo:state' @{
        room = 'control-close'
        mode = 'closeControl'
    }
    $controlFailure = Receive-ConvexSubscription $live $control 5000
    Assert-Equal $controlFailure.error.name 'TransportError' 'close control classification'
    $controlRecovery = Receive-ConvexSubscription $live $control 10000
    Assert-Equal $controlRecovery.value.count 1 'close control recovery value'
    Remove-ConvexSubscription $live 'control-close'

    # The peer continuously sends fragmented updates while unsubscribe races it.
    $flood = Add-ConvexSubscription $live 'flood' 'demo:state' @{ room = 'flood'; mode = 'flood' }
    Receive-ConvexSubscription $live $flood 5000 | Out-Null
    Start-Sleep -Milliseconds 100
    $floodTimer = [Diagnostics.Stopwatch]::StartNew()
    Remove-ConvexSubscription $live 'flood'
    $floodTimer.Stop()
    Assert-True ($floodTimer.ElapsedMilliseconds -lt 4000) 'continuously-sending unsubscribe exceeded deadline'

    # Five real disconnects must detach the old socket, acknowledge, resend Add,
    # suppress unchanged hydration, and then deliver the external update.
    $reconnect = Add-ConvexSubscription $live 'reconnect' 'demo:state' @{ room = 'reconnect' }
    $reconnectInitial = Receive-ConvexSubscription $live $reconnect 5000
    $expected = [int]$reconnectInitial.value.count
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $reconnectTimer = [Diagnostics.Stopwatch]::StartNew()
        Disconnect-ConvexLiveForAdapter $live
        Assert-True $live.Owner.HydrationApplied.IsSet "reconnect $attempt did not cross the transition barrier"
        Assert-Equal $live.Owner.HydrationQueryIds.Count 0 "reconnect $attempt left hydration queries pending"
        Assert-Equal $live.Owner.Socket.State ([Net.WebSockets.WebSocketState]::Open) "reconnect $attempt owner was not open at acknowledgement"
        $expected++
        Invoke-ConvexMutation $client 'demo:increment' @{
            room  = 'reconnect'
            runId = "reconnect-$attempt"
        } | Out-Null
        $update = Receive-ConvexSubscription $live $reconnect 10000
        $reconnectTimer.Stop()
        Assert-Equal $update.value.count $expected "reconnect $attempt update"
        Assert-True ($reconnectTimer.ElapsedMilliseconds -lt 2500) "reconnect $attempt inherited stale backoff"
    }
    Remove-ConvexSubscription $live 'reconnect'
    $workerRetention = (Get-ConvexQuery $client 'fixture:reapWorkers' @{ maximum = 0 }).Value
    Assert-Equal $workerRetention.retainedWorkers 0 'completed reconnect fixture workers crossed the lifecycle barrier'
    $metadata = (Get-ConvexQuery $client 'fixture:metadata' @{}).Value
    Assert-True ($metadata.connections -ge 6) 'five reconnects did not create real sockets'
    Assert-True ($metadata.adds -ge 6) 'active Add was not resent after every reconnect'
    Assert-True ($metadata.retainedWorkers -le 2) 'completed reconnect fixture workers were not reaped'
    $connects = @($metadata.connectMessages)
    $debugMessages = @(
        $connects |
            Where-Object { $_.lastCloseReason -eq 'DebugDisconnect' } |
            Select-Object -Last 5
    )
    Assert-True ($debugMessages.Count -ge 5) 'debug reconnect metadata omitted close reason'
    Assert-True ($debugMessages[-1].connectionCount -ge 5) 'connectionCount did not advance'
    Assert-True ($debugMessages[-1].ContainsKey('maxObservedTimestamp')) 'reconnect omitted maxObservedTimestamp'
    $timestampValues = @($debugMessages | ForEach-Object {
            ConvertFrom-FixtureTimestamp $_.maxObservedTimestamp
        })
    for ($index = 1; $index -lt $debugMessages.Count; $index++) {
        Assert-Equal $debugMessages[$index].connectionCount ($debugMessages[$index - 1].connectionCount + 1) 'connectionCount was not monotonic'
        $previousTimestamp = ConvertFrom-FixtureTimestamp $debugMessages[$index - 1].maxObservedTimestamp
        $currentTimestamp = ConvertFrom-FixtureTimestamp $debugMessages[$index].maxObservedTimestamp
        Assert-True ($currentTimestamp -gt $previousTimestamp) 'maxObservedTimestamp did not advance monotonically'
    }

    # Rehydration sends active Adds in query-id order. Identical values are not
    # emitted again, so a reconnect does not create fake subscription updates.
    $orderA = Add-ConvexSubscription $live 'order-a' 'demo:state' @{ room = 'order-a' }
    $orderB = Add-ConvexSubscription $live 'order-b' 'demo:state' @{ room = 'order-b' }
    $orderC = Add-ConvexSubscription $live 'order-c' 'demo:state' @{ room = 'order-c' }
    Receive-ConvexSubscription $live $orderA 5000 | Out-Null
    Receive-ConvexSubscription $live $orderB 5000 | Out-Null
    Receive-ConvexSubscription $live $orderC 5000 | Out-Null
    Disconnect-ConvexLiveForAdapter $live
    Assert-True $live.Owner.HydrationApplied.IsSet 'ordered rehydration transition barrier did not complete'
    Assert-Equal $live.Owner.HydrationQueryIds.Count 0 'ordered rehydration left active query IDs pending'
    Assert-Equal $orderA.Updates.Count 0 'unchanged hydration leaked for order-a'
    Assert-Equal $orderB.Updates.Count 0 'unchanged hydration leaked for order-b'
    Assert-Equal $orderC.Updates.Count 0 'unchanged hydration leaked for order-c'
    $orderMetadata = (Get-ConvexQuery $client 'fixture:metadata' @{}).Value
    $lastAddBatch = @($orderMetadata.addBatches)[-1]
    Assert-Equal (@($lastAddBatch) -join ',') (@($orderA.QueryId, $orderB.QueryId, $orderC.QueryId) -join ',') 'rehydration Add order was not deterministic'
    Remove-ConvexSubscription $live 'order-c'
    Remove-ConvexSubscription $live 'order-b'
    Remove-ConvexSubscription $live 'order-a'

    # Drive twenty distinct real transitions without reading. The queue keeps
    # exactly the newest sixteen, in delivery order, rather than the oldest set.
    $bounded = Add-ConvexSubscription $live 'bounded-newest' 'demo:state' @{ room = 'bounded-newest' }
    Receive-ConvexSubscription $live $bounded 5000 | Out-Null
    $lastBoundedCount = 0
    for ($index = 0; $index -lt 20; $index++) {
        $lastBoundedCount = [int](Invoke-ConvexMutation $client 'demo:increment' @{
                room  = 'bounded-newest'
                runId = "bounded-$index"
            }).Value.state.count
        $deliveryDeadline = [datetime]::UtcNow.AddSeconds(2)
        do {
            [Threading.Monitor]::Enter($live.QueueGate)
            try {
                $queued = @($bounded.Updates.ToArray())
                $deliveredCount = if ($queued.Count) { [int]$queued[-1].Event.value.count } else { -1 }
            }
            finally {
                [Threading.Monitor]::Exit($live.QueueGate)
            }
            if ($deliveredCount -ne $lastBoundedCount) { Start-Sleep -Milliseconds 5 }
        } while ($deliveredCount -ne $lastBoundedCount -and [datetime]::UtcNow -lt $deliveryDeadline)
        Assert-Equal $deliveredCount $lastBoundedCount 'fixture transition did not reach bounded queue'
    }
    [Threading.Monitor]::Enter($live.QueueGate)
    try { $newest = @($bounded.Updates.ToArray()) } finally { [Threading.Monitor]::Exit($live.QueueGate) }
    Assert-Equal $newest.Count 16 'per-subscription queue did not retain exactly newest 16'
    Assert-Equal $newest[0].Event.value.count ($lastBoundedCount - 15) 'bounded queue retained the wrong oldest value'
    Assert-Equal $newest[-1].Event.value.count $lastBoundedCount 'bounded queue retained the wrong newest value'
    Remove-ConvexSubscription $live 'bounded-newest'

    # Count and encoded-byte limits are global across subscriptions, not merely
    # per queue. Large near-frame-limit values cannot push pending memory past 8 MiB.
    for ($index = 0; $index -lt 4; $index++) {
        Add-ConvexSubscription $live "large-$index" 'demo:state' @{
            room = "large-$index"
            mode = 'large'
        } | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert-True ($live.PendingBytes -le 8MB) 'global encoded-byte queue budget exceeded'
    for ($index = 0; $index -lt 70; $index++) {
        Add-ConvexSubscription $live "count-$index" 'demo:state' @{ room = "count-$index" } | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert-True ($live.PendingCount -le 64) 'global event-count queue budget exceeded'
    Assert-True ($live.PendingBytes -le 8MB) 'global byte budget exceeded after count pressure'

    $closeTimer = [Diagnostics.Stopwatch]::StartNew()
    Close-ConvexLive $live
    $closeTimer.Stop()
    Assert-True ($closeTimer.ElapsedMilliseconds -lt 5000) 'bounded close deadline exceeded'

    # This peer accepts TCP but never completes its WebSocket handshake. The
    # ConnectAsync deadline must leave unsubscribe and close bounded.
    $handshakeListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 43141)
    $handshakeListener.Start()
    $handshakeLive = New-ConvexLiveState 'http://127.0.0.1:43141'
    try {
        Add-ConvexSubscription $handshakeLive 'stalled-handshake' 'demo:state' @{} | Out-Null
        Start-Sleep -Milliseconds 100
        $handshakeTimer = [Diagnostics.Stopwatch]::StartNew()
        Remove-ConvexSubscription $handshakeLive 'stalled-handshake'
        $handshakeTimer.Stop()
        Assert-True ($handshakeTimer.ElapsedMilliseconds -lt 4000) 'stalled handshake unsubscribe exceeded deadline'
        $handshakeCloseTimer = [Diagnostics.Stopwatch]::StartNew()
        Close-ConvexLive $handshakeLive
        $handshakeCloseTimer.Stop()
        Assert-True ($handshakeCloseTimer.ElapsedMilliseconds -lt 5000) 'stalled handshake close exceeded deadline'
    }
    finally {
        if (-not $handshakeLive.Closed) { Close-ConvexLive $handshakeLive }
        $handshakeListener.Stop()
    }

    # This peer completes the WebSocket upgrade slowly and then never reads the
    # connection again, so the replayed ModifyQuerySet blocks with a closed
    # receive window. Connect, the initial Connect frame, and that Add all draw
    # on one cumulative owner budget: private per-step timeouts would report the
    # failure only after the upgrade delay plus a whole send timeout.
    $slowState = [hashtable]::Synchronized(@{
            Stop    = $false
            Clients = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
        })
    $slowListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 43145)
    # An explicit small receive buffer on the listening socket is inherited by
    # accepted connections and disables receive-window auto-tuning, so the peer
    # cannot silently absorb the whole Add message in kernel buffers.
    $slowListener.Server.ReceiveBufferSize = 512
    $slowListener.Start()
    $slowPeer = [PowerShell]::Create()
    [void]$slowPeer.AddScript($slowPeerWorker)
    [void]$slowPeer.AddArgument($slowListener)
    [void]$slowPeer.AddArgument(2000)
    [void]$slowPeer.AddArgument($slowState)
    $slowHandle = $slowPeer.BeginInvoke()
    $slowLive = New-ConvexLiveState 'http://127.0.0.1:43145'
    try {
        $slowTimer = [Diagnostics.Stopwatch]::StartNew()
        $slowSubscription = Add-ConvexSubscription $slowLive 'slow-owner' 'demo:state' @{
            room = 'slow-owner'
            blob = 'x' * (2MB)
        }
        $slowFailure = Receive-ConvexSubscription $slowLive $slowSubscription 9000
        $slowTimer.Stop()
        Assert-Equal $slowFailure.error.name 'TransportError' 'slow connect and stalled write classification'
        # Past the 2000 ms upgrade delay proves the owner reached the send phase
        # on the same budget rather than failing during the handshake alone.
        Assert-True ($slowTimer.ElapsedMilliseconds -ge 2500) 'slow peer failed before its blocked send drew on the owner budget'
        Assert-True ($slowTimer.ElapsedMilliseconds -lt 4500) 'connect and sends did not share one cumulative owner deadline'
        $slowCloseTimer = [Diagnostics.Stopwatch]::StartNew()
        Close-ConvexLive $slowLive
        $slowCloseTimer.Stop()
        Assert-True ($slowCloseTimer.ElapsedMilliseconds -lt 5000) 'slow peer close exceeded its bounded deadline'
    }
    finally {
        if (-not $slowLive.Closed) { Close-ConvexLive $slowLive }
        $slowState.Stop = $true
        $slowListener.Stop()
        if (-not $slowHandle.AsyncWaitHandle.WaitOne(5000)) { $slowPeer.Stop() }
        try { $slowPeer.EndInvoke($slowHandle) | Out-Null } catch {}
        $slowPeer.Dispose()
    }
    Write-Output 'PASS PowerShell HTTP and adversarial Live fixtures'
}
finally {
    if ($null -ne $queryIdLive -and -not $queryIdLive.Closed) {
        Close-ConvexLive $queryIdLive
    }
    if (-not $live.Closed) {
        Close-ConvexLive $live
    }
    Stop-Fixture $fixture $client
    Close-ConvexClient $client
}
