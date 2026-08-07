# Convex from Kotlin

This folder shows a small Kotlin program talking directly to Convex. It uses
the documented JSON HTTP endpoints and a native, experimental Live WebSocket
implementation to follow a counter as it changes.

This is educational and unofficial, not a production SDK or a package intended
for publication.

## Start here

The [basic example](examples/basics/Main.kt) follows one useful journey: it
reads a counter with HTTP, starts Live before changing anything, applies an
idempotent mutation, and confirms the Live update agrees with the response.

## What works

| Capability | Status |
| --- | --- |
| Native HTTP query, mutation, and action implementation | Verified by shared local and hosted conformance |
| Native Live query implementation | Verified by shared local and hosted conformance |
| Docker test and final runtime image | Verified by shared local and hosted conformance |
| Earned capability badges | None until shared local and hosted verification passes |
| Live authentication, WebSocket mutations/actions, optimistic updates, replay | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.kt -->
```kotlin
package convex.kotlin.example

import convex.kotlin.ConvexClient
import convex.kotlin.Update
import convex.kotlin.integralIntOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Duration
import java.util.UUID

fun main(args: Array<String>) {
    // Read the verifier-selected deployment instead of baking a URL into the image.
    val url = System.getenv("CONVEX_URL") ?: error("CONVEX_URL is required")
    // A unique room prevents another example run from changing this counter.
    val room = args.firstOrNull() ?: "kotlin-example"
    val roomArgs = buildJsonObject { put("room", room) }
    // Create one native client and always close its HTTP and Live resources.
    ConvexClient(url).use { client ->
        // Read the current counter with Convex's documented JSON HTTP query.
        val before = count(client.query("demo:state", roomArgs).value, "current query")
        // Start Live before the mutation so its first value is our observation point.
        client.subscribe("demo:state", roomArgs).use { subscription ->
            val initial = count(next(subscription.next(), "initial Live value"), "initial Live value")
            check(initial == before) { "Live initial value disagreed with HTTP" }
            // The run ID is an idempotency key, preventing a retry from incrementing twice.
            val mutation =
                client
                    .mutation(
                        "demo:increment",
                        buildJsonObject {
                            put("room", room)
                            put("language", "kotlin")
                            put("runId", UUID.randomUUID().toString())
                        },
                    ).value.jsonObject
            check(mutation["applied"]?.jsonPrimitive?.boolean == true) { "mutation was not applied" }
            val after = count(mutation["state"] ?: error("mutation omitted state"), "mutation")
            check(after == before + 1) { "mutation count was unexpected" }
            // Consume the change already observed by Live, without polling again.
            val updated = count(next(subscription.next(), "updated Live value"), "updated Live value")
            check(updated == after) { "Live update disagreed with mutation" }
            // Stdout is intentionally the shared six-line happy-path transcript only.
            println("current count: $before")
            println("live initial count: $initial")
            println("mutation applied: true")
            println("mutation count: $after")
            println("live updated count: $updated")
            println("verified count: $before -> $updated")
        }
    }
}

// Turn Live's three non-value outcomes into useful example failures: no event,
// a structured query error, or a malformed update that omitted its value.
private fun next(
    update: Update?,
    operation: String,
): kotlinx.serialization.json.JsonElement {
    update ?: error("timed out waiting for $operation")
    update.error?.let { throw it }
    return update.value ?: error("$operation omitted a value")
}

// Convex JSON may spell an integral count as 0.0. Decode it exactly, without
// rounding a fractional value or accepting a number outside Kotlin's Int range.
private fun count(
    value: kotlinx.serialization.json.JsonElement,
    operation: String,
): Int =
    value.jsonObject["count"]?.integralIntOrNull()
        ?: error("$operation did not return an integer count")
```
<!-- END GENERATED EXAMPLE -->

The block above is generated from the exact runnable source used by the Docker
image. Run `./run sync-examples` after editing it.

## Docker-only verification

```sh
./run test kotlin
./run build kotlin
```

`test` compiles the Kotlin sources, runs local HTTP tests, and assembles the
canonical example plus conformance adapter inside Docker. `build` creates the
minimal Linux amd64 adapter image. The coordinator runs the shared example and
hosted conformance gates serially because they share a backend and evidence.

## Conformance and protocol notes

The test-only executable at `client/tests/conformance/AdapterMain.kt` accepts
NDJSON protocol v1 through stdin/stdout or `ADAPTER_LISTEN` TCP. It calls the
real Kotlin client for query, mutation, action, subscription, authentication,
unsubscribe, clean close, and its adapter-only `debugDisconnect` hook.

Live has one owner thread for socket reads, writes, reconnects, and query-set
versions. Each subscription keeps the newest 16 updates, dropping old
intermediate state for a slow consumer. A relay rechecks subscription identity
after dequeue so a stale event cannot escape after unsubscribe or same-ID
replacement.

The implementation targets the experimental unversioned `/api/sync` profile
documented by `convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It uses JDK HTTP/WebSocket and
Kotlin JSON only, never the Convex CLI, Node, Python, curl, or another Convex
client.

## Limitations

Live authentication, WebSocket mutations/actions, optimistic updates, journals,
replay, tagged Convex values beyond JSON-safe values, and TransitionChunk
assembly are deferred. A TransitionChunk is treated as protocol drift and
reconnects, rather than silently producing a partial state.
