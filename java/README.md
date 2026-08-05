# Convex from Java

This is a small Java demonstration of calling Convex over its documented JSON
HTTP API, plus an experimental implementation of the pinned Live sync profile.
It is educational and unofficial, not a production SDK.

## Start here

[The canonical basic example](examples/basics/Main.java) reads a counter,
starts Live before changing it, performs an idempotent HTTP mutation, and checks
the Live update. It is the exact program included below and run by the image.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, awaiting shared evidence |
| Live query subscriptions | Experimental pinned profile, awaiting shared evidence |
| Authentication | HTTP bearer tokens only |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.java -->
```java
package convex.example;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;
import convex.LiveClient;
import java.io.PrintWriter;
import java.time.Duration;
import java.util.UUID;

/** The canonical teaching example, also installed unchanged in the example image. */
public final class Main {
  private static int count(JsonNode state, String operation) {
    if (!state.path("count").canConvertToInt()) {
      throw new IllegalStateException(operation + " did not return a whole count");
    }
    return state.path("count").intValue();
  }

  public static void main(String[] args) throws Exception {
    // Read configuration from the verifier rather than baking a deployment into the image.
    String url = System.getenv("CONVEX_URL");
    if (url == null) throw new IllegalStateException("CONVEX_URL is required");

    // Use a unique room so separate example runs cannot change each other's counter.
    String room = args.length == 0 ? "java-example" : args[0];
    ObjectNode roomArgs = ConvexClient.JSON.createObjectNode().put("room", room);

    // Create one native HTTP client and one Live connection, both cleaned up on every exit path.
    try (ConvexClient client = new ConvexClient(url);
        LiveClient live = new LiveClient(url)) {
      // Ask the documented HTTP query API for the current state and decode its JSON count.
      int before = count(client.query("demo:state", roomArgs).value(), "current query");

      // Start Live before mutating so its initial value establishes the observation point.
      try (LiveClient.Subscription subscription = live.subscribe("demo:state", roomArgs)) {
        int initial = count(subscription.next(Duration.ofSeconds(10)), "initial Live value");
        if (initial != before) throw new IllegalStateException("Live initial value disagreed");

        // The random runId is the mutation's idempotency key, avoiding duplicate increments on a
        // retry.
        ObjectNode mutationArgs =
            roomArgs.deepCopy().put("language", "java").put("runId", UUID.randomUUID().toString());
        JsonNode mutation = client.mutation("demo:increment", mutationArgs).value();
        boolean applied = mutation.path("applied").asBoolean();
        if (!applied) throw new IllegalStateException("mutation was not applied");
        int after = count(mutation.path("state"), "mutation");
        if (after != before + 1) throw new IllegalStateException("mutation count was unexpected");

        // Consume the resulting Live update without making a second HTTP query.
        int updated = count(subscription.next(Duration.ofSeconds(10)), "updated Live value");
        if (updated != after) throw new IllegalStateException("Live update disagreed");

        // Print only after HTTP and Live agree on the complete 0 to 1 journey.
        writeTranscript(
            new PrintWriter(System.out, true), before, initial, applied, after, updated);
      }
    }
  }

  // Keep the verifier-facing output in one small function so its exact six-line
  // contract can be tested without replacing the real network example.
  static void writeTranscript(
      PrintWriter output, int before, int initial, boolean applied, int mutation, int updated) {
    output.println("current count: " + before);
    output.println("live initial count: " + initial);
    output.println("mutation applied: " + applied);
    output.println("mutation count: " + mutation);
    output.println("live updated count: " + updated);
    output.println("verified count: " + before + " -> " + updated);
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test java
./run build java
./run verify-example java
./run verify java
```

`test` compiles and runs Java-local checks inside Docker. `build` produces the
minimal runtime images. The latter two commands are root-owned shared evidence
runs and have not yet awarded any capability badges.

## Protocol notes

Live uses the explicitly pinned `convex-rs-0.10.4-unversioned-sync` profile at
`/api/sync`. The adapter speaks NDJSON protocol v1 and has a test-only
`debugDisconnect` hook for reconnect testing.

## Limitations

This experiment deliberately supports the JSON-safe value subset. Live auth,
WebSocket mutations/actions, transition chunks, optimistic updates, journals,
and mutation replay are deferred. Live delivery keeps a bounded newest-16
update buffer for each subscription; a slow reader loses old intermediate
values rather than growing memory without bound.
