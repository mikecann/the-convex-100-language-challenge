# Convex from Scala

This is a small Scala 3 demonstration of Convex's documented JSON HTTP API and
an experimental implementation of the pinned Live sync profile. It is
educational and unofficial, not a production SDK.

## Start here

[The canonical basic example](examples/basics/Main.scala) reads a counter,
starts Live before changing it, performs an idempotent HTTP mutation, and checks
the Live update. The exact same commented program is installed in the example
image.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, awaiting shared evidence |
| Live query subscriptions | Experimental pinned profile, awaiting shared evidence |
| Authentication | HTTP bearer tokens only |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.scala -->
```text
package convex.example

import convex.{ConvexClient, LiveClient}
import com.fasterxml.jackson.databind.JsonNode
import java.time.Duration
import java.util.UUID

/** The canonical Scala teaching example, installed unchanged in the example image. */
object Main:
  private def count(state: JsonNode, operation: String): Int =
    if !state.path("count").canConvertToInt then
      throw new IllegalStateException(s"$operation did not return a whole count")
    state.path("count").intValue()

  def main(args: Array[String]): Unit =
    // Read configuration supplied by the verifier instead of baking a deployment into the image.
    val url = Option(System.getenv("CONVEX_URL"))
      .getOrElse(throw new IllegalStateException("CONVEX_URL is required"))
    // Use a unique room so another example run cannot alter this counter's journey.
    val room = args.headOption.getOrElse("scala-example")
    val roomArgs = ConvexClient.json.createObjectNode().put("room", room)
    // Keep native HTTP and Live clients scoped together so both clean up on every exit path.
    val client = new ConvexClient(url)
    val live = new LiveClient(url)
    try
      // Query Convex's JSON HTTP API and decode only the count this example needs.
      val before = count(client.query("demo:state", roomArgs).value, "current query")
      // Start Live first, making its initial value the observation point before the mutation.
      val subscription = live.subscribe("demo:state", roomArgs)
      try
        val initial = count(subscription.next(Duration.ofSeconds(10)), "initial Live value")
        if initial != before then throw new IllegalStateException("Live initial value disagreed")
        // This UUID is the idempotency key, so a retry cannot increment the room twice.
        val mutationArgs =
          roomArgs.deepCopy().put("language", "scala").put("runId", UUID.randomUUID().toString)
        val mutation = client.mutation("demo:increment", mutationArgs).value
        val applied = mutation.path("applied").asBoolean()
        val after = count(mutation.path("state"), "mutation")
        if !applied || after != before + 1 then
          throw new IllegalStateException("mutation did not produce the next count")
        // Consume the Live update rather than hiding an out-of-sync subscription with another query.
        val updated = count(subscription.next(Duration.ofSeconds(10)), "updated Live value")
        if updated != after then throw new IllegalStateException("Live update disagreed")
        println(s"current count: $before")
        println(s"live initial count: $initial")
        println(s"mutation applied: $applied")
        println(s"mutation count: $after")
        println(s"live updated count: $updated")
        println(s"verified count: $before -> $updated")
      finally subscription.close()
    finally
      live.close()
      client.close()
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test scala
./run build scala
./run verify-example scala
./run verify scala
```

`test` compiles Scala and runs language-local checks inside Docker. `build`
creates minimal amd64 runtime images. The latter two commands are coordinator-
owned shared evidence, so no capability has been awarded here.

## Protocol notes

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`.
One Scala worker owns WebSocket transitions and commands. Each subscription has
a bounded newest-16 queue. The test-only NDJSON v1 adapter includes
`debugDisconnect` for reconnect conformance. Deterministic Scala-local fixtures
cover reconnect backoff and metadata, unchanged hydration suppression,
replacement and unsubscribe relay barriers, fragmented UTF-8 with control
frames, structured failures and recovery, and bounded stalled-peer shutdown.

## Limitations

Live auth, WebSocket mutation/action calls, optimistic updates, journals,
mutation replay, and `TransitionChunk` assembly are deliberately deferred. The
sync protocol is an implementation experiment rather than a stability promise.
