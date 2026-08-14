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

### The reply rides the pipeline

The `|>` operator is F#'s signature punctuation: `x |> f` simply means `f x`,
so a value reads top-to-bottom through its transformations. A query result here
is a `JsonNode option` — "maybe absent" is a type, not a lurking null — and it
flows from the wire to a plain `int` in one visible stream:

```fsharp
let before =
    // TypeScript: const state = useQuery(api.demo.state, { room })
    client.Query("demo:state", roomArgs).Result.Value
    |> Option.defaultWith (fun () -> invalidOp "query returned null")
    |> fun value -> count value "current query"
```

Because the value is an `option`, the compiler will not let the empty case be
forgotten; it has to be peeled off deliberately.

### `use` gives the subscription a visible lifetime

`use` is `let` plus a promise: when the binding leaves scope, `Dispose` runs —
and disposing a `Subscription` sends the WebSocket unsubscribe. So the
subscribe-then-mutate ordering at the heart of Convex reactivity reads as a
plain sequence of lines:

```fsharp
use live = new LiveClient(url)
// Start listening before the mutation so its update cannot be missed.
use subscription = live.Subscribe("demo:state", roomArgs).Result
let initial = subscription.Next(TimeSpan.FromSeconds 10.)
client.Mutation("demo:increment", mutationArgs).Result |> ignore
let updated = subscription.Next(TimeSpan.FromSeconds 10.)
// TypeScript: React's useQuery owns this whole lifecycle behind the hook.
```

When the function returns, subscription, Live client, and HTTP client all clean
up in reverse order — no `finally` in sight.

### One `match` asks the JSON three questions

An F# pattern can test a value's runtime type (`:? JsonObject`), bind it under
a new name, and attach a `when` guard, all in a single arm. The example's whole
decoder — turn `{ "count": 0.0 }` into an `int` or say exactly why not — is one
expression in [`Count.fs`](examples/basics/Count.fs):

```fsharp
let count (value: JsonNode) place =
    match value with
    | :? JsonObject as objectValue when not (isNull objectValue["count"]) ->
        match wholeInt32 (objectValue["count"].ToJsonString()) with
        | Some number -> number
        | None -> invalidOp (place + " did not return a whole Int32 count")
    | _ -> invalidOp (place + " did not return a counter value")
```

The compiler checks the arms cover every case, so "what if it isn't an object?"
cannot go unanswered.

### An Erlang-flavored mailbox owns the WebSocket

`MailboxProcessor` has shipped with F# since async workflows arrived in 2007 —
an actor in the standard library, years before `async`/`await` reached C#. This
client's Live internals use one: each operation becomes a message in a
discriminated union, and a single async loop is the only code that ever touches
the socket:

```fsharp
type private OwnerCommand =
    | SubscribeOwner of string * JsonObject * int * TaskCompletionSource<Subscription>
    | UnsubscribeOwner of int * TaskCompletionSource<unit>
    | ReconnectOwner of int64
    // ... one case per thing the socket's owner can be asked to do

let owner =
    MailboxProcessor.Start(fun inbox ->
        async {
            // The sole caller of Connect, Receive, Send, and Dispose.
            let! command = inbox.TryReceive 1
            // match on the command, drive the socket, reply when done ...
        })
```

Callers on any thread just post messages, so races over the socket are
impossible by construction.

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
