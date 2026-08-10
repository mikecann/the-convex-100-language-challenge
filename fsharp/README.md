<img src="logo.png" alt="F# logo" width="120">
<!-- Logo source: https://fsharp.org/img/logo/fsharp256.png -->

# F#

F# is an open-source, cross-platform, functional-first programming language in
the ML family. Don Syme began developing it at Microsoft Research in the early
2000s, drawing heavily from OCaml and the longer ML tradition. It runs on .NET,
so F# code can use the same runtime and libraries as C#, while adding features
such as immutable values by default, type inference, pipelines, records,
discriminated unions, and pattern matching.

Today F# is actively maintained but remains a specialist choice beside the much
more widely encountered C#. It is used for ordinary .NET applications as well
as web and cloud services, data-heavy and quantitative work, and scripting.
That smaller niche means fewer F#-specific examples and libraries than a C#
developer may expect, although normal .NET libraries remain available. The
language's official home is [fsharp.org](https://fsharp.org/).

This directory contains an educational, unofficial Convex client. It is not a
production SDK or an officially supported Convex package.

## Getting Started

Start with [`examples/basics/Program.fs`](examples/basics/Program.fs). It reads a
counter with `demo:state`, subscribes to that same query, calls
`demo:increment`, and waits for the Live result.
[`examples/basics/Count.fs`](examples/basics/Count.fs) contains the small decoder
used to turn the returned JSON count into an F# integer.

From the repository root, run:

```sh
./run verify-example fsharp
```

The command builds and runs the canonical example in Docker, so no F# or .NET
toolchain needs to be installed on the host. It gives the example a unique room
and checks the complete `0 -> 1` output.

## Interesting Parts

### The JSON boundary is explicit

