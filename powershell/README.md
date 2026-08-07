# Convex from PowerShell

This small PowerShell client calls a Convex function over HTTP, then follows the same counter through the experimental Live sync profile.

It is educational and unofficial, not a production SDK or a supported Convex package.

## Start here

The [canonical basic example](examples/basics/main.ps1) makes the counter's `0 -> 1` journey: HTTP query, initial Live value, idempotent mutation, and the Live update caused by that mutation.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, pending shared evidence |
| Pinned `/api/sync` Live reads | Implemented, pending shared evidence |
| Capability badges | None earned yet |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ps1 -->
```text
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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test powershell
./run build powershell
```

The first command formats/parses and runs deterministic client and adapter checks in an amd64 PowerShell container. The second builds the final non-root runtime image. Root-owned verification separately runs the canonical example and shared local and hosted conformance.

## Conformance and protocol notes

`/usr/local/bin/convex-adapter` implements NDJSON protocol v1 through stdin/stdout or `ADAPTER_LISTEN`. Its one owner runspace alone reads, writes, reconnects, and advances `/api/sync` versions. Subscription relays check the active generation under a lock. Live delivery keeps the newest 16 events per subscription inside a global 64-event and 8 MiB queue budget.

Both adapter modes share one ordered writer. It admits a single encoded event at a time within an 18 MiB reservation that charges the UTF-8 bytes, retained event graph, and runtime overhead, and it holds that reservation for the whole record so events can never interleave. Serializing, every chunked write, the newline, and the flush share one cumulative one-second deadline. A timeout releases the reservation exactly once and then terminates the stream — disposing the controller socket, or standard output in stdin mode — so nothing can follow a partial record.

Every Live socket operation is bounded the same way. One cumulative cancellable budget covers DNS, connect, TLS, the 101 upgrade, the initial `Connect` frame, and the replayed `ModifyQuerySet`; a public call that stops waiting cancels that budget so the abandoned work retires instead of delaying the next control command. Assembling one WebSocket message has an absolute deadline armed by its first byte and never extended by later fragments, so a peer that trickles bytes forever fails exactly like one that stops mid-frame: a structured `TransportError`, a reconnect, replayed `Add` operations, and a later valid value on the same subscription.

## Limitations

Live authentication, optimistic updates, WebSocket mutations/actions, tagged Convex values, query journals, and transition chunks are deliberately out of scope. The client supports the full transitions used by the pinned profile but rejects unsupported transition chunk variants transactionally. `/api/sync` is pinned experimental protocol behaviour, not a stability promise.
