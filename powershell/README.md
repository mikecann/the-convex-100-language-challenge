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

### Convex arguments look like ordinary PowerShell hashtables

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterSnapshot() {
  const room = "powershell-readme";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>Count: {state.count}</p>; // The hook keeps this value reactive.
}
```

**PowerShell**

```powershell
. (Join-Path $PWD 'powershell/client/Convex.ps1') # Dot-source the client functions.

$deploymentUrl = $env:CONVEX_URL
if (-not $deploymentUrl) { throw 'CONVEX_URL is required' }
$room = 'powershell-readme'
$client = New-ConvexClient $deploymentUrl
try {
    # A hashtable becomes the Convex function's { room } argument object.
    $state = (Get-ConvexQuery $client 'demo:state' @{ room = $room }).Value
    Write-Output "Count: $($state.count)"
}
finally {
    Close-ConvexClient $client
}
```

PowerShell's `@{ room = $room }` is a key/value object much like the TypeScript argument object. The important semantic difference is lifecycle: React's `useQuery` stays subscribed and rerenders the component, while `Get-ConvexQuery` makes one HTTP request and returns one snapshot.

### A command-line subscription has an explicit lifetime

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function ReactiveCounter() {
  const room = "powershell-live-readme";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function incrementOnce() {
    await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(), // One logical mutation gets one retry-safe key.
    });
  }

  return (
    <button onClick={incrementOnce} disabled={state === undefined}>
      Count: {state?.count ?? "loading"}
    </button>
  ); // React owns subscription setup and cleanup for useQuery.
}
```

**PowerShell**

```powershell
. (Join-Path $PWD 'powershell/client/Convex.ps1')

$deploymentUrl = $env:CONVEX_URL
if (-not $deploymentUrl) { throw 'CONVEX_URL is required' }
$room = 'powershell-live-readme'
$client = New-ConvexClient $deploymentUrl
$live = New-ConvexLiveState $deploymentUrl
$subscription = $null
try {
    # Subscribe first, then block until the initial reactive value arrives.
    $subscription = Add-ConvexSubscription $live 'counter' 'demo:state' @{ room = $room }
    $initial = Receive-ConvexSubscription $live $subscription 10000
    Write-Output "Initial: $($initial.value.count)"

    $result = (Invoke-ConvexMutation $client 'demo:increment' @{
            room     = $room
            language = 'powershell'
            runId    = [guid]::NewGuid().ToString('N')
        }).Value
    Write-Output "Mutation returned: $($result.state.count)"

    # Receive the next value emitted for the same subscription.
    $updated = Receive-ConvexSubscription $live $subscription 10000
    Write-Output "Live update: $($updated.value.count)"
}
finally {
    if ($subscription) { Remove-ConvexSubscription $live 'counter' }
    Close-ConvexLive $live
    Close-ConvexClient $client
}
```

PowerShell supports callbacks and asynchronous .NET APIs, but this client deliberately exposes a blocking `Receive-ConvexSubscription` operation. That choice makes ownership visible in a script: subscribe, receive values, unsubscribe, and close. React hides those mechanics behind the component lifecycle.

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
