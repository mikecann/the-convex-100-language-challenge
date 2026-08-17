<img src="logo.png" alt="PowerShell logo" width="128">
<!-- Logo source: https://github.com/PowerShell/PowerShell/blob/master/assets/Powershell_256.png -->

# PowerShell

[PowerShell](https://learn.microsoft.com/powershell/) is a cross-platform command shell, scripting language, and automation framework built on .NET. [Windows PowerShell 1.0 arrived in 2006](https://learn.microsoft.com/powershell/scripting/install/powershell-support-lifecycle), and [Microsoft open-sourced the cross-platform edition in 2016](https://devblogs.microsoft.com/powershell/windows-powershell-is-now-powershell-an-open-source-project-with-linux-support-how-did-we-do-it/). Its distinctive trick is an object pipeline: commands pass structured .NET objects instead of making every program parse text. It remains especially useful for Windows administration, Microsoft cloud tooling, deployment scripts, and CI automation, while also running on Linux and macOS.

This client is an educational, unofficial demonstration. It is not a production SDK or a supported Convex package.

## Getting Started

The [canonical basic example](examples/basics/main.ps1) takes a counter from `0` to `1` with an HTTP query, a Live subscription, and an idempotent mutation. From the repository root, Docker builds the pinned PowerShell environment and runs that exact example against an isolated test room:

```sh
./run verify-example powershell
```

You do not need PowerShell installed on the host.

## Interesting Parts

### Everything on the pipeline is an object, never text

PowerShell's founding bet — going back to the "Monad" design that became PowerShell 1.0 — was that shell commands should hand each other structured .NET objects instead of piping text a downstream command has to re-parse. This client leans on that directly: a Convex response comes back as a `PSCustomObject`, so reading a field is a property access, not a `grep`.

```powershell
$client = New-ConvexClient $env:CONVEX_URL
# A hashtable literal becomes the Convex function's { room } argument object.
$state = (Get-ConvexQuery $client 'demo:state' @{ room = $room }).Value
Write-Output "Count: $($state.count)"
# TypeScript: const state = useQuery(api.demo.state, { room })
```

No `JSON.parse`, no string splitting — `.Value.count` is already a live property on a .NET object.

### Dot-sourcing stands in for `import`

PowerShell has no import statement for a loose script file. Instead, the dot operator runs another script *in the caller's own scope*, so every function it defines simply appears, as if you'd typed it yourself. That is the entire mechanism this repo uses to load the client — no module manifest, no build step.

```powershell
# The leading dot runs Convex.ps1 in *this* scope; call it without the dot and
# every function it defines vanishes the moment the script returns.
. (Join-Path $PSScriptRoot '../../client/Convex.ps1')

$client = New-ConvexClient $env:CONVEX_URL
try {
    $current = (Get-ConvexQuery $client 'demo:state' @{ room = $room }).Value
}
finally {
    Close-ConvexClient $client
}
```

### `Receive-ConvexSubscription` turns Live into a blocking call

A script runs line by line, so instead of hiding a WebSocket behind a callback or an event handler, the Live half of this client queues updates and hands them over through one blocking function. Subscribing, receiving, and unsubscribing are three separate statements you can see, rather than mechanics a component's mount and unmount hide from you.

```powershell
$subscription = Add-ConvexSubscription $live 'counter' 'demo:state' @{ room = $room }
try {
    # Blocks the script until Convex pushes a value or the timeout elapses.
    $initial = Receive-ConvexSubscription $live $subscription 10000
    Write-Output "Live count: $($initial.value.count)"
    # TypeScript: useQuery keeps this value reactive for you automatically.
}
finally {
    Remove-ConvexSubscription $live 'counter'
}
```

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Pinned `/api/sync` Live reads | Verified by shared local and hosted conformance |
| Capability badges | `http`, `live`, awarded by the shared evaluator from clean exact-head local and hosted runs |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ps1 -->
```powershell
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

## Implementation Notes

The client is native PowerShell. The public functions in [`client/Convex.ps1`](client/Convex.ps1) implement Convex-specific HTTP and Live behaviour themselves, using .NET's `System.Net.Http`, `System.Net.WebSockets`, and JSON classes only for ordinary transport and decoding. HTTP queries, mutations, and actions share one request path, return both the decoded `Value` and Convex log lines, and preserve structured function errors instead of flattening them into strings.

Live is the harder half. One background PowerShell runspace exclusively owns the WebSocket, reconnects, and subscription changes, so callers never race each other on the socket. The public API gives each subscription a small queue and a blocking receive function. It retains the newest 16 events per subscription, with global limits of 64 events and 8 MiB, which keeps a slow script from growing memory without bound.

The final images pin PowerShell 7.5.0 and run as an unprivileged user. They include the PowerShell runtime and the small POSIX command surface required by the shared verifier, but remove package managers, compiler assemblies, and unrelated shells and runtimes.

### Verification layers

```sh
./run test powershell
./run build powershell
./run verify-example powershell
./run verify-all powershell
```

`test` checks formatting, parsing, client behaviour, adapter behaviour, and memory bounds inside Docker. `build` creates the minimal runtime images. `verify-example` runs the exact source shown above. Root-owned `verify-all` is the broader local and hosted conformance gate used for the capability awards in the status table.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions, query journals, and transition chunks are not implemented.
2. Live values are limited to the JSON-safe subset exercised by this demonstration. Convex tagged values are outside the current client.
3. Live follows a pinned, experimental `/api/sync` profile. Passing the recorded local and hosted checks does not make that undocumented protocol a stability promise.
4. `Receive-ConvexSubscription` blocks the calling script until a value or timeout arrives. That is this educational client's API choice, not a limitation of PowerShell itself.
