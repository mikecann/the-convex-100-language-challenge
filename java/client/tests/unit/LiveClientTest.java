package convex;

import com.fasterxml.jackson.databind.JsonNode;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** Focused buffering and real WebSocket reconnect/resubscribe checks. */
public final class LiveClientTest {
  public static void main(String[] args) throws Exception {
    boundedDeliveryKeepsNewestValues();
    reconnectRestoresActiveQuery();
    System.out.println("client Live tests passed");
  }

  private static void boundedDeliveryKeepsNewestValues() throws Exception {
    LiveClient.Subscription subscription = new LiveClient.Subscription(null, 7, "demo:state", ConvexClient.JSON.createObjectNode());
    for (int count = 0; count < 20; count++)
      subscription.offer(new LiveClient.Update(ConvexClient.JSON.createObjectNode().put("count", count), null, List.of()));
    check(subscription.next(Duration.ofMillis(10)).path("count").asInt() == 4, "buffer was not bounded to newest 16");
    for (int expected = 5; expected < 20; expected++)
      check(subscription.next(Duration.ofMillis(10)).path("count").asInt() == expected, "delivery order changed");
  }

  private static void reconnectRestoresActiveQuery() throws Exception {
    try (ServerSocket listener = new ServerSocket(0)) {
      Throwable[] serverFailure = new Throwable[1];
      AtomicLong disconnectNanos = new AtomicLong();
      AtomicLong reconnectDelayMillis = new AtomicLong();
      Thread server = new Thread(() -> {
        try {
          serveConnection(listener.accept(), 0, 0);
          Socket restored = listener.accept();
          long delayMillis = TimeUnit.NANOSECONDS.toMillis(
            System.nanoTime() - disconnectNanos.get());
          reconnectDelayMillis.set(delayMillis);

          // Model the harness race: the external mutation becomes visible after
          // 75 ms. An immediate reconnect therefore restores stale count 0,
          // while the normal 100 ms backoff restores the changed count 1.
          serveConnection(restored, 1, delayMillis >= 75 ? 1 : 0);
        } catch (Throwable error) { serverFailure[0] = error; }
      }, "fake-convex-sync");
      server.start();
      try (LiveClient live = new LiveClient("http://127.0.0.1:" + listener.getLocalPort());
           LiveClient.Subscription subscription = live.subscribe("demo:state", ConvexClient.JSON.createObjectNode().put("room", "reconnect"))) {
        check(subscription.next(Duration.ofSeconds(3)).path("count").asInt() == 0, "missing initial transition");
        disconnectNanos.set(System.nanoTime());
        live.debugDisconnect();
        check(subscription.next(Duration.ofSeconds(3)).path("count").asInt() == 1, "missing post-reconnect transition");
      }
      server.join(3_000);
      check(!server.isAlive(), "fake sync server did not finish");
      if (serverFailure[0] != null) throw new AssertionError("fake sync server failed", serverFailure[0]);
      check(reconnectDelayMillis.get() >= 75, "debug disconnect bypassed normal reconnect backoff");
    }
  }

  private static void serveConnection(Socket socket, int expectedConnectionCount, int count) throws Exception {
    try (socket) {
      InputStream input = socket.getInputStream(); OutputStream output = socket.getOutputStream();
      String headers = readHeaders(input);
      String key = header(headers, "sec-websocket-key");
      String accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1")
        .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes(StandardCharsets.US_ASCII)));
      output.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
      output.flush();
      JsonNode connect = ConvexClient.JSON.readTree(readClientText(input));
      check(connect.path("connectionCount").asInt() == expectedConnectionCount, "wrong connectionCount");
      JsonNode modify = ConvexClient.JSON.readTree(readClientText(input));
      check("Add".equals(modify.path("modifications").path(0).path("type").asText()), "active query was not restored");
      int queryId = modify.path("modifications").path(0).path("queryId").asInt();
      String endTimestamp = count == 0 ? "AQAAAAAAAAA=" : "AgAAAAAAAAA=";
      JsonNode transition = ConvexClient.JSON.readTree("{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"" + endTimestamp + "\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":" + queryId + ",\"value\":{\"count\":" + count + "},\"logLines\":[]}]}" );
      writeServerText(output, transition.toString());
      if (count == 0) while (input.read() != -1) { }
    }
  }

  private static String readHeaders(InputStream input) throws Exception {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(); int matched = 0;
    while (matched < 4) { int value=input.read(); if(value<0) throw new IllegalStateException("EOF in handshake"); bytes.write(value); matched = switch(matched) { case 0 -> value=='\r'?1:0; case 1 -> value=='\n'?2:0; case 2 -> value=='\r'?3:0; default -> value=='\n'?4:0; }; }
    return bytes.toString(StandardCharsets.US_ASCII);
  }
  private static String header(String headers, String name) {
    for (String line : headers.split("\r\n")) { int separator=line.indexOf(':'); if(separator>0 && line.substring(0,separator).toLowerCase(Locale.ROOT).equals(name)) return line.substring(separator+1).trim(); }
    throw new IllegalStateException("missing " + name);
  }
  private static String readClientText(InputStream input) throws Exception {
    int first=input.read(), second=input.read(); if(first<0||second<0) throw new IllegalStateException("EOF in frame");
    int length=second&0x7f; if(length==126) length=(input.read()<<8)|input.read(); else if(length==127) { long large=0; for(int i=0;i<8;i++) large=(large<<8)|input.read(); length=Math.toIntExact(large); }
    byte[] mask=input.readNBytes(4), payload=input.readNBytes(length); for(int i=0;i<payload.length;i++) payload[i]^=mask[i%4]; return new String(payload,StandardCharsets.UTF_8);
  }
  private static void writeServerText(OutputStream output, String text) throws Exception {
    byte[] payload=text.getBytes(StandardCharsets.UTF_8); output.write(0x81); if(payload.length<126) output.write(payload.length); else { output.write(126); output.write(payload.length>>>8); output.write(payload.length); } output.write(payload); output.flush();
  }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
