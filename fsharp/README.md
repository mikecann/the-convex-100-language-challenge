# Convex from F#

An educational F# client that calls Convex HTTP functions and explores the pinned `/api/sync` Live protocol with .NET's built-in networking libraries.

It is unofficial teaching code, not a production SDK.

## Start here

[The canonical basic example](examples/basics/Program.fs) reads a room's counter over HTTP, starts Live, applies one idempotent mutation, and checks the Live update. Its small [exact JSON count decoder](examples/basics/Count.fs) accepts decimal forms such as `0.0` without rounding through floating point.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action calls | Implemented locally; capability badge awaits root-owned shared conformance |
| Live query updates and reconnects | Implemented locally; capability badge awaits root-owned shared conformance |
| HTTP bearer authentication | Implemented locally |
| Live authentication and optimistic updates | Not implemented |

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

## Docker verification

Run `./run test fsharp` to compile the client, adapter, and exact example in the pinned .NET SDK image and execute the deterministic language-local fixtures. Run `./run build fsharp` to produce the non-root minimal adapter runtime.

The repository coordinator owns `verify-example`, `verify`, and `verify-hosted`. Those shared gates are still required before this client earns HTTP or Live capability badges.

## Protocol notes

The implementation sends Convex JSON HTTP requests directly and speaks the pinned `/api/sync` WebSocket protocol in F#. One mailbox owner is the sole caller of every WebSocket connect, receive, send, abort, and dispose operation. It validates and coalesces a complete transition, commits the strict state version, and only then publishes changes in query-ID order. Subscription replacement and unsubscribe invalidate the old relay before acknowledgement.

All subscriptions share one newest-16 delivery budget capped at 8 MiB of complete encoded values and structured errors. Subscription count, argument bytes, command ingress, Live frames, and HTTP bodies have separate global ceilings, so adding subscriptions cannot multiply an unbounded per-query allowance. Convex timestamps must be canonical base64 encodings of exactly one little-endian `uint64`; reconnect metadata retains the numeric maximum rather than the most recently received string.

The adapter implements NDJSON protocol v1 over stdin/stdout or one TCP controller connection. It incrementally caps input at 4 MiB per encoded record, caps queued controller output at 16 MiB, and gives each write a 1.5-second deadline. It reserves stdout for protocol events and exposes `debugDisconnect` only for conformance testing.

## Limitations

This is pinned to an undocumented protocol profile, so it is evidence for this experiment rather than a stable SDK contract. Live authentication, optimistic updates, transition chunks, journals, and WebSocket mutation or action calls are not implemented. HTTP supports bearer authentication and remains the path for mutations and actions.

The language-local fixtures also cover atomic transition rejection, repeated-query coalescing, strict state versions, 255 to 256 little-endian timestamp ordering, semantic object and null hydration, same-value recovery after errors, cross-subscription memory pressure, command and subscription ceilings, bounded HTTP bodies, oversized partial NDJSON, controller backpressure, and sole-owner socket instrumentation. Shared local and hosted conformance evidence is deliberately left to the repository coordinator.
