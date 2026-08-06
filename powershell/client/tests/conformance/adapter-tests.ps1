Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ExactKeys([hashtable] $Value, [string[]] $Expected, [string] $Message) {
    $actualKeys = @($Value.Keys | Sort-Object)
    $expectedKeys = @($Expected | Sort-Object)
    Assert-True (($actualKeys -join ',') -eq ($expectedKeys -join ',')) (
        "$Message. expected=$($expectedKeys -join ',') actual=$($actualKeys -join ',')"
    )
}

function Start-Fixture([int] $Port) {
    $ready = "/tmp/powershell-adapter-fixture-$Port.ready"
    [IO.File]::Delete($ready)
    $process = Start-Process pwsh -ArgumentList @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot '../fixture-server.ps1'),
        '-Port', [string]$Port, '-ReadyFile', $ready
    ) -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($ready) -and [datetime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw "adapter fixture exited early: $($process.ExitCode)" }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ([IO.File]::Exists($ready)) 'adapter fixture did not become ready'
    [pscustomobject]@{ Process = $process; Url = "http://127.0.0.1:$Port" }
}

function Stop-Fixture($Fixture) {
    try {
        $http = [Net.Http.HttpClient]::new()
        $content = [Net.Http.StringContent]::new(
            '{"path":"fixture:shutdown","args":{},"format":"json"}',
            [Text.Encoding]::UTF8,
            'application/json'
        )
        $http.PostAsync("$($Fixture.Url)/api/query", $content).GetAwaiter().GetResult().Dispose()
        $content.Dispose()
        $http.Dispose()
    }
    catch {}
    if (-not $Fixture.Process.WaitForExit(5000)) { $Fixture.Process.Kill($true) }
}

function Start-Adapter([string] $Url, [string] $Listen = '') {
    $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
    $start.ArgumentList.Add('-NoLogo')
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-File')
    $start.ArgumentList.Add((Join-Path $PSScriptRoot 'adapter.ps1'))
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = -not $Listen
    $start.RedirectStandardOutput = -not $Listen
    $start.RedirectStandardError = $true
    $start.Environment['CONVEX_URL'] = $Url
    if ($Listen) { $start.Environment['ADAPTER_LISTEN'] = $Listen }
    $process = [Diagnostics.Process]::Start($start)
    $script:LastAdapterProcess = $process
    $process
}

function Read-LineBefore($Reader, [int] $Milliseconds = 4000) {
    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($Milliseconds)) {
        if ($script:LastAdapterProcess.HasExited) {
            throw "adapter exited $($script:LastAdapterProcess.ExitCode): $($script:LastAdapterProcess.StandardError.ReadToEnd())"
        }
        throw 'adapter output deadline expired while process remained alive'
    }
    $line = $task.GetAwaiter().GetResult()
    if ($null -eq $line) { throw 'adapter output reached EOF unexpectedly' }
    $line | ConvertFrom-Json -AsHashtable -Depth 64
}

function Send-Line($Process, [string] $Line) {
    $Process.StandardInput.WriteLine($Line)
    $Process.StandardInput.Flush()
}

function Assert-ProtocolCommandRejected($Process, [string] $Command, [string] $Name) {
    Send-Line $Process $Command
    $event = Read-LineBefore $Process.StandardOutput
    Assert-True ($event.type -eq 'error') "$Name did not emit an error event"
    Assert-True ($event.error.name -eq 'ProtocolError') "$Name was not ProtocolError"
    Assert-ExactKeys $event @('error', 'type') "$Name emitted optional fields for invalid input"
}

function Connect-Adapter([int] $Port) {
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while ([datetime]::UtcNow -lt $deadline) {
        $tcp = [Net.Sockets.TcpClient]::new()
        try {
            $tcp.Connect('127.0.0.1', $Port)
            return $tcp
        }
        catch {
            $tcp.Dispose()
            Start-Sleep -Milliseconds 20
        }
    }
    throw 'TCP adapter did not listen before deadline'
}

