package convex.adapter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;
import convex.LiveClient;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/** Test-only NDJSON adapter protocol v1 endpoint. */
public final class Adapter {
  public static void main(String[] args) throws Exception {
    String listen = System.getenv("ADAPTER_LISTEN");
    if (listen == null || listen.isBlank()) {
      run(System.in, System.out, System.getenv("CONVEX_URL"));
      return;
    }
    try (ServerSocket server = bind(listen); Socket controller = server.accept()) {
      run(controller.getInputStream(), controller.getOutputStream(), System.getenv("CONVEX_URL"));
    }
  }

  static ServerSocket bind(String address) throws Exception {
    int separator = address.lastIndexOf(':');
    if (separator < 1) throw new IllegalArgumentException("ADAPTER_LISTEN must be host:port");
    String host = address.substring(0, separator);
    int port = Integer.parseInt(address.substring(separator + 1));
    ServerSocket server = new ServerSocket();
    server.bind(new InetSocketAddress(InetAddress.getByName(host), port));
    return server;
  }

  static void run(InputStream source, OutputStream sink, String deploymentUrl) throws Exception {
    BufferedReader input = new BufferedReader(new InputStreamReader(source, StandardCharsets.UTF_8));
    Output output = new Output(sink);
    Map<String, LiveClient.Subscription> subscriptions = new ConcurrentHashMap<>();
    AtomicBoolean closing = new AtomicBoolean();
    ConvexClient client = null;
    LiveClient live = null;

    for (String line; (line = input.readLine()) != null;) {
      JsonNode command;
      try { command = ConvexClient.JSON.readTree(line); }
      catch (Exception error) { output.write(failure("", "", error)); continue; }
      String id = command.path("id").asText("");
      String operation = command.path("op").asText("");
      try {
        if ("hello".equals(operation)) {
          if (command.path("protocolVersion").asInt() != 1) throw new IllegalArgumentException("unsupported adapter protocol version");
          output.write(event("ready", id).put("protocolVersion", 1).put("language", "java")
            .put("implementation", "native-java-21").put("runtime", System.getProperty("java.runtime.version")));
          continue;
        }
        if ("close".equals(operation)) {
          closing.set(true);
          for (LiveClient.Subscription subscription : subscriptions.values()) {
            try { subscription.close(); } catch (Exception ignored) { /* Shutdown remains best-effort and idempotent. */ }
          }
          subscriptions.clear();
          if (live != null) live.close();
          if (client != null) client.close();
          output.write(event("closed", id));
          return;
        }
        if (deploymentUrl == null || deploymentUrl.isBlank()) throw new IllegalStateException("CONVEX_URL is required");
        if (client == null) client = new ConvexClient(deploymentUrl);

        if ("setAuth".equals(operation)) {
          client.setAuth(command.path("token").asText());
          output.write(event("ack", id));
        } else if (Set.of("query", "mutation", "action").contains(operation)) {
          JsonNode args = command.has("args") ? command.get("args") : ConvexClient.JSON.createObjectNode();
          ConvexClient.Result result = switch (operation) {
            case "query" -> client.query(command.path("path").asText(), args);
            case "mutation" -> client.mutation(command.path("path").asText(), args);
            default -> client.action(command.path("path").asText(), args);
          };
          output.write(result(id, result));
        } else if ("subscribe".equals(operation)) {
          String subscriptionId = command.path("subscriptionId").asText("");
          if (subscriptionId.isBlank()) throw new IllegalArgumentException("subscriptionId is required");
          if (live == null) live = new LiveClient(deploymentUrl);
          LiveClient.Subscription previous = subscriptions.remove(subscriptionId);
          if (previous != null) previous.close();
          LiveClient.Subscription subscription = live.subscribe(command.path("path").asText(),
            command.has("args") ? command.get("args") : ConvexClient.JSON.createObjectNode());
          subscriptions.put(subscriptionId, subscription);
          output.write(event("ack", id));
          Thread worker = new Thread(() -> relay(subscriptionId, subscription, subscriptions, closing, output), "convex-java-adapter-" + subscriptionId);
          worker.setDaemon(true);
          worker.start();
        } else if ("unsubscribe".equals(operation)) {
          String subscriptionId = command.path("subscriptionId").asText("");
          LiveClient.Subscription subscription = subscriptions.remove(subscriptionId);
          if (subscription != null) subscription.close();
          output.write(event("ack", id));
        } else if ("debugDisconnect".equals(operation)) {
          if (live == null) throw new IllegalStateException("Live WebSocket is not connected");
          live.debugDisconnect();
          output.write(event("ack", id));
        } else {
          throw new IllegalArgumentException("unknown operation: " + operation);
        }
      } catch (Exception error) {
        output.write(failure(id, "", error));
      }
    }

    closing.set(true);
    if (live != null) live.close();
    if (client != null) client.close();
  }

  private static void relay(String subscriptionId, LiveClient.Subscription subscription,
      Map<String, LiveClient.Subscription> subscriptions, AtomicBoolean closing, Output output) {
    while (!closing.get() && subscriptions.get(subscriptionId) == subscription) {
      try {
        LiveClient.Update update = subscription.nextUpdate(Duration.ofDays(1));
        if (update.error() != null) output.write(failure("", subscriptionId, update.error()));
        else {
          ObjectNode response = event("subscription", "").put("subscriptionId", subscriptionId).set("value", update.value());
          if (!update.logs().isEmpty()) response.set("logs", ConvexClient.JSON.valueToTree(update.logs()));
          output.write(response);
        }
      } catch (Exception error) {
        if (!closing.get() && subscriptions.get(subscriptionId) == subscription)
          output.write(failure("", subscriptionId, error));
        return;
      }
    }
  }

  static ObjectNode failure(String id, String subscriptionId, Exception error) {
    ObjectNode response = event(subscriptionId.isBlank() ? "error" : "subscription", id);
    if (!subscriptionId.isBlank()) response.put("subscriptionId", subscriptionId);
    String name = error instanceof ConvexClient.FunctionException ? "FunctionError"
      : error instanceof ConvexClient.ProtocolException ? "ProtocolError"
      : error instanceof ConvexClient.TransportException ? "TransportError"
      : error.getClass().getSimpleName();
    ObjectNode detail = response.putObject("error").put("name", name)
      .put("message", error.getMessage() == null ? name : error.getMessage());
    if (error instanceof ConvexClient.FunctionException function) {
      if (function.data != null) detail.set("data", function.data);
      if (!function.logs.isEmpty()) response.set("logs", ConvexClient.JSON.valueToTree(function.logs));
    }
    return response;
  }

  static ObjectNode result(String id, ConvexClient.Result result) {
    ObjectNode response = event("result", id).set("value", result.value());
    if (!result.logs().isEmpty()) response.set("logs", ConvexClient.JSON.valueToTree(result.logs()));
    return response;
  }

  private static ObjectNode event(String type, String id) {
    ObjectNode event = ConvexClient.JSON.createObjectNode().put("type", type);
    if (id != null && !id.isBlank()) event.put("id", id);
    return event;
  }

  private static final class Output {
    private final PrintWriter writer;
    private Output(OutputStream sink) { writer = new PrintWriter(sink, true, StandardCharsets.UTF_8); }
    private synchronized void write(ObjectNode event) { writer.println(event); }
  }
}
