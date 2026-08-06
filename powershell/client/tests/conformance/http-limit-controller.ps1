param(
    [string] $AdapterHost = 'powershell-http-adapter',
    [int] $AdapterPort = 43145,
    [string] $StateDirectory = '/state'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixtureReady = Join-Path $StateDirectory 'http-fixture-ready'
$resultFile = Join-Path $StateDirectory 'http-controller-result'
[IO.File]::Delete($fixtureReady)
[IO.File]::Delete($resultFile)

function Connect-Adapter {
    $deadline = [datetime]::UtcNow.AddSeconds(8)
    while ([datetime]::UtcNow -lt $deadline) {
        $candidate = [Net.Sockets.TcpClient]::new()
        try {
            $candidate.Connect($AdapterHost, $AdapterPort)
            return $candidate
        }
        catch {
            $candidate.Dispose()
            Start-Sleep -Milliseconds 20
        }
    }
    throw 'HTTP limit controller could not connect to final adapter'
}

function Send-Command([Net.Sockets.NetworkStream] $Stream, [hashtable] $Command) {
    $json = $Command | ConvertTo-Json -Compress -Depth 64
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes("$json`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-Event([Net.Sockets.NetworkStream] $Stream) {
    $Stream.ReadTimeout = 15000
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $next = $Stream.ReadByte()
        if ($next -lt 0) { throw 'final adapter closed before completing an NDJSON event' }
        if ($next -eq 10) { break }
        $bytes.Add([byte]$next)
    }
    [Text.Encoding]::UTF8.GetString($bytes.ToArray()) |
        ConvertFrom-Json -AsHashtable -Depth 64
}

# The raw fixture streams just over 8 MiB in small chunks and deliberately
# takes roughly one second to do it. It shares only the controller cgroup. The
# final adapter has its own 128 MiB cap, so fixture allocations cannot hide an
# adapter memory regression.
$fixture = Start-Process pwsh -ArgumentList @(
    '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot '../http-fixture-server.ps1'),
    '-Port', '43144', '-ReadyFile', $fixtureReady, '-BindHost', '0.0.0.0'
) -PassThru
$tcp = $null
try {
    $readyDeadline = [datetime]::UtcNow.AddSeconds(8)
    while (-not [IO.File]::Exists($fixtureReady) -and [datetime]::UtcNow -lt $readyDeadline) {
        if ($fixture.HasExited) { throw "HTTP limit fixture exited $($fixture.ExitCode)" }
        Start-Sleep -Milliseconds 20
    }
    if (-not [IO.File]::Exists($fixtureReady)) { throw 'HTTP limit fixture did not become ready' }

    $tcp = Connect-Adapter
    $stream = $tcp.GetStream()
    Send-Command $stream @{ protocolVersion = 1; id = 'http-limit-hello'; op = 'hello' }
    $ready = Read-Event $stream
    if ($ready.type -ne 'ready') { throw 'final adapter did not become ready' }

    Send-Command $stream @{
        id = 'http-limit'; op = 'query'; path = 'fixture:httpSlowOverLimit'; args = @{}
    }
    $failure = Read-Event $stream
    if ($failure.type -ne 'error' -or $failure.error.name -ne 'TransportError') {
        throw "slow over-limit HTTP response was not TransportError: $($failure | ConvertTo-Json -Compress -Depth 64)"
    }

    # The same process and controller connection must still work. This rules
    # out OOM, controller teardown, or process death as a false success signal.
    Send-Command $stream @{
        id = 'http-recovery'; op = 'query'; path = 'fixture:httpRecovery'; args = @{}
    }
    $recovery = Read-Event $stream
    if ($recovery.type -ne 'result' -or -not $recovery.value.recovered) {
        throw "final adapter did not recover after the bounded HTTP failure: $($recovery | ConvertTo-Json -Compress -Depth 64)"
    }

    Send-Command $stream @{ id = 'http-limit-close'; op = 'close' }
    $closed = Read-Event $stream
    if ($closed.type -ne 'closed') { throw 'final adapter did not close cleanly after HTTP recovery' }
    [IO.File]::WriteAllText($resultFile, 'PASS', [Text.UTF8Encoding]::new($false))
}
finally {
    if ($null -ne $tcp) { $tcp.Dispose() }
    try {
        $http = [Net.Http.HttpClient]::new()
        $body = [Net.Http.StringContent]::new(
            '{"path":"fixture:httpShutdown","args":{},"format":"json"}',
            [Text.Encoding]::UTF8,
            'application/json'
        )
        $http.PostAsync('http://127.0.0.1:43144/api/query', $body).GetAwaiter().GetResult().Dispose()
        $body.Dispose()
        $http.Dispose()
    }
    catch {}
    if (-not $fixture.WaitForExit(5000)) { $fixture.Kill($true) }
}
