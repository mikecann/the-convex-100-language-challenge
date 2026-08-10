<img src="logo.png" alt="Julia logo" width="150">
<!-- Logo source: https://raw.githubusercontent.com/JuliaLang/www.julialang.org/main/_assets/images/logo.png -->

# Julia

[Julia](https://julialang.org/) is a dynamic, compiled language created by Jeff
Bezanson, Stefan Karpinski, Viral B. Shah, and Alan Edelman. Work began around
2009 and the first public release arrived in 2012. Its founders wanted the
interactive feel of Python, R, and MATLAB with native-code performance and
multiple dispatch. Today Julia has a particularly strong niche in numerical
and scientific computing, data science, optimisation, machine learning, and
parallel or GPU workloads. The project reports more than 100 million downloads
and over 12,000 registered packages.

This repository uses Julia for an educational Convex client experiment. It is
unofficial and is not a production SDK.

## Getting Started

Start with [`examples/basics/main.jl`](examples/basics/main.jl). It subscribes
to a room before reading its counter over HTTP, increments the counter once,
and then waits for the matching Live update. From the repository root, run the
exact example in its Docker image with:

```sh
./run verify-example julia
```

Nothing is installed on your host. The command builds and runs the pinned
`linux/amd64` image against a fresh test room.

## Interesting Parts

### A familiar JSON query, without generated result types

TypeScript with React:

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Counter() {
  const room = "readme-julia-query";
  const state = useQuery(api.demo.state, { room });
  // `api` is generated, so `state.count` is type-safe after loading.
  if (state === undefined) return <p>Loading...</p>;
  return <p>Count: {state.count}</p>;
}
```

Julia:

```julia
include("client/Convex.jl")
using .Convex

room = "readme-julia-query"
url = get(ENV, "CONVEX_URL", "")
isempty(url) && error("CONVEX_URL is required")
client = Client(url)
try
    # Dict constructs the same `{ room }` argument object explicitly.
    result = query(client, "demo:state", Dict("room" => room))
    # This client returns JSON-shaped Dict values, not generated Julia types.
    count = whole_count(result.value["count"], "state count")
    println("Count: $(count)")
finally
    close!(client)
end
```

The Julia call is a one-off HTTP query. React's `useQuery` also owns a reactive
subscription and rerenders the component, so the two snippets deliberately do
not promise identical lifecycles. Julia can express richer typed models, but
this small client keeps decoded results as ordinary dictionaries and validates
important values at runtime.

### React rerenders; this client lets you pull the next Live value

TypeScript with React:

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function LiveCounter() {
  const room = "readme-julia-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    // useQuery receives the change and React rerenders this component.
  }

  return <button onClick={addOne}>Count: {state?.count ?? "loading"}</button>;
}
```

Julia:

```julia
include("client/Convex.jl")
using .Convex
using Random

room = "readme-julia-live"
url = get(ENV, "CONVEX_URL", "")
isempty(url) && error("CONVEX_URL is required")
client = Client(url)
subscription = nothing
try
    # Subscribe first so the mutation cannot race ahead of Live.
    subscription = subscribe(client, "demo:state", Dict("room" => room))
    initial = next_update(subscription; timeout = 10)
    initial.error === nothing || throw(initial.error)
    println("Before: $(whole_count(initial.value["count"], "initial count"))")

    changed = mutation(
        client,
        "demo:increment",
        Dict(
            "room" => room,
            "language" => "julia",
            "runId" => randstring(16), # Idempotency key for this mutation.
        ),
    )
    println("Applied: $(changed.value["applied"])")

    # This blocks the calling task until the client delivers the next value.
    updated = next_update(subscription; timeout = 10)
    updated.error === nothing || throw(updated.error)
    println("After: $(whole_count(updated.value["count"], "updated count"))")
finally
    try
        subscription === nothing || unsubscribe!(subscription)
    finally
        close!(client)
    end
end
```

Julia has first-class tasks and channels, but this client's public API chooses
a blocking `next_update` operation. That is convenient for a command-line
example, not a limitation of Julia. A GUI or service wrapper could wait in its
own task and forward updates, while React's hooks manage that work for the
component automatically.

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP query, mutation, and action | Verified locally and hosted |
| `/api/sync` reactive queries | Verified locally and hosted |
| Capability badges | HTTP and Live earned by root-owned local and hosted conformance |

`./run test julia` checks formatting, compilation, architecture, and Julia-local
tests in Docker. `./run verify-all julia` is the broader root-owned gate that
repeats the canonical example and black-box conformance against local and
hosted deployments.

## Example

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

## Implementation Notes

The HTTP side is straightforward Julia. `HTTP.jl` handles HTTP and TLS,
`JSON3.jl` handles JSON, and the client implements Convex request and error
semantics itself. Responses become plain `Dict{String,Any}` and `Vector{Any}`
trees. This avoids retaining lazy parser views and gives the ahead-of-time
compiled runtime a finite set of container shapes, at the cost of generated
application types.

Live concurrency is more deliberate. One Julia `Task`, created with `@async`,
has exclusive ownership of WebSocket reads, writes, reconnection, and query-set
changes. Public callers send commands to that owner through a bounded internal
`Channel`. Live values are retained in bounded, lock-protected queues and
`next_update` pulls from those queues. In other words, channels coordinate the
client internally, but a subscription is not itself exposed as a Julia
`Channel` or stream. Choosing whether a future public API should return a
channel, invoke a callback, or offer an iterator is client API design still to
be done.

The final Docker image is built with Julia 1.11.6 and PackageCompiler, then the
`julia` executable and build tools are removed. Ahead-of-time compilation is
the awkward part: dynamic JSON payloads and error paths must be normalised so a
new runtime type does not demand a compiler specialization that is absent from
the stripped image. The result contains only the compiled example or adapter
launcher needed by its Docker target.

The Live implementation is pinned to the unversioned `/api/sync` behaviour at
`convex-rs` commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`. It owns
reconnection and WebSocket framing in Julia rather than delegating to another
Convex client. `debugDisconnect` belongs only to the conformance adapter so the
shared tests can exercise real reconnects.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and `TransitionChunk` assembly are deferred.
2. Values are limited to the JSON-safe Convex subset used by this experiment.
   Binary and other non-JSON Convex values are unsupported.
3. Live delivery favours bounded memory over an unlimited history. Across all
   subscriptions, the client retains at most five queued values and 3 MiB,
   dropping the oldest value for a slow consumer. The adapter applies its own
   bounded output budget and treats a controller that stops reading as a
   transport failure.
4. `/api/sync` is pinned implementation evidence, not an official public
   protocol guarantee. A backend protocol change may require this client to be
   updated and reverified.
