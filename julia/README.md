# Convex from Julia

This is a small Julia demonstration of Convex's JSON HTTP API and the pinned
unversioned `/api/sync` protocol. Its canonical example watches a room, reads
its counter over HTTP, increments it with an idempotency key, then proves the
Live update reached the same value.

It is educational, unofficial, and not a production SDK.

## Start here

[`examples/basics/main.jl`](examples/basics/main.jl) is the source shown below.
It deliberately starts Live before its mutation, so its concise output proves
the `0 -> 1` journey rather than merely issuing individual requests.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP query, mutation, and action | Implemented locally, not yet shared-verified |
| `/api/sync` reactive queries | Implemented locally, not yet shared-verified |
| Capability badges | None earned until root-owned local and hosted conformance passes |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.jl -->
```julia
#!/usr/local/bin/julia

# Load the client from this repository. The compiled image already defines it,
# because PackageCompiler includes this same file inside its runtime module.
isdefined(@__MODULE__, :Convex) ||
    include(joinpath(@__DIR__, "..", "..", "client", "Convex.jl"))
using .Convex
using Random

function run_example(room::String = get(ENV, "EXAMPLE_ROOM", "julia-example"))
    # The verifier supplies the dedicated deployment URL; keeping it outside
    # the image avoids baking credentials or environment-specific hosts in.
    url = get(ENV, "CONVEX_URL", "")
    isempty(url) && error("CONVEX_URL is required")

    # One client owns both JSON HTTP calls and the /api/sync Live connection.
    client = Client(url)
    subscription = nothing
    try
        # Start Live first, so the later HTTP mutation cannot race past the
        # subscription's initial server state.
        subscription = subscribe(client, "demo:state", Dict("room" => room))

        # Fetch the current shared state with Convex's JSON HTTP query API.
        current = query(client, "demo:state", Dict("room" => room))
        # Convex counters arrive as JSON numbers, so 0 may be encoded as 0.0.
        # whole_count decodes any mathematically integral, in-range number and
        # rejects fractional, quoted, non-finite, or overflowing values.
        current_count = whole_count(current.value["count"], "current count")
        current_count == 0 || error("current count was $(current_count), expected 0")
        println("current count: $(current_count)")

        # The first Live value must agree with the HTTP query before we change
        # the room. A typed query failure remains visible to this example.
        initial = next_update(subscription; timeout = 10)
        initial.error === nothing || throw(initial.error)
        initial_count = whole_count(initial.value["count"], "initial Live count")
        initial_count == current_count || error("initial Live count disagreed with HTTP")
        println("live initial count: $(initial_count)")

        # runId is the mutation idempotency key. Retrying this logical request
        # therefore cannot increment the test room twice.
        changed = mutation(
            client,
            "demo:increment",
            Dict("room" => room, "language" => "julia", "runId" => randstring(16)),
        )
        changed.value["applied"] == true || error("mutation was not applied")
        println("mutation applied: true")
        mutation_count = whole_count(changed.value["state"]["count"], "mutation count")
        mutation_count == 1 || error("mutation count was $(mutation_count), expected 1")
        println("mutation count: $(mutation_count)")

        # This value is delivered by /api/sync, without another HTTP query.
        updated = next_update(subscription; timeout = 10)
        updated.error === nothing || throw(updated.error)
        updated_count = whole_count(updated.value["count"], "updated Live count")
        updated_count == 1 || error("updated Live count was $(updated_count), expected 1")
        println("live updated count: $(updated_count)")
        println("verified count: 0 -> 1")
    finally
        # Closing the client must still happen if unsubscribe itself observes a
        # broken peer, otherwise a failed example could leak its Live worker.
        try
            subscription === nothing || unsubscribe!(subscription)
        finally
            close!(client)
        end
    end
end

# PackageCompiler includes this exact file in its generated package. Only run
# automatically when Julia launched the canonical source file itself.
if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    run_example(length(ARGS) >= 1 ? ARGS[1] : get(ENV, "EXAMPLE_ROOM", "julia-example"))
end
```
<!-- END GENERATED EXAMPLE -->

## Docker checks

```sh
./run test julia
./run build julia
```

The first command checks formatting, architecture, compilation, and Julia-local
tests inside pinned toolchain images. The second only builds the default
linux/amd64 adapter image. Entrypoint execution, minimal-runtime policy, the
canonical hosted example, and black-box conformance are deliberately separate
root-owned verification gates:

```sh
./run verify-example julia
./run verify-all julia
```

## Protocol notes

The implementation owns query-set versions, transitions, reconnects, and
little-endian base64 timestamps in Julia. `debugDisconnect` exists only in the
test adapter so the shared harness can prove reconnect behaviour. Live delivery
uses one global newest-value budget across subscriptions: the client retains at
most five values and 3 MiB, while the adapter retains at most seven output
values and 3 MiB, including its in-flight write. Four explicitly charged
transient slots cover relay, decode, client-candidate, and adapter-encoding
work. The complete pipeline is therefore bounded to 16 values and 14 MiB of
encoded payload. This source-level bound is tested separately from process RSS;
the hard 128 MiB final-image gate must still pass before any capability is
claimed. Oldest queued subscription values are dropped for a slow consumer;
command acknowledgements instead fail on bounded backpressure.

The compiled runtime occupies roughly 84 MiB of anonymous memory before it does
any work, so the shared 128 MiB limit leaves headroom for about one
near-maximum payload. The conformance adapter therefore admits large work
through one process-wide budget: a query result and a Live update cannot
materialise at the same time, admission itself is deadline bounded so a caller
fails with a typed error rather than waiting forever, and reservations are
released on every path. A controller that stays connected but never reads is
treated as a transport failure, not a clean session: the writer's cumulative
one-second deadline retires the adapter, which reports the stall on stderr and
exits nonzero. Measured with a permanently unread controller and 32
near-maximum HTTP results, peak container memory was 110.4 MiB of the 128 MiB
limit with no OOM kill.

The frame parser is bounded separately. It retains at most one maximal frame
with its header plus any fragmented payload still being assembled, and every
transport read is capped by whatever remains of that budget. A peer that
pipelines the next frame directly behind a near-maximum one therefore leaves
those bytes in the transport instead of being rejected as oversized.

## Limitations

The protocol is pinned to `convex-rs` commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`; it is not an official public
protocol guarantee. Authentication for Live, binary/non-JSON Convex values,
and `TransitionChunk` are intentionally deferred. No capability is claimed
until the shared evaluator has its own clean evidence.
