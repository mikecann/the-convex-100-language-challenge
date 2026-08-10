<img src="logo.png" alt="Kotlin logo" width="240">
<!-- Logo source: https://resources.jetbrains.com/storage/products/kotlin/docs/kotlin_logos.zip -->

# Kotlin

[Kotlin](https://kotlinlang.org/) is an open-source, statically typed language
developed by JetBrains. The project began in 2010 and reached 1.0 in 2016. It
mixes object-oriented and functional features, compiles to Java-compatible JVM
bytecode, and can also target Android, JavaScript, WebAssembly, and native code.

Its clearest present-day niche is Android, where
[Google's tooling and guidance are Kotlin-first](https://developer.android.com/kotlin/first),
but its Java interoperability also makes it practical for
[JVM backend work](https://kotlinlang.org/docs/server-overview.html) with
frameworks such as Spring and Ktor. This repository's client uses that JVM
path. It is an educational, unofficial demonstration, not a production SDK or
a package intended for publication.

## Getting Started

The [canonical example](examples/basics/Main.kt) reads a counter once over
HTTP, subscribes to the same counter over Live, applies an idempotent mutation,
and checks that the reactive update agrees with the mutation result.

From the repository root, run:

```sh
./run verify-example kotlin
```

The command builds and runs the exact example in Docker against a verifier-owned
room. It proves the example's `0 -> 1` journey, not the client's full conformance
suite.

## Interesting Parts

### Generated types versus explicit JSON

**TypeScript with React**

```tsx
import { ConvexProvider, ConvexReactClient, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

function Counter() {
  const state = useQuery(api.demo.state, { room: "readme-kotlin" });
  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // Function, arguments, and result are generated types.
}

export function App() {
  return (
    <ConvexProvider client={convex}>
      <Counter />
    </ConvexProvider>
  );
}
```

**Kotlin**

```kotlin
import convex.kotlin.ConvexClient
import convex.kotlin.integralIntOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

fun main() {
    val deploymentUrl = System.getenv("CONVEX_URL") ?: error("CONVEX_URL is required")
    val arguments = buildJsonObject { put("room", "readme-kotlin") }

    ConvexClient(deploymentUrl).use { client ->
        // This client accepts a function path and JSON, rather than generated types.
        val state = client.query("demo:state", arguments).value.jsonObject
        val count = state["count"]?.integralIntOrNull() ?: error("count was not an Int")
        println(count)
    } // use closes the client's HTTP and Live resources.
}
```

Kotlin itself is statically typed, but this small client deliberately exposes
`JsonElement` values instead of generating a Kotlin model for each Convex
function. The React hook remains subscribed and rerenders its component. The
Kotlin `query` above is a one-off HTTP read. See
[`ConvexClient.kt`](client/src/main/kotlin/convex/kotlin/ConvexClient.kt) for the
actual API.

### React-owned reactivity versus an owned subscription

**TypeScript with React**

```tsx
import {
  ConvexProvider,
  ConvexReactClient,
  useMutation,
  useQuery,
} from "convex/react";
import { api } from "./convex/_generated/api";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

function Counter() {
  const state = useQuery(api.demo.state, { room: "readme-live" });
  const increment = useMutation(api.demo.increment);
  if (state === undefined) return <p>Loading...</p>;

  async function addOne() {
    const result = await increment({
      room: "readme-live",
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation result is type-safe too.
  }

  // React keeps the query subscribed and rerenders after the mutation.
  return <button onClick={() => void addOne()}>Count: {state.count}</button>;
}

export function App() {
  return (
    <ConvexProvider client={convex}>
      <Counter />
    </ConvexProvider>
  );
}
```

**Kotlin**

```kotlin
import convex.kotlin.ConvexClient
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.UUID

fun main() {
    val deploymentUrl = System.getenv("CONVEX_URL") ?: error("CONVEX_URL is required")
    val roomArguments = buildJsonObject { put("room", "readme-live") }

    ConvexClient(deploymentUrl).use { client ->
        // Start Live first so no update can be missed between the read and mutation.
        client.subscribe("demo:state", roomArguments).use { subscription ->
            val initialUpdate = subscription.next() ?: error("initial Live value timed out")
            initialUpdate.error?.let { throw it }
            val initial = initialUpdate.value ?: error("initial Live value was missing")
            println(initial.jsonObject["count"]) // The first snapshot is delivered explicitly.

            val result =
                client.mutation(
                    "demo:increment",
                    buildJsonObject {
                        put("room", "readme-live")
                        put("language", "kotlin")
                        put("runId", UUID.randomUUID().toString())
                    },
                ).value.jsonObject
            println(result["state"]) // The caller decodes the returned JSON shape.

            val updatedEvent = subscription.next() ?: error("Live update timed out")
            updatedEvent.error?.let { throw it }
            val updated = updatedEvent.value ?: error("Live update value was missing")
            println(updated.jsonObject["count"]) // next blocks until a snapshot arrives.
        } // Closing the subscription removes it from Live.
    }
}
```

Kotlin supports coroutines, callbacks, and streams. This client's blocking
`Subscription.next()` is an API choice for a small command-line demonstration,
not a language limitation. It makes lifecycle and ordering visible, while React
owns those details for `useQuery`. The complete sequence is in the
[canonical example](examples/basics/Main.kt).

## Status

| Capability | Status |
| --- | --- |
| Native HTTP query, mutation, and action implementation | Verified by shared local and hosted conformance |
| Native Live query implementation | Verified by shared local and hosted conformance |
| Docker test and final runtime image | Verified by shared local and hosted conformance |
| Earned capability badges | HTTP and Live |
| Live authentication, WebSocket mutations/actions, optimistic updates, replay | Deferred |

## Example

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

## Implementation Notes

This is a native Kotlin/JVM implementation. The public client uses JDK 21's
`HttpClient` and `WebSocket` for transport and `kotlinx.serialization` for JSON.
It does not delegate Convex behavior to the JavaScript client, the Convex CLI,
or another language runtime. HTTP query, mutation, and action calls are
synchronous, retain Convex log lines, and keep function errors distinct from
transport and protocol errors.

Resource ownership follows familiar JVM patterns: `ConvexClient` and
`Subscription` implement `AutoCloseable`, so callers can scope them with
Kotlin's `use` function. Live socket state, reconnects, and query-set changes
run through one owner thread. Each subscription has a bounded queue containing
at most the newest 16 updates, which prevents a slow consumer from creating an
unbounded backlog.

The Live implementation targets the experimental, unversioned `/api/sync`
profile documented by `convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. The test-only
[`AdapterMain.kt`](client/tests/conformance/AdapterMain.kt) translates the
shared conformance protocol into calls on the real client. Docker builds with
Kotlin 2.2.21 and JDK 21, then uses `jlink` to create a smaller JVM runtime for
the final Linux amd64 images.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and replay are deferred. HTTP authentication is supported.
2. A `TransitionChunk` is treated as protocol drift and triggers a reconnect;
   the client does not assemble chunked transitions.
3. A slow Live consumer receives the newest snapshots, but older intermediate
   values are deliberately dropped after its 16-update queue fills.
4. The demonstration covers JSON-safe values. Tagged Convex values outside
   ordinary JSON are deferred.
