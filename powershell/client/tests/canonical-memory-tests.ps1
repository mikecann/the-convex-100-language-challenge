Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expected = @(
    'current count: 0',
    'live initial count: 0',
    'mutation applied: true',
    'mutation count: 1',
    'live updated count: 1',
    'verified count: 0 -> 1'
)
$port = 43142
$ready = "/tmp/powershell-canonical-memory-$port.ready"
[IO.File]::Delete($ready)

# The final runtime caps the CLR heap at 64 MiB inside the verifier's 128 MiB
# cgroup. Exercise the exact teaching program with those inherited settings so
# an allocation peak after Live's initial value cannot return unnoticed.
$fixture = Start-Process pwsh -ArgumentList @(
    '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixture-server.ps1'),
    '-Port', [string]$port, '-ReadyFile', $ready
) -PassThru

try {
    $readyDeadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($ready) -and [datetime]::UtcNow -lt $readyDeadline) {
        if ($fixture.HasExited) { throw "memory fixture exited early: $($fixture.ExitCode)" }
        Start-Sleep -Milliseconds 20
    }
    if (-not [IO.File]::Exists($ready)) { throw 'memory fixture did not become ready' }

    $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
    $start.ArgumentList.Add('-NoLogo')
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-File')
    $start.ArgumentList.Add((Join-Path $PSScriptRoot '../../examples/basics/main.ps1'))
    $start.ArgumentList.Add('canonical-memory')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CONVEX_URL'] = "http://127.0.0.1:$port"
    $example = [Diagnostics.Process]::Start($start)
    $stdout = $example.StandardOutput.ReadToEndAsync()
    $stderr = $example.StandardError.ReadToEndAsync()
    if (-not $example.WaitForExit(12000)) { $example.Kill($true); throw 'canonical example exceeded its memory-regression deadline' }
    $output = @($stdout.GetAwaiter().GetResult().TrimEnd("`r", "`n") -split "`r?`n")
    if ($example.ExitCode -ne 0) { throw "canonical example exited $($example.ExitCode): $($stderr.GetAwaiter().GetResult())" }
    if (@(Compare-Object $expected $output -SyncWindow 0).Count -ne 0) { throw "canonical transcript changed: $($output -join ' | ')" }
    Write-Output 'PASS PowerShell canonical example stays within the runtime heap budget'
}
finally {
    try {
        $http = [Net.Http.HttpClient]::new()
        $body = [Net.Http.StringContent]::new('{"path":"fixture:shutdown","args":{},"format":"json"}', [Text.Encoding]::UTF8, 'application/json')
        $http.PostAsync("http://127.0.0.1:$port/api/query", $body).GetAwaiter().GetResult().Dispose()
        $body.Dispose()
        $http.Dispose()
    }
    catch {}
    if (-not $fixture.WaitForExit(5000)) { $fixture.Kill($true) }
}
