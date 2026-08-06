param(
    [string] $AdapterHost = 'powershell-adapter',
    [int] $AdapterPort = 43140,
    [string] $StateDirectory = '/state'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixtureReady = Join-Path $StateDirectory 'fixture-ready'
$commandsSent = Join-Path $StateDirectory 'commands-sent'
$stopFile = Join-Path $StateDirectory 'stop-controller'
[IO.File]::Delete($fixtureReady)
[IO.File]::Delete($commandsSent)

# The fixture and stopped reader intentionally share the controller's 256 MiB
# cgroup. The real final adapter runs separately under the verifier's 128 MiB
# limit, so controller allocations cannot make its memory result look better.
$fixture = Start-Process pwsh -ArgumentList @(
    '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot '../fixture-server.ps1'),
    '-Port', '43138', '-ReadyFile', $fixtureReady, '-BindHost', '+',
    '-NearMaximumServedFile', (Join-Path $StateDirectory 'near-maximum-served')
) -PassThru
$tcp = $null
try {
    $readyDeadline = [datetime]::UtcNow.AddSeconds(8)
    while (-not [IO.File]::Exists($fixtureReady) -and [datetime]::UtcNow -lt $readyDeadline) {
        if ($fixture.HasExited) { throw "stopped-reader fixture exited $($fixture.ExitCode)" }
        Start-Sleep -Milliseconds 20
    }
    if (-not [IO.File]::Exists($fixtureReady)) { throw 'stopped-reader fixture did not become ready' }

    $connectDeadline = [datetime]::UtcNow.AddSeconds(8)
    while ($null -eq $tcp -and [datetime]::UtcNow -lt $connectDeadline) {
        $candidate = [Net.Sockets.TcpClient]::new()
        try {
            $candidate.Connect($AdapterHost, $AdapterPort)
            $tcp = $candidate
        }
        catch {
            $candidate.Dispose()
            Start-Sleep -Milliseconds 20
        }
    }
    if ($null -eq $tcp) { throw 'stopped-reader controller could not connect to adapter' }
    $tcp.ReceiveBufferSize = 1024
    $tcp.SendTimeout = 2000
    $stream = $tcp.GetStream()

    # Queue ordinary tiny commands before the first near-limit HTTP response is
    # encoded. The controller never reads a byte from this stream. It also stays
    # connected until the host records the adapter's exit and memory. That makes
    # controller teardown unavailable as a false source of backpressure success.
    for ($index = 0; $index -lt 12; $index++) {
        $command = @{ id = "stopped-reader-$index"; op = 'query'; path = 'fixture:nearMaximum'; args = @{} } |
            ConvertTo-Json -Compress
        [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes("$command`n")
        $stream.Write($bytes, 0, $bytes.Length)
    }
    [IO.File]::WriteAllText($commandsSent, 'sent', [Text.UTF8Encoding]::new($false))

    while (-not [IO.File]::Exists($stopFile)) {
        # The fixture may observe the adapter retiring its HTTP connection.
        # That must not tear down the still-unread controller TCP connection.
        Start-Sleep -Milliseconds 20
    }
}
finally {
    # This runs only after the host has already captured the adapter outcome.
    # Until then the controller socket remains connected and unread.
    if ($null -ne $tcp) { $tcp.Dispose() }
    try {
        $http = [Net.Http.HttpClient]::new()
        $body = [Net.Http.StringContent]::new(
            '{"path":"fixture:shutdown","args":{},"format":"json"}',
            [Text.Encoding]::UTF8,
            'application/json'
        )
        $http.PostAsync('http://127.0.0.1:43138/api/query', $body).GetAwaiter().GetResult().Dispose()
        $body.Dispose()
        $http.Dispose()
    }
    catch {}
    if (-not $fixture.WaitForExit(5000)) { $fixture.Kill($true) }
}
