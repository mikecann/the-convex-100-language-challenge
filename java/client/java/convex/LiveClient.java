package convex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Deliberately small implementation of the pinned unversioned Convex sync profile. */
public final class LiveClient implements AutoCloseable, WebSocket.Listener {
  private final URI endpoint;
  private final HttpClient http = HttpClient.newHttpClient();
  private final Map<Integer, Subscription> subscriptions = new ConcurrentHashMap<>();
  private final AtomicInteger nextId = new AtomicInteger();
  private volatile WebSocket socket;
  private volatile int querySetVersion;
  private volatile JsonNode version;
  private StringBuilder frames = new StringBuilder();

  public LiveClient(String deploymentUrl) throws Exception {
    URI base = URI.create(deploymentUrl.replaceAll("/+$", ""));
    endpoint = URI.create(("https".equals(base.getScheme()) ? "wss" : "ws") + "://" + base.getAuthority() + base.getPath() + "/api/sync");
    version = ConvexClient.JSON.readTree("{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}");
  }
  public synchronized Subscription subscribe(String path, JsonNode args) throws Exception {
    if (socket == null) connect();
    int id = nextId.getAndIncrement(); Subscription sub = new Subscription(id); subscriptions.put(id, sub);
    ObjectNode add = ConvexClient.JSON.createObjectNode().put("type", "Add").put("queryId", id).put("udfPath", path);
    add.putArray("args").add(args); modify(add); return sub;
  }
  private void connect() throws Exception {
    socket = http.newWebSocketBuilder().connectTimeout(Duration.ofSeconds(10)).buildAsync(endpoint, this).get(10, TimeUnit.SECONDS);
    ObjectNode connect = ConvexClient.JSON.createObjectNode().put("type", "Connect").put("sessionId", UUID.randomUUID().toString()).put("connectionCount", 0).put("lastCloseReason", "InitialConnect").put("clientTs", 0);
    send(connect);
  }
  private void modify(ObjectNode modification) throws Exception {
    ObjectNode message = ConvexClient.JSON.createObjectNode().put("type", "ModifyQuerySet").put("baseVersion", querySetVersion).put("newVersion", querySetVersion + 1);
    message.putArray("modifications").add(modification); querySetVersion++; send(message);
  }
  private void send(JsonNode message) throws Exception { socket.sendText(ConvexClient.JSON.writeValueAsString(message), true).get(10, TimeUnit.SECONDS); }
  @Override public CompletionStage<?> onText(WebSocket ws, CharSequence data, boolean last) {
    frames.append(data); if (!last) return CompletableFuture.completedFuture(null);
    try { handle(ConvexClient.JSON.readTree(frames.toString())); } catch (Exception e) { subscriptions.values().forEach(s -> s.fail(e)); } finally { frames = new StringBuilder(); }
    ws.request(1); return CompletableFuture.completedFuture(null);
  }
  @Override public void onOpen(WebSocket ws) { ws.request(1); }
  private void handle(JsonNode message) {
    if (!"Transition".equals(message.path("type").asText())) return;
    if (!message.path("startVersion").equals(version)) throw new IllegalStateException("Live transition version mismatch");
    version = message.path("endVersion");
    for (JsonNode mod : message.path("modifications")) if ("QueryUpdated".equals(mod.path("type").asText())) {
      Subscription sub = subscriptions.get(mod.path("queryId").asInt()); if (sub != null) sub.offer(mod.get("value"));
    } else if ("QueryFailed".equals(mod.path("type").asText())) { Subscription sub=subscriptions.get(mod.path("queryId").asInt()); if(sub!=null) sub.fail(new IllegalStateException(mod.path("errorMessage").asText())); }
  }
  public synchronized void debugDisconnect() { if (socket == null) throw new IllegalStateException("Live WebSocket is not connected"); socket.abort(); socket = null; }
  @Override public void close() { if (socket != null) socket.sendClose(WebSocket.NORMAL_CLOSURE, "closed"); subscriptions.values().forEach(Subscription::close); subscriptions.clear(); }
  public static final class Subscription implements AutoCloseable {
    private final int id; private final BlockingDeque<JsonNode> values = new LinkedBlockingDeque<>(16); private volatile Exception error;
    Subscription(int id) { this.id=id; } void offer(JsonNode value) { if (!values.offerLast(value)) { values.pollFirst(); values.offerLast(value); } } void fail(Exception e) { error=e; }
    public JsonNode next(Duration timeout) throws Exception { if(error!=null) throw error; JsonNode value=values.poll(timeout.toMillis(), TimeUnit.MILLISECONDS); if(value==null) throw new TimeoutException("timed out waiting for Live update"); return value; }
    @Override public void close() { values.clear(); }
  }
}
