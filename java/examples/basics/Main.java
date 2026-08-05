package convex.example;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;
import convex.LiveClient;
import java.time.Duration;
import java.util.UUID;

/** The canonical teaching example, also installed unchanged in the example image. */
public final class Main {
  private static int count(JsonNode state, String operation) { if (!state.path("count").canConvertToInt()) throw new IllegalStateException(operation + " did not return a whole count"); return state.path("count").intValue(); }
  public static void main(String[] args) throws Exception {
    // Read configuration from the verifier rather than baking a deployment into the image.
    String url = System.getenv("CONVEX_URL"); if (url == null) throw new IllegalStateException("CONVEX_URL is required");
    // Use a unique room so separate example runs cannot change each other's counter.
    String room = args.length == 0 ? "java-example" : args[0]; ObjectNode roomArgs = ConvexClient.JSON.createObjectNode().put("room", room);
    // Create one native HTTP client and one Live connection, both cleaned up on every exit path.
    try (ConvexClient client = new ConvexClient(url); LiveClient live = new LiveClient(url)) {
      // First ask the documented HTTP query API for the current state.
      int before = count(client.query("demo:state", roomArgs).value(), "current query"); System.out.println("current count: " + before);
      // Start Live before mutating so its initial value establishes the observation point.
      try (LiveClient.Subscription subscription = live.subscribe("demo:state", roomArgs)) {
        int initial = count(subscription.next(Duration.ofSeconds(10)), "initial Live value"); if(initial != before) throw new IllegalStateException("Live initial value disagreed"); System.out.println("live initial count: " + initial);
        // The random runId is the mutation's idempotency key, avoiding duplicate increments on a retry.
        ObjectNode mutationArgs = roomArgs.deepCopy().put("language", "java").put("runId", UUID.randomUUID().toString()); JsonNode mutation = client.mutation("demo:increment", mutationArgs).value();
        if (!mutation.path("applied").asBoolean()) throw new IllegalStateException("mutation was not applied"); System.out.println("mutation applied: true");
        int after = count(mutation.path("state"), "mutation"); if(after != before + 1) throw new IllegalStateException("mutation count was unexpected"); System.out.println("mutation count: " + after);
        int updated = count(subscription.next(Duration.ofSeconds(10)), "updated Live value"); if(updated != after) throw new IllegalStateException("Live update disagreed"); System.out.println("live updated count: " + updated);
        // Print only after HTTP and Live agree on the complete 0 to 1 journey.
        System.out.println("verified count: " + before + " -> " + updated);
      }
    }
  }
}
