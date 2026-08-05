package convex.example

import convex.{ConvexClient, LiveClient}
import com.fasterxml.jackson.databind.JsonNode
import java.time.Duration
import java.util.UUID

/** The canonical Scala teaching example, installed unchanged in the example image. */
object Main:
  private def count(state: JsonNode, operation: String): Int =
    if !state.path("count").canConvertToInt then throw new IllegalStateException(s"$operation did not return a whole count")
    state.path("count").intValue()

  def main(args: Array[String]): Unit =
    // Read configuration supplied by the verifier instead of baking a deployment into the image.
    val url = Option(System.getenv("CONVEX_URL")).getOrElse(throw new IllegalStateException("CONVEX_URL is required"))
    // Use a unique room so another example run cannot alter this counter's journey.
    val room = args.headOption.getOrElse("scala-example")
    val roomArgs = ConvexClient.json.createObjectNode().put("room", room)
    // Keep native HTTP and Live clients scoped together so both clean up on every exit path.
    val client = new ConvexClient(url); val live = new LiveClient(url)
    try
      // Query Convex's JSON HTTP API and decode only the count this example needs.
      val before = count(client.query("demo:state", roomArgs).value, "current query")
      // Start Live first, making its initial value the observation point before the mutation.
      val subscription = live.subscribe("demo:state", roomArgs)
      try
        val initial = count(subscription.next(Duration.ofSeconds(10)), "initial Live value")
        if initial != before then throw new IllegalStateException("Live initial value disagreed")
        // This UUID is the idempotency key, so a retry cannot increment the room twice.
        val mutationArgs = roomArgs.deepCopy().put("language", "scala").put("runId", UUID.randomUUID().toString)
        val mutation = client.mutation("demo:increment", mutationArgs).value
        val applied = mutation.path("applied").asBoolean(); val after = count(mutation.path("state"), "mutation")
        if !applied || after != before + 1 then throw new IllegalStateException("mutation did not produce the next count")
        // Consume the Live update rather than hiding an out-of-sync subscription with another query.
        val updated = count(subscription.next(Duration.ofSeconds(10)), "updated Live value")
        if updated != after then throw new IllegalStateException("Live update disagreed")
        println(s"current count: $before"); println(s"live initial count: $initial"); println(s"mutation applied: $applied"); println(s"mutation count: $after"); println(s"live updated count: $updated"); println(s"verified count: $before -> $updated")
      finally subscription.close()
    finally { live.close(); client.close() }
