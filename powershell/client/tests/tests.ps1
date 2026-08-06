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
    Start-Sleep -Milliseconds 100
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
    $metadata = (Get-ConvexQuery $client 'fixture:metadata' @{}).Value
    Assert-True ($metadata.connections -ge 6) 'five reconnects did not create real sockets'
    Assert-True ($metadata.adds -ge 6) 'active Add was not resent after every reconnect'
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
    Start-Sleep -Milliseconds 500
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
