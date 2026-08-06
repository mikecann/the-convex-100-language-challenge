#!/usr/local/bin/julia

client_root =
    isfile("/opt/convex/client/Convex.jl") ? "/opt/convex/client" :
    joinpath(@__DIR__, "..", "..", "client")
isdefined(@__MODULE__, :Convex) || include(joinpath(client_root, "Convex.jl"))
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
