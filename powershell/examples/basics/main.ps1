#!/usr/bin/pwsh
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../client/Convex.ps1')

function ConvertTo-WholeCount {
    param($Value, [string] $Operation)
    # JSON can represent whole Convex counts as 0.0. Accept only finite, exact
    # whole numbers so the teaching transcript is stable without hiding bad data.
    if ($Value -is [bool] -or $Value -isnot [ValueType]) { throw "$Operation count was not an integral JSON number" }
    $decimal = [decimal]$Value
    if ($decimal -ne [math]::Truncate($decimal) -or $decimal -lt [int]::MinValue -or $decimal -gt [int]::MaxValue) { throw "$Operation count was not an in-range whole number" }
    [int]$decimal
}

# Read the deployment and verifier-provided isolated room from the environment.
if (-not $env:CONVEX_URL) { throw 'CONVEX_URL is required' }
$room = if ($args.Count) { $args[0] } elseif ($env:EXAMPLE_ROOM) { $env:EXAMPLE_ROOM } else { 'powershell-example' }

# Create the native PowerShell client for the verifier's isolated deployment.
$client = New-ConvexClient $env:CONVEX_URL
$live = $null
try {
    # Query first to establish the expected counter value through Convex HTTP.
    $current = ConvertTo-WholeCount (Get-ConvexQuery $client 'demo:state' @{ room = $room }).Value.count 'current query'
    if ($current -ne 0) { throw "current count was $current, expected 0" }
    Write-Output "current count: $current"
    # Subscribe before changing state, so Live proves the initial value as well.
    $live = New-ConvexLiveState $env:CONVEX_URL
    $subscription = Add-ConvexSubscription $live 'basic-counter' 'demo:state' @{ room = $room }
    try {
        $initial = Receive-ConvexSubscription $live $subscription 10000
        if ($initial.ContainsKey('error')) { Throw-ConvexError (New-ConvexError -Name $initial.error.name -Message $initial.error.message -Data $initial.error.data) }
        if ((ConvertTo-WholeCount $initial.value.count 'initial Live value') -ne $current) { throw 'initial Live value disagreed with HTTP' }
        Write-Output "live initial count: $current"
        # A fresh idempotency key means retries cannot apply this logical increment twice.
        $mutation = (Invoke-ConvexMutation $client 'demo:increment' @{ room = $room; language = 'powershell'; runId = [guid]::NewGuid().ToString('N') }).Value
        if ($mutation.applied -ne $true) { throw 'mutation was not applied' }
        Write-Output 'mutation applied: true'
        $expected = $current + 1
        if ((ConvertTo-WholeCount $mutation.state.count 'mutation') -ne $expected) { throw 'mutation count disagreed' }
        Write-Output "mutation count: $expected"
        $updated = Receive-ConvexSubscription $live $subscription 10000
        if ($updated.ContainsKey('error')) { Throw-ConvexError (New-ConvexError -Name $updated.error.name -Message $updated.error.message -Data $updated.error.data) }
        if ((ConvertTo-WholeCount $updated.value.count 'updated Live value') -ne $expected) { throw 'updated Live count disagreed' }
        Write-Output "live updated count: $expected"
        Write-Output "verified count: $current -> $expected"
    }
    # Retire the subscription before disposing its one Live socket owner.
    finally { Remove-ConvexSubscription $live 'basic-counter' }
}
# Close both clients even when an assertion above finds unexpected Convex data.
finally { if ($live) { Close-ConvexLive $live }; Close-ConvexClient $client }
