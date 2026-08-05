package convex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;

/** Native Java access to Convex's documented JSON HTTP functions API. */
public final class ConvexClient implements AutoCloseable {
  public static final ObjectMapper JSON = new ObjectMapper();
  private final URI deployment;
  private final HttpClient http =
      HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();
  private volatile String token = "";
  private volatile boolean closed;

  public ConvexClient(String deploymentUrl) {
    URI parsed = URI.create(deploymentUrl);
    if (!("http".equals(parsed.getScheme()) || "https".equals(parsed.getScheme()))
        || parsed.getHost() == null
        || parsed.getUserInfo() != null) {
      throw new IllegalArgumentException(
          "Convex deployment URL must be http(s), have a host, and omit user info");
    }
    this.deployment = URI.create(parsed.toString().replaceAll("/+$", ""));
  }

  public void setAuth(String bearerToken) {
    ensureOpen();
    token = bearerToken == null ? "" : bearerToken;
  }

  public Result query(String path, JsonNode args) throws Exception {
    return call("query", path, args);
  }

  public Result mutation(String path, JsonNode args) throws Exception {
    return call("mutation", path, args);
  }

  public Result action(String path, JsonNode args) throws Exception {
    return call("action", path, args);
  }

  private Result call(String operation, String path, JsonNode args) throws Exception {
    ensureOpen();
    if (path == null || path.isBlank())
      throw new IllegalArgumentException("Convex function path is required");
    if (args == null || !args.isObject())
      throw new IllegalArgumentException("Convex arguments must be a named JSON object");
    ObjectNode body = JSON.createObjectNode().put("path", path).set("args", args);
    body.put("format", "json");
    HttpRequest.Builder request =
        HttpRequest.newBuilder(deployment.resolve("/api/" + operation))
            .timeout(Duration.ofSeconds(30))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("Convex-Client", "java-0.1.0")
            .POST(HttpRequest.BodyPublishers.ofString(JSON.writeValueAsString(body)));
    if (!token.isEmpty()) request.header("Authorization", "Bearer " + token);
    HttpResponse<String> response;
    try {
      response = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    } catch (Exception e) {
      throw new TransportException(operation, e);
    }
    JsonNode decoded;
    try {
      decoded = JSON.readTree(response.body());
    } catch (Exception e) {
      throw new TransportException(
          operation, new IllegalStateException("non-Convex HTTP response", e));
    }
    if ("success".equals(decoded.path("status").asText())) {
      if (!decoded.has("value")) throw new ProtocolException("success response omitted value");
      return new Result(decoded.get("value"), logs(decoded));
    }
    if ("error".equals(decoded.path("status").asText()))
      throw new FunctionException(
          operation,
          decoded.path("errorMessage").asText("Convex function failed"),
          decoded.get("errorData"),
          logs(decoded));
    throw new ProtocolException("HTTP " + response.statusCode() + " response has unknown status");
  }

  private static List<String> logs(JsonNode n) {
    return n.path("logLines").isArray()
        ? JSON.convertValue(
            n.path("logLines"),
            JSON.getTypeFactory().constructCollectionType(List.class, String.class))
        : List.of();
  }

  private void ensureOpen() {
    if (closed) throw new IllegalStateException("Convex client is closed");
  }

  @Override
  public void close() {
    closed = true;
  }

  public record Result(JsonNode value, List<String> logs) {}

  public static class TransportException extends Exception {
    public final String operation;

    public TransportException(String op, Throwable cause) {
      super(cause.getMessage(), cause);
      operation = op;
    }
  }

  public static class ProtocolException extends Exception {
    public ProtocolException(String message) {
      super(message);
    }
  }

  public static class FunctionException extends Exception {
    public final String operation;
    public final JsonNode data;
    public final List<String> logs;

    public FunctionException(String op, String message, JsonNode data, List<String> logs) {
      super(message);
      operation = op;
      this.data = data;
      this.logs = logs;
    }
  }
}
