<img src="logo.png" alt="Java logo" width="212">
<!-- Logo source: https://dev.java/assets/images/java-logo-vector.png -->

# Java

Java is a general-purpose, class-based language created at Sun Microsystems and
launched in 1995. Its C-like syntax will look familiar to C#, C++, and many
TypeScript developers, but Java normally compiles to bytecode for the Java
Virtual Machine, which gives the same program a portable runtime across operating
systems. The [official Java developer site](https://dev.java/) is the best place
to start learning the modern language.

Java is still especially common in long-lived server, cloud, and enterprise
systems, while the wider platform also covers desktop and connected-device
software. This repository's Java 21 client is an educational, unofficial
demonstration. It is not a production SDK and is not sanctioned by Convex.

## Getting Started

[The canonical example](examples/basics/Main.java) reads a counter, opens a Live
subscription before changing it, performs an idempotent mutation, and observes
the reactive update. From the repository root, run the exact example in its
Docker image against a unique test room:

```sh
./run verify-example java
```

Docker supplies the pinned Java toolchain and dependencies, so this command does
not install Java or Maven on your host.

## Interesting Parts

### A typed language meeting dynamic JSON

In a normal Convex React app, generated bindings connect a function's argument
and return types to TypeScript. This demonstration deliberately has no generated
Java model classes, so it constructs and checks Jackson JSON trees at runtime.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function Counter({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  if (state === undefined) return <span>Loading...</span>;
  return <span>{state.count}</span>; // state and count are type-safe here.
}
```

**Java**

```java
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;

String room = "readme-java-query";
ObjectNode args = ConvexClient.JSON.createObjectNode().put("room", room);

try (ConvexClient client = new ConvexClient(System.getenv("CONVEX_URL"))) {
  // This is one HTTP snapshot, so the application checks the dynamic JSON result itself.
  JsonNode state = client.query("demo:state", args).value();
  if (!state.path("count").canConvertToInt()) {
    throw new IllegalStateException("demo:state returned an invalid count");
  }
  int count = state.path("count").intValue(); // count is an ordinary Java int from here.
  System.out.println(count);
}
```

`useQuery` stays subscribed and causes React to render again when the value
changes. `ConvexClient.query` is a one-off HTTP call, so it is useful for a
snapshot but is not equivalent to the hook's reactivity.

### Owning a Live subscription explicitly

React owns a hook subscription's lifecycle. This command-line Java API instead
returns an `AutoCloseable` subscription and exposes a blocking `next` operation,
which makes the order of the initial value, mutation, and update visible.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function IncrementButton({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={() =>
        increment({ room, language: "typescript", runId: crypto.randomUUID() })
      }
    >
      Count: {state?.count ?? "loading"}
    </button>
  ); // React starts and stops the reactive query with this component.
}
```

**Java**

```java
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;
import convex.LiveClient;
import java.time.Duration;
import java.util.UUID;

String room = "readme-java-live";
ObjectNode roomArgs = ConvexClient.JSON.createObjectNode().put("room", room);

try (ConvexClient http = new ConvexClient(System.getenv("CONVEX_URL"));
    LiveClient live = new LiveClient(System.getenv("CONVEX_URL"));
    LiveClient.Subscription subscription = live.subscribe("demo:state", roomArgs)) {
  // next waits for the subscription's initial value. Blocking is this client's API choice.
  JsonNode initial = subscription.next(Duration.ofSeconds(10));

  ObjectNode mutationArgs =
      roomArgs.deepCopy().put("language", "java").put("runId", UUID.randomUUID().toString());
  JsonNode mutation = http.mutation("demo:increment", mutationArgs).value();
  boolean applied = mutation.path("applied").asBoolean(); // The mutation returns this field.

  // The same subscription then supplies the reactive value caused by the mutation.
  JsonNode updated = subscription.next(Duration.ofSeconds(10));
  System.out.println(initial.path("count") + " -> " + updated.path("count") + ", " + applied);
} // try-with-resources unsubscribes and closes both clients, even after a failure.
```

Java itself supports callbacks, futures, streams, and reactive libraries. The
blocking pull interface is a small-client design decision, not a Java limitation.
See the complete validation journey in the [canonical example](examples/basics/Main.java).

## Status

The checked-in manifest records this implementation as native and the repository's
existing shared local and hosted evidence awarded both HTTP and Live. This README
does not claim a new verification run.

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Live query subscriptions | Verified by shared local and hosted conformance |
| Authentication | HTTP bearer tokens only |

## Example

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

## Implementation Notes

- The client is native Java. JDK 21's `HttpClient` handles HTTP and WebSocket
  transport, and Jackson 2.18.2 handles JSON. Convex-specific requests,
  responses, subscriptions, reconnects, and errors are implemented in the Java
  sources rather than delegated to another Convex client.
- HTTP queries, mutations, and actions use Convex's documented JSON endpoints.
  A `Result` record keeps the returned value and function log lines together,
  while function, protocol, and transport failures use separate exception
  types. Bearer authentication currently applies only to this HTTP client.
- Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`.
  Each `Subscription` keeps at most the newest 16 updates and `next` waits for
  the consumer's next value. Reconnects restore active queries. The conformance
  adapter has a test-only `debugDisconnect` command to exercise that recovery.
- Maven compilation, tests, and dependency resolution stay inside Docker. The
  runtime image uses `jlink` to carry only the Java modules this client needs,
  with no compiler or Maven command in the final image.

## Known Issues

1. Live authentication is deferred. `setAuth` sends bearer tokens for HTTP
   calls only.
2. Values are limited to the JSON-safe subset used by this experiment. The API
   returns Jackson `JsonNode` values rather than generated Java domain types.
3. Live supports query subscriptions, but WebSocket mutations and actions,
   transition chunks, optimistic updates, journals, and mutation replay are not
   implemented.
4. A slow Live consumer can lose older intermediate values because each
   subscription deliberately retains only its newest 16 updates.