A React app gets generated types. This handwritten F# client uses a string path
and checks the returned JSON itself.

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function CurrentCount({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  return state === undefined ? null : <span>{state.count}</span>; // Typed result.
}
```

```fsharp
let readCurrentCount (url: string) (room: string) =
    // Validate configuration before creating the client.
    if System.String.IsNullOrWhiteSpace url then
        invalidOp "CONVEX_URL is required"

    let args = System.Text.Json.Nodes.JsonObject()
    args["room"] <- System.Text.Json.Nodes.JsonValue.Create room
    use client = new Convex.Client(url)
    client.Query("demo:state", args).Result.Value
    |> Option.defaultWith (fun () -> invalidOp "query returned null")
    |> fun value -> ExampleCount.count value "current query" // Decode JsonNode.
```

The [`count` decoder](examples/basics/Count.fs) accepts integral forms such as
`0.0` without accepting fractions or out-of-range values.

### A Live query is an owned resource

React owns the subscription lifecycle. The F# caller owns its Live resources,
so the important ordering is visible.

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function CounterButton({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room }); // React owns the subscription.
  const increment = useMutation(api.demo.increment);
  const addOne = () =>
    increment({ room, language: "typescript", runId: crypto.randomUUID() });
  return <button onClick={() => void addOne()}>Count: {state?.count ?? "Loading"}</button>;
}
```

```fsharp
let incrementAndObserve url roomArgs mutationArgs =
    // Validate configuration before opening either client.
    if System.String.IsNullOrWhiteSpace url then
        invalidOp "CONVEX_URL is required"

    use client = new Convex.Client(url)
    use live = new Convex.LiveClient(url)
    // Start listening before the mutation so its update cannot be missed.
    use subscription = live.Subscribe("demo:state", roomArgs).Result
    let initial = subscription.Next(System.TimeSpan.FromSeconds 10.)
    // mutationArgs includes runId, making this HTTP mutation safe to retry.
    client.Mutation("demo:increment", mutationArgs).Result |> ignore
    let updated = subscription.Next(System.TimeSpan.FromSeconds 10.)
    ExampleCount.count initial "initial", ExampleCount.count updated "updated"
```

`use` disposes the client, Live owner, and subscription when the function exits.
The canonical example below adds the complete result checks and output sequence.

## Status

The current manifest records a native, working implementation with both `http`
and `live` capabilities. These claims come from the repository's existing
root-owned evidence; this documentation update does not claim a new verification
run.

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action calls | Verified by root-owned local and hosted conformance |
| Live query updates and reconnects | Verified by root-owned local and hosted conformance |
| HTTP bearer authentication | Implemented locally |
| Live authentication and optimistic updates | Not implemented |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Program.fs -->
```fsharp
open System
open System.Text.Json.Nodes
open Convex
open ExampleCount

[<EntryPoint>]
let main argv =
    let url = Environment.GetEnvironmentVariable "CONVEX_URL"

    if String.IsNullOrWhiteSpace url then
        invalidOp "CONVEX_URL is required"

    // A unique verifier room prevents other examples from changing this counter.
    let room = if argv.Length > 0 then argv[0] else "fsharp-example"
    let roomArgs = JsonObject()
    roomArgs["room"] <- JsonValue.Create room

    // This public demonstration needs no authentication. Both native clients are disposed on exit.
    use client = new Client(url)
    use live = new LiveClient(url)

    // Read the HTTP query and decode its JSON result into an ordinary F# integer.
    let before =
        client.Query("demo:state", roomArgs).Result.Value
        |> Option.defaultWith (fun () -> invalidOp "query returned null")
        |> fun value -> count value "current query"

    // Start Live before the mutation so this initial value is our observation point.
    use subscription = live.Subscribe("demo:state", roomArgs).Result

    let initial =
        subscription.Next(TimeSpan.FromSeconds 10.)
        |> fun value -> count value "initial Live value"

    if initial <> before then
        invalidOp "Live initial value disagreed"

    // runId makes the mutation idempotent if a transport retry occurs.
    let mutationArgs = JsonObject()
    mutationArgs["room"] <- JsonValue.Create room
    mutationArgs["language"] <- JsonValue.Create "fsharp"
    mutationArgs["runId"] <- JsonValue.Create(Guid.NewGuid().ToString())

    let mutation =
        client.Mutation("demo:increment", mutationArgs).Result.Value
        |> Option.defaultWith (fun () -> invalidOp "mutation returned null")

    let mutationObject = mutation.AsObject()
    let applied = mutationObject["applied"].GetValue<bool>()
    let after = count mutationObject["state"] "mutation"

    if not applied || after <> before + 1 then
        invalidOp "mutation did not produce the next count"

    // Only print after the matching Live update proves the full 0 -> 1 journey.
    let updated =
        subscription.Next(TimeSpan.FromSeconds 10.)
        |> fun value -> count value "updated Live value"

    if updated <> after then
        invalidOp "Live update disagreed"

    printfn "current count: %d" before
    printfn "live initial count: %d" initial
    printfn "mutation applied: true"
    printfn "mutation count: %d" after
    printfn "live updated count: %d" updated
    printfn "verified count: %d -> %d" before updated
    0
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native F# implementation. HTTP calls use .NET's `HttpClient`; JSON
uses `System.Text.Json`; Live uses `ClientWebSocket`. No JavaScript Convex
client, Convex CLI, Node.js, Python, or `curl` performs the work. Function names
remain strings such as `demo:state`, and results remain JSON nodes, so
application-level types must be decoded and checked by the F# caller.

The Live client uses an F# `MailboxProcessor`, a single worker that receives
commands one at a time. That worker alone connects, reads, writes, reconnects,
and changes the active query collection. In practical terms, subscriptions can
be requested from different callers without several threads trying to operate
the same WebSocket at once. On reconnect it resends active subscriptions and
suppresses an unchanged initial value, so a reconnect does not look like a
fresh application update.

The test and runtime images target `linux/amd64`. The Dockerfile pins .NET SDK
`8.0.408`, .NET runtime `8.0.15`, and Fantomas `6.3.16`. The final runtime
executes as user `65532:65532` and contains the .NET runtime rather than the
compiler or SDK.

The language-local tests cover the public HTTP and Live behavior plus awkward
cases such as fragmented UTF-8, reconnect recovery, stale updates after
unsubscribe, malformed values, bounded shutdown, and slow consumers. Shared
local and hosted conformance provide the capability evidence reported above.

## Known Issues

1. Live follows a pinned, undocumented Convex protocol profile. It demonstrates
   what passed this repository's tests, not a compatibility promise for future
   Convex releases.
2. Live authentication, optimistic updates, transition chunks, journals, and
   mutation or action calls over the WebSocket are not implemented. Bearer
   authentication is available only through the HTTP client.
3. Slow consumers do not get an unbounded history. All subscriptions on one
   `LiveClient` share the newest 16 queued deliveries and an 8 MiB encoded-data
   budget, so older intermediate updates can be discarded. The client also
   limits active or pending subscriptions to 64.
