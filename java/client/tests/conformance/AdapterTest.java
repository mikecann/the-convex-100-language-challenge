package convex.adapter;

import com.fasterxml.jackson.databind.JsonNode;
import convex.ConvexClient;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Adapter TCP, optional-field, close, and structured-error serialization tests. */
public final class AdapterTest {
  public static void main(String[] args) throws Exception {
    JsonNode result = Adapter.result("query", new ConvexClient.Result(
      ConvexClient.JSON.createObjectNode().put("count", 1), List.of("query log")));
    check("result".equals(result.path("type").asText()), "wrong success event type");
    check(result.path("value").path("count").asInt() == 1, "lost success value");
    check("query log".equals(result.path("logs").path(0).asText()), "lost success logs");
    JsonNode resultWithoutLogs = Adapter.result("query-empty", new ConvexClient.Result(
      ConvexClient.JSON.createObjectNode().put("count", 0), List.of()));
    check(!resultWithoutLogs.has("logs"), "serialized absent success logs");

    JsonNode failed = Adapter.failure("request", "", new ConvexClient.FunctionException(
      "query", "empty", ConvexClient.JSON.createObjectNode().put("code", "ROOM_EMPTY"), List.of("checked")));
    check("ROOM_EMPTY".equals(failed.path("error").path("data").path("code").asText()), "lost error.data");
    check(!failed.has("subscriptionId"), "serialized absent subscriptionId");

    JsonNode subscriptionFailure = Adapter.failure("", "room", new IllegalStateException("broken"));
    check(!subscriptionFailure.has("id"), "serialized absent id");
    check("room".equals(subscriptionFailure.path("subscriptionId").asText()), "lost subscriptionId");

    try (ServerSocket server = Adapter.bind("127.0.0.1:0")) {
      Thread adapter = new Thread(() -> {
        try (Socket controller = server.accept()) {
          Adapter.run(controller.getInputStream(), controller.getOutputStream(), null);
        } catch (Exception error) { throw new RuntimeException(error); }
      });
      adapter.start();
      try (Socket controller = new Socket("127.0.0.1", server.getLocalPort());
           PrintWriter commands = new PrintWriter(controller.getOutputStream(), true, StandardCharsets.UTF_8);
           BufferedReader events = new BufferedReader(new InputStreamReader(controller.getInputStream(), StandardCharsets.UTF_8))) {
        commands.println("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}");
        JsonNode ready = ConvexClient.JSON.readTree(events.readLine());
        check("ready".equals(ready.path("type").asText()) && "java".equals(ready.path("language").asText()), "bad TCP hello");
        commands.println("{\"id\":\"close\",\"op\":\"close\"}");
        JsonNode closed = ConvexClient.JSON.readTree(events.readLine());
        check("closed".equals(closed.path("type").asText()), "bad TCP close");
      }
      adapter.join(2_000);
      check(!adapter.isAlive(), "adapter did not close TCP session");
    }
    System.out.println("adapter tests passed");
  }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
