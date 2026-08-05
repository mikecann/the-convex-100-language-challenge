package convex;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Language-local HTTP and structured-error checks, run inside Docker. */
public final class ConvexClientTest {
  public static void main(String[] args) throws Exception {
    try {
      new ConvexClient("ftp://example.com");
      throw new AssertionError("accepted ftp URL");
    } catch (IllegalArgumentException expected) {
    }

    HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/api/query",
        exchange -> {
          String response =
              "{\"status\":\"error\",\"errorMessage\":\"empty\",\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[\"checked\"]}";
          exchange.sendResponseHeaders(560, response.length());
          exchange.getResponseBody().write(response.getBytes(StandardCharsets.UTF_8));
          exchange.close();
        });
    server.start();
    try (ConvexClient client =
        new ConvexClient("http://127.0.0.1:" + server.getAddress().getPort())) {
      try {
        client.query("demo:requiresNonzero", ConvexClient.JSON.createObjectNode());
        throw new AssertionError("error response became success");
      } catch (ConvexClient.FunctionException error) {
        check("ROOM_EMPTY".equals(error.data.path("code").asText()), "lost structured error code");
        check(error.logs.equals(List.of("checked")), "lost function logs");
      }
    } finally {
      server.stop(0);
    }
    System.out.println("client HTTP tests passed");
  }

  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}
