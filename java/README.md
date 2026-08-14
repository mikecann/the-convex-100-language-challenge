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

### The closing brace is the unsubscribe

Java 7's try-with-resources gives any `AutoCloseable` object a scoped lifetime:
declare it inside the `try` parentheses and the runtime closes it on every exit
path. The HTTP client, the Live WebSocket connection, and each subscription are
all resources here, so the reactive lifecycle React hides inside hooks becomes a
visible block:

```java
try (ConvexClient http = new ConvexClient(url);
    LiveClient live = new LiveClient(url);
    LiveClient.Subscription subscription = live.subscribe("demo:state", roomArgs)) {
  // TypeScript: const state = useQuery(api.demo.state, { room }) — React owns the lifecycle.
  JsonNode initial = subscription.next(Duration.ofSeconds(10));
  http.mutation("demo:increment", mutationArgs);
  JsonNode updated = subscription.next(Duration.ofSeconds(10)); // the reactive update arrives
} // Leaving the block unsubscribes and closes both clients, even after an exception.
```

Where React unmounts a component to end a `useQuery`, Java simply leaves a block.

### One record line carries the whole reply

Java was famously ceremonious about small classes until records arrived in
Java 16: one line declares an immutable carrier with a constructor, accessors,
`equals`, and `hashCode`. This client's HTTP result is exactly that, keeping the
Convex value and the function's server-side log lines together:

```java
public record Result(JsonNode value, List<String> logs) {}

ConvexClient.Result result = client.query("demo:state", roomArgs);
int count = result.value().path("count").intValue();
result.logs().forEach(System.out::println); // console.log lines from the Convex function
```

### Checked exceptions put failure in the signature

Checked exceptions are Java's most-debated feature: when a method declares
`throws FunctionException`, the compiler refuses callers that ignore it. The
client uses that to split failures into three types, so "your Convex function
threw" can never be confused with "the network died":

```java
try {
  client.mutation("demo:increment", mutationArgs);
} catch (ConvexClient.FunctionException error) {
  // The Convex function itself threw: message, structured errorData, and its logs.
  System.err.println(error.getMessage() + " " + error.data);
} catch (ConvexClient.TransportException error) {
  // The network failed before Convex ever answered.
}
// TypeScript: one thrown value, and nothing forces you to write the catch.
```

### An arrow switch sorts the Live wire

When a `Transition` frame arrives on the WebSocket, `LiveClient` routes each
modification with Java 14's arrow `switch` — no fall-through, no `break`, and a
`default` arm that makes an unknown protocol message loud instead of silently
dropped. This is real code from [`LiveClient.java`](client/java/convex/LiveClient.java):

```java
switch (modification.path("type").asText()) {
  case "QueryUpdated" ->
      changed.put(queryId, new Update(modification.get("value"), null, logs));
  case "QueryFailed" ->
      changed.put(queryId, new Update(null,
          new ConvexClient.FunctionException("query",
              modification.path("errorMessage").asText(),
              modification.get("errorData"), logs), logs));
  case "QueryRemoved" -> {}
  default -> throw new IllegalStateException("unknown Transition modification");
}
```

Every reactive update your React app ever received went through a decoder shaped
like this one.

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
