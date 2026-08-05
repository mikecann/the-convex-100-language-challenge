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