function Read-RawLine([Net.Sockets.NetworkStream] $Stream) {
    $Stream.ReadTimeout = 4000
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'TCP adapter reached EOF before newline' }
        if ($value -eq 10) { break }
        $bytes.Add([byte]$value)
    }
    [byte[]]$bytes.ToArray()
}

function Send-TcpCommand([Net.Sockets.NetworkStream] $Stream, [hashtable] $Command) {
    # Keep the lifecycle regression on the real bounded TCP NDJSON transport.
    # It must not accidentally exercise the easier stdin adapter path.
    $json = $Command | ConvertTo-Json -Compress -Depth 64
    $bytes = [Text.Encoding]::UTF8.GetBytes("$json`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-TcpEvent([Net.Sockets.NetworkStream] $Stream) {
    $text = [Text.Encoding]::UTF8.GetString((Read-RawLine $Stream))
    $event = $text | ConvertFrom-Json -AsHashtable -Depth 64
    if ($event -isnot [Collections.IDictionary]) {
        $eventType = if ($null -eq $event) { 'null' } else { $event.GetType().FullName }
        throw "TCP adapter emitted a non-object event ($eventType): $text"
    }
    $event
}

$fixture = Start-Fixture 43138
try {
    # Stdin mode keeps malformed input as structured ProtocolError events, keeps
    # single log lines as JSON arrays, and cleans up after a complete close.
    $adapter = Start-Adapter $fixture.Url
    $longId = 'i' * 129
    $longSubscriptionId = 's' * 129
    $invalidCommands = [ordered]@{
        'malformed JSON'              = '{'
        'array root'                  = '[]'
        'null root'                   = 'null'
        'scalar root'                 = '42'
        'string root'                 = '"command"'
        'missing operation and ID'    = '{}'
        'null operation'              = '{"protocolVersion":1,"id":"bad","op":null}'
        'boolean operation'           = '{"protocolVersion":1,"id":"bad","op":true}'
        'unknown operation'           = '{"id":"bad","op":"unknown"}'
        'numeric ID'                  = '{"protocolVersion":1,"id":12,"op":"hello"}'
        'null ID'                     = '{"protocolVersion":1,"id":null,"op":"hello"}'
        'empty ID'                    = '{"protocolVersion":1,"id":"","op":"hello"}'
        'overlong ID'                 = (@{ protocolVersion = 1; id = $longId; op = 'hello' } | ConvertTo-Json -Compress)
        'hello missing version'       = '{"id":"bad","op":"hello"}'
        'hello null version'          = '{"protocolVersion":null,"id":"bad","op":"hello"}'
        'hello string version'        = '{"protocolVersion":"1","id":"bad","op":"hello"}'
        'hello boolean version'       = '{"protocolVersion":true,"id":"bad","op":"hello"}'
        'hello wrong version'         = '{"protocolVersion":2,"id":"bad","op":"hello"}'
        'hello extra field'           = '{"protocolVersion":1,"id":"bad","op":"hello","extra":true}'
        'query missing args'          = '{"id":"bad","op":"query","path":"demo:echo"}'
        'query null path'             = '{"id":"bad","op":"query","path":null,"args":{}}'
        'query numeric path'          = '{"id":"bad","op":"query","path":12,"args":{}}'
        'query short path'            = '{"id":"bad","op":"query","path":"ab","args":{}}'
        'mutation array args'         = '{"id":"bad","op":"mutation","path":"demo:increment","args":[]}'
        'action null args'            = '{"id":"bad","op":"action","path":"demo:greet","args":null}'
        'action extra field'          = '{"id":"bad","op":"action","path":"demo:greet","args":{},"extra":true}'
        'subscribe missing path'      = '{"id":"bad","op":"subscribe","subscriptionId":"sub","args":{}}'
        'subscribe null args'         = '{"id":"bad","op":"subscribe","subscriptionId":"sub","path":"demo:state","args":null}'
        'subscribe numeric ID'        = '{"id":"bad","op":"subscribe","subscriptionId":12,"path":"demo:state","args":{}}'
        'subscribe null ID'           = '{"id":"bad","op":"subscribe","subscriptionId":null,"path":"demo:state","args":{}}'
        'subscribe empty ID'          = '{"id":"bad","op":"subscribe","subscriptionId":"","path":"demo:state","args":{}}'
        'subscribe overlong ID'       = (@{ id = 'bad'; op = 'subscribe'; subscriptionId = $longSubscriptionId; path = 'demo:state'; args = @{} } | ConvertTo-Json -Compress)
        'subscribe extra field'       = '{"id":"bad","op":"subscribe","subscriptionId":"sub","path":"demo:state","args":{},"extra":true}'
        'unsubscribe missing ID'      = '{"id":"bad","op":"unsubscribe"}'
        'unsubscribe extra path'      = '{"id":"bad","op":"unsubscribe","subscriptionId":"sub","path":"demo:state"}'
        'setAuth missing token'       = '{"id":"bad","op":"setAuth"}'
        'setAuth null token'          = '{"id":"bad","op":"setAuth","token":null}'
        'setAuth numeric token'       = '{"id":"bad","op":"setAuth","token":12}'
        'setAuth extra field'         = '{"id":"bad","op":"setAuth","token":"","extra":true}'
        'close extra field'           = '{"id":"bad","op":"close","extra":true}'
        'debugDisconnect missing ID'  = '{"op":"debugDisconnect"}'
        'debugDisconnect extra field' = '{"id":"bad","op":"debugDisconnect","extra":true}'
    }
    foreach ($entry in $invalidCommands.GetEnumerator()) {
        Assert-ProtocolCommandRejected $adapter $entry.Value $entry.Key
    }
    Send-Line $adapter ('x' * 66000)
    $overflow = Read-LineBefore $adapter.StandardOutput
    Assert-True ($overflow.error.name -eq 'ProtocolError') 'oversized partial NDJSON was not ProtocolError'
    Assert-ExactKeys $overflow @('error', 'type') 'oversized NDJSON emitted optional fields'
    Send-Line $adapter '{"protocolVersion":1,"id":"hello","op":"hello"}'
    $ready = Read-LineBefore $adapter.StandardOutput
    Assert-True ($ready.type -eq 'ready') 'stdin hello failed after malformed input'
    Assert-ExactKeys $ready @('protocolVersion', 'id', 'type', 'language', 'implementation', 'runtime') 'ready event shape'
    Send-Line $adapter '{"id":"auth","op":"setAuth","token":""}'
    $auth = Read-LineBefore $adapter.StandardOutput
    Assert-True ($auth.type -eq 'ack') 'setAuth failed after ProtocolError recovery'
    Assert-ExactKeys $auth @('id', 'type') 'setAuth acknowledgement shape'
    Send-Line $adapter '{"id":"action","op":"action","path":"demo:greet","args":{}}'
    $action = Read-LineBefore $adapter.StandardOutput
    Assert-True ($action.value.message -eq 'Convex is responding from fixture') 'valid action command failed'
    Assert-ExactKeys $action @('id', 'type', 'value') 'result without logs shape'
    Send-Line $adapter '{"id":"q","op":"query","path":"demo:echo","args":{"value":"ok"}}'
    $query = Read-LineBefore $adapter.StandardOutput
    Assert-True ($query.value -eq 'ok') 'stdin query did not use real client'
    Assert-True ($query.logs -is [array] -and $query.logs.Count -eq 1) 'adapter collapsed one HTTP log to a scalar'
    Assert-ExactKeys $query @('id', 'type', 'value', 'logs') 'result with logs shape'
    Send-Line $adapter '{"id":"f","op":"query","path":"demo:fail","args":{"code":"EXPECTED"}}'
    $failure = Read-LineBefore $adapter.StandardOutput
    Assert-True ($failure.error.name -eq 'FunctionError') 'adapter flattened FunctionError'
    Assert-True ($failure.logs -is [array] -and $failure.logs.Count -eq 1) 'adapter collapsed one error log to a scalar'
    Assert-ExactKeys $failure @('id', 'type', 'error', 'logs') 'structured HTTP error shape'
    Send-Line $adapter '{"id":"sub","op":"subscribe","subscriptionId":"recover","path":"demo:requiresNonzero","args":{"room":"adapter"}}'
    Assert-True ((Read-LineBefore $adapter.StandardOutput).type -eq 'ack') 'subscribe ack failed'
    $subscriptionFailure = Read-LineBefore $adapter.StandardOutput
    Assert-True ($subscriptionFailure.subscriptionId -eq 'recover') 'subscription failure omitted ID'
    Assert-True ($subscriptionFailure.error.name -eq 'FunctionError') 'QueryFailed adapter classification'
    Assert-True ($subscriptionFailure.logs -is [array] -and $subscriptionFailure.logs.Count -eq 1) 'adapter collapsed one subscription log to a scalar'
    Assert-ExactKeys $subscriptionFailure @('type', 'subscriptionId', 'error', 'logs') 'subscription error shape'
    Send-Line $adapter '{"id":"mutate","op":"mutation","path":"demo:increment","args":{"room":"adapter","runId":"recover"}}'
    Assert-True ((Read-LineBefore $adapter.StandardOutput).type -eq 'result') 'recovery mutation failed'
    $subscriptionRecovery = Read-LineBefore $adapter.StandardOutput
    Assert-True ($subscriptionRecovery.value.count -eq 1) 'subscription did not recover after QueryFailed'
    Assert-ExactKeys $subscriptionRecovery @('type', 'subscriptionId', 'value', 'logs') 'subscription value shape'
    Send-Line $adapter '{"id":"unsub","op":"unsubscribe","subscriptionId":"recover"}'
    Assert-True ((Read-LineBefore $adapter.StandardOutput).type -eq 'ack') 'unsubscribe ack failed'
    Send-Line $adapter '{"id":"close","op":"close"}'
    $closed = Read-LineBefore $adapter.StandardOutput
    Assert-True ($closed.type -eq 'closed') 'stdin close failed'
    Assert-ExactKeys $closed @('id', 'type') 'closed event shape'
    $adapter.StandardInput.Close()
    Assert-True ($adapter.WaitForExit(4000)) 'stdin adapter did not exit after close'
    Assert-True ($adapter.ExitCode -eq 0) "stdin adapter exit was $($adapter.ExitCode)"

    # A final command without a trailing newline is still processed before EOF,
    # then every client and reader is disposed and the process exits.
    $eofAdapter = Start-Adapter $fixture.Url
    $eofAdapter.StandardInput.Write('{"protocolVersion":1,"id":"eof","op":"hello"}')
    $eofAdapter.StandardInput.Close()
    Assert-True ((Read-LineBefore $eofAdapter.StandardOutput).type -eq 'ready') 'partial final command was lost at EOF'
    Assert-True ($eofAdapter.WaitForExit(4000)) 'adapter did not clean up after input EOF'

    $liveEofAdapter = Start-Adapter $fixture.Url
    Send-Line $liveEofAdapter '{"id":"eof-sub","op":"subscribe","subscriptionId":"eof-live","path":"demo:state","args":{"room":"eof-live"}}'
    $liveEofAdapter.StandardInput.Close()
    Assert-True ($liveEofAdapter.WaitForExit(5000)) 'adapter did not clean up live state after EOF'
    Assert-True ($liveEofAdapter.ExitCode -eq 0) 'live EOF cleanup failed'

    # TCP mode is inspected as bytes so a StreamWriter preamble can never hide
    # behind JSON parsing. Both the request and response are deliberately split.
    $tcpAdapter = Start-Adapter $fixture.Url '127.0.0.1:43139'
    $tcp = Connect-Adapter 43139
    $stream = $tcp.GetStream()
    $helloBytes = [Text.Encoding]::UTF8.GetBytes("{`"protocolVersion`":1,`"id`":`"tcp`",`"op`":`"hello`"}`n")
    $stream.Write($helloBytes, 0, 7)
    Start-Sleep -Milliseconds 10
    $stream.Write($helloBytes, 7, $helloBytes.Length - 7)
    $raw = Read-RawLine $stream
    Assert-True (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'TCP NDJSON response started with a UTF-8 BOM'
    $ready = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json -AsHashtable
    Assert-True ($ready.type -eq 'ready') 'TCP hello did not produce ready'
    $closeBytes = [Text.Encoding]::UTF8.GetBytes("{`"id`":`"close`",`"op`":`"close`"}`n")
    $stream.Write($closeBytes, 0, $closeBytes.Length)
    Assert-True (([Text.Encoding]::UTF8.GetString((Read-RawLine $stream)) | ConvertFrom-Json -AsHashtable).type -eq 'closed') 'TCP close failed'
    $tcp.Dispose()
    Assert-True ($tcpAdapter.WaitForExit(4000)) 'TCP adapter did not exit after close'

    # The pilot keeps one TCP controller attached while it runs every HTTP and
    # Live case. Cover the tail of that sequence here: five genuine reconnects
    # followed by QueryFailed recovery must leave the adapter listening for a
    # later command. It may exit only after this explicit close command.
    # This needs a fresh fixture because the earlier HTTP tests deliberately
    # increment their shared counter before reaching the TCP lifecycle case.
    $lifecycleFixture = Start-Fixture 43143
    $longLivedAdapter = Start-Adapter $lifecycleFixture.Url '127.0.0.1:43142'
    $longLivedTcp = Connect-Adapter 43142
    $longLivedStream = $longLivedTcp.GetStream()
    Send-TcpCommand $longLivedStream @{ protocolVersion = 1; id = 'long-hello'; op = 'hello' }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ready') 'long-lived TCP hello failed'
    Send-TcpCommand $longLivedStream @{
        id = 'long-recovery-subscribe'; op = 'subscribe'; subscriptionId = 'long-recovery'
        path = 'demo:requiresNonzero'; args = @{ room = 'long-recovery' }
    }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') 'long-lived recovery subscribe failed'
    $recoveryFailure = Read-TcpEvent $longLivedStream
    Assert-True ($recoveryFailure.error.name -eq 'FunctionError') 'long-lived QueryFailed was not delivered'
    Send-TcpCommand $longLivedStream @{
        id = 'long-recovery-mutation'; op = 'mutation'; path = 'demo:increment'
        args = @{ room = 'long-recovery'; runId = 'long-recovery-run' }
    }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'result') 'long-lived recovery mutation failed'
    Assert-True ((Read-TcpEvent $longLivedStream).value.count -eq 1) 'long-lived QueryFailed did not recover'
    Send-TcpCommand $longLivedStream @{ id = 'long-recovery-unsubscribe'; op = 'unsubscribe'; subscriptionId = 'long-recovery' }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') 'long-lived recovery unsubscribe failed'
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $room = "long-reconnect-$attempt"
        $subscriptionId = "long-subscription-$attempt"
        Send-TcpCommand $longLivedStream @{
            id = "long-subscribe-$attempt"; op = 'subscribe'; subscriptionId = $subscriptionId
            path = 'demo:state'; args = @{ room = $room }
        }
        Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') "long-lived subscribe $attempt failed"
        $initialEvent = Read-TcpEvent $longLivedStream
        Assert-True ($initialEvent.value.count -eq $attempt) "long-lived initial value $attempt failed: $($initialEvent | ConvertTo-Json -Compress -Depth 64)"
        Send-TcpCommand $longLivedStream @{ id = "long-disconnect-$attempt"; op = 'debugDisconnect' }
        Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') "long-lived disconnect $attempt failed"
        Send-TcpCommand $longLivedStream @{
            id = "long-mutation-$attempt"; op = 'mutation'; path = 'demo:increment'
            args = @{ room = $room; runId = "long-run-$attempt" }
        }
        Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'result') "long-lived mutation $attempt failed"
        Assert-True ((Read-TcpEvent $longLivedStream).value.count -eq ($attempt + 1)) "long-lived reconnect update $attempt failed"
        Send-TcpCommand $longLivedStream @{ id = "long-unsubscribe-$attempt"; op = 'unsubscribe'; subscriptionId = $subscriptionId }
        Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') "long-lived unsubscribe $attempt failed"
    }
    # Mirror the hosted boundary exactly: after a real initial result and
    # external update, unsubscribe-64 must acknowledge while the TCP adapter
    # remains available for a later ordinary command and final close.
    Send-TcpCommand $longLivedStream @{
        id = 'client-subscribe'; op = 'subscribe'; subscriptionId = 'client-unsubscribe'
        path = 'demo:state'; args = @{ room = 'client-unsubscribe' }
    }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') 'client-unsubscribe subscribe failed'
    Assert-True ((Read-TcpEvent $longLivedStream).value.count -eq 6) 'client-unsubscribe initial value failed'
    Send-TcpCommand $longLivedStream @{
        id = 'client-mutation'; op = 'mutation'; path = 'demo:increment'
        args = @{ room = 'client-unsubscribe'; runId = 'client-unsubscribe' }
    }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'result') 'client-unsubscribe mutation failed'
    Assert-True ((Read-TcpEvent $longLivedStream).value.count -eq 7) 'client-unsubscribe external update failed'
    Send-TcpCommand $longLivedStream @{ id = 'unsubscribe-64'; op = 'unsubscribe'; subscriptionId = 'client-unsubscribe' }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'ack') 'unsubscribe-64 acknowledgement failed'
    Start-Sleep -Milliseconds 250
    Assert-True (-not $longLivedAdapter.HasExited) 'long-lived adapter exited before explicit close'
    Send-TcpCommand $longLivedStream @{ id = 'long-echo'; op = 'query'; path = 'demo:echo'; args = @{ value = 'still-listening' } }
    $echo = Read-TcpEvent $longLivedStream
    Assert-True ($echo.type -eq 'result' -and $echo.value -eq 'still-listening') 'long-lived adapter stopped accepting commands'
    Send-TcpCommand $longLivedStream @{ id = 'long-close'; op = 'close' }
    Assert-True ((Read-TcpEvent $longLivedStream).type -eq 'closed') 'long-lived TCP close failed'
    $longLivedTcp.Dispose()
    Assert-True ($longLivedAdapter.WaitForExit(5000)) 'long-lived adapter did not exit after explicit close'
    Assert-True ($longLivedAdapter.ExitCode -eq 0) "long-lived adapter exit was $($longLivedAdapter.ExitCode)"
    Stop-Fixture $lifecycleFixture

    # A controller that stops reading must not grow an unbounded adapter queue.
    # The direct network writer hits its one-second write deadline and cleanup
    # terminates the process instead of retaining more result events.
    $blockedAdapter = Start-Adapter $fixture.Url '127.0.0.1:43140'
    $blockedTcp = Connect-Adapter 43140
    $blockedTcp.SendTimeout = 2000
    $blockedTcp.ReceiveBufferSize = 1024
    $blockedStream = $blockedTcp.GetStream()
    try {
        for ($index = 0; $index -lt 64; $index++) {
            $command = @{ id = "blocked-$index"; op = 'query'; path = 'fixture:backpressure'; args = @{} } |
                ConvertTo-Json -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes("$command`n")
            $blockedStream.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        # Either side may observe the deadline first. Process termination below is
        # the invariant, not which kernel buffer reports the broken connection.
    }
    if (-not $blockedAdapter.WaitForExit(8000)) {
        $blockedAdapter.Kill($true)
        $blockedAdapter.WaitForExit()
        throw "stopped-reader adapter exceeded its write/cleanup deadline: $($blockedAdapter.StandardError.ReadToEnd())"
    }
    Assert-True ($blockedAdapter.ExitCode -ne 0) 'stopped-reader adapter silently retained output'
    $blockedError = $blockedAdapter.StandardError.ReadToEnd()
    Assert-True ($blockedError.Contains('reserved output bytes after release: 0')) "stopped-reader adapter did not release its output reservation exactly: $blockedError"
    $blockedTcp.Dispose()

    Write-Output 'PASS PowerShell adapter NDJSON, EOF, TCP, and backpressure fixtures'
}
finally {
    Stop-Fixture $fixture
}
