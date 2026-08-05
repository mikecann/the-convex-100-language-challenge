package convex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.BlockingDeque;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Native implementation of the pinned convex-rs 0.10.4 unversioned sync profile. */
public final class LiveClient implements AutoCloseable, WebSocket.Listener {
  private static final String INITIAL_TIMESTAMP = "AAAAAAAAAAA=";
  private static final long INITIAL_BACKOFF_MILLIS = 100;
  private static final long MAX_BACKOFF_MILLIS = 15_000;

  private final URI endpoint;
  private final HttpClient http = HttpClient.newHttpClient();
  private final ScheduledExecutorService scheduler =
      Executors.newSingleThreadScheduledExecutor(
          r -> {
            Thread thread = new Thread(r, "convex-java-live");
            thread.setDaemon(true);
            return thread;
          });
  private final Map<Integer, Subscription> subscriptions = new LinkedHashMap<>();
  private int nextId;
  private int querySetVersion;
  private int connectionCount;
  private long reconnectBackoffMillis = INITIAL_BACKOFF_MILLIS;
  private String lastCloseReason = "InitialConnect";
  private String maxObservedTimestamp;
  private JsonNode remoteVersion = zeroVersion();
  private WebSocket socket;
  private boolean reconnectScheduled;
  private boolean closed;
  private final StringBuilder frames = new StringBuilder();

  public LiveClient(String deploymentUrl) {
    URI base = URI.create(deploymentUrl.replaceAll("/+$", ""));
    String scheme = "https".equals(base.getScheme()) ? "wss" : "ws";
    endpoint = URI.create(scheme + "://" + base.getAuthority() + base.getPath() + "/api/sync");
  }

  public synchronized Subscription subscribe(String path, JsonNode args) throws Exception {
    ensureOpen();
    if (path == null || path.isBlank())
      throw new IllegalArgumentException("Convex function path is required");
    if (args == null || !args.isObject())
      throw new IllegalArgumentException("Convex arguments must be a named JSON object");
    Subscription subscription = new Subscription(this, nextId++, path, args.deepCopy());
    subscriptions.put(subscription.queryId, subscription);
    try {
      if (socket == null) connect();
      else modify(List.of(addModification(subscription)));
      return subscription;
    } catch (Exception error) {
      subscriptions.remove(subscription.queryId);
      throw error;
    }
  }

  private synchronized void unsubscribe(Subscription subscription) throws Exception {
    if (subscriptions.remove(subscription.queryId) == null) return;
    subscription.finish();
    if (socket != null)
      modify(
          List.of(
              ConvexClient.JSON
                  .createObjectNode()
                  .put("type", "Remove")
                  .put("queryId", subscription.queryId)));
  }

  private void connect() throws Exception {
    ensureOpen();
    WebSocket connected =
        http.newWebSocketBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .header("Convex-Client", "java-0.1.0")
            .buildAsync(endpoint, this)
            .get(10, TimeUnit.SECONDS);
    socket = connected;
    querySetVersion = 0;
    remoteVersion = zeroVersion();

    ObjectNode connect =
        ConvexClient.JSON
            .createObjectNode()
            .put("type", "Connect")
            .put("sessionId", UUID.randomUUID().toString())
            .put("connectionCount", connectionCount)
            .put("lastCloseReason", lastCloseReason)
            .put("clientTs", 0);
    if (maxObservedTimestamp != null) connect.put("maxObservedTimestamp", maxObservedTimestamp);
    send(connect);
    if (!subscriptions.isEmpty()) {
      List<ObjectNode> additions = new ArrayList<>();
      for (Subscription subscription : subscriptions.values())
        additions.add(addModification(subscription));
      modify(additions);
    }
    reconnectBackoffMillis = INITIAL_BACKOFF_MILLIS;
    reconnectScheduled = false;
  }

  private ObjectNode addModification(Subscription subscription) {
    ObjectNode add =
        ConvexClient.JSON
            .createObjectNode()
            .put("type", "Add")
            .put("queryId", subscription.queryId)
            .put("udfPath", subscription.path);
    add.putArray("args").add(subscription.args);
    return add;
  }

  private void modify(List<ObjectNode> modifications) throws Exception {
    ObjectNode message =
        ConvexClient.JSON
            .createObjectNode()
            .put("type", "ModifyQuerySet")
            .put("baseVersion", querySetVersion)
            .put("newVersion", querySetVersion + 1);
    ArrayNode array = message.putArray("modifications");
    modifications.forEach(array::add);
    send(message);
    querySetVersion++;
  }

  private void send(JsonNode message) throws Exception {
    WebSocket active = socket;
    if (active == null) throw new IllegalStateException("Live WebSocket is not connected");
    active.sendText(ConvexClient.JSON.writeValueAsString(message), true).get(10, TimeUnit.SECONDS);
  }

  @Override
  public void onOpen(WebSocket webSocket) {
    webSocket.request(1);
  }

  @Override
  public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
    synchronized (this) {
      if (webSocket != socket) return CompletableFuture.completedFuture(null);
      frames.append(data);
      if (last) {
        try {
          handle(ConvexClient.JSON.readTree(frames.toString()));
        } catch (Exception error) {
          for (Subscription subscription : subscriptions.values())
            subscription.offer(new Update(null, error, List.of()));
          disconnect("ProtocolError", true);
        } finally {
          frames.setLength(0);
        }
      }
    }
    webSocket.request(1);
    return CompletableFuture.completedFuture(null);
  }

  @Override
  public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
    synchronized (this) {
      if (webSocket == socket) disconnect("ServerClosed:" + statusCode, true);
    }
    return CompletableFuture.completedFuture(null);
  }

  @Override
  public void onError(WebSocket webSocket, Throwable error) {
    synchronized (this) {
      if (webSocket == socket) disconnect("TransportError", true);
    }
  }

  private void handle(JsonNode message) {
    String type = message.path("type").asText();
    if ("Ping".equals(type) || "MutationResponse".equals(type) || "ActionResponse".equals(type))
      return;
    if ("TransitionChunk".equals(type))
      throw new IllegalStateException("TransitionChunk is not supported by the Java demonstration");
    if ("FatalError".equals(type) || "AuthError".equals(type))
      throw new IllegalStateException(type + ": " + message.path("error").asText());
    if (!"Transition".equals(type))
      throw new IllegalStateException("unknown Live message: " + type);
    if (!message.path("startVersion").equals(remoteVersion))
      throw new IllegalStateException("Live transition version mismatch");

    Map<Integer, Update> changed = new LinkedHashMap<>();
    for (JsonNode modification : message.path("modifications")) {
      int queryId = modification.path("queryId").asInt();
      List<String> logs = strings(modification.path("logLines"));
      switch (modification.path("type").asText()) {
        case "QueryUpdated" ->
            changed.put(queryId, new Update(modification.get("value"), null, logs));
        case "QueryFailed" ->
            changed.put(
                queryId,
                new Update(
                    null,
                    new ConvexClient.FunctionException(
                        "query",
                        modification.path("errorMessage").asText(),
                        modification.get("errorData"),
                        logs),
                    logs));
        case "QueryRemoved" -> {}
        default ->
            throw new IllegalStateException(
                "unknown Transition modification: " + modification.path("type").asText());
      }
    }
    remoteVersion = message.path("endVersion").deepCopy();
    maxObservedTimestamp = remoteVersion.path("ts").asText(null);
    for (Map.Entry<Integer, Update> entry : changed.entrySet()) {
      Subscription subscription = subscriptions.get(entry.getKey());
      if (subscription != null) subscription.offer(entry.getValue());
    }
  }

  private static List<String> strings(JsonNode node) {
    if (!node.isArray()) return List.of();
    List<String> values = new ArrayList<>();
    node.forEach(item -> values.add(item.asText()));
    return List.copyOf(values);
  }

  public synchronized void debugDisconnect() {
    ensureOpen();
    if (socket == null) throw new IllegalStateException("Live WebSocket is not connected");
    WebSocket previous = socket;
    socket = null;
    previous.abort();
    connectionCount++;
    lastCloseReason = "DebugDisconnect";
    resetRemoteState();
    // Give an in-flight external mutation a chance to commit before the restored
    // query publishes its first value. This is the normal initial transport
    // backoff, not a special retry loop that could hide a broken connection.
    scheduleReconnect(reconnectBackoffMillis);
  }

  private void disconnect(String reason, boolean reconnect) {
    WebSocket previous = socket;
    socket = null;
    if (previous != null) {
      previous.abort();
      connectionCount++;
    }
    lastCloseReason = reason;
    resetRemoteState();
    if (reconnect) scheduleReconnect(reconnectBackoffMillis);
  }

  private void resetRemoteState() {
    querySetVersion = 0;
    remoteVersion = zeroVersion();
  }

  private void scheduleReconnect(long delayMillis) {
    if (closed || subscriptions.isEmpty() || reconnectScheduled) return;
    reconnectScheduled = true;
    scheduler.schedule(
        () -> {
          synchronized (LiveClient.this) {
            reconnectScheduled = false;
            if (closed || subscriptions.isEmpty() || socket != null) return;
            try {
              connect();
            } catch (Exception error) {
              lastCloseReason = error.getMessage();
              long delay = reconnectBackoffMillis;
              reconnectBackoffMillis = Math.min(MAX_BACKOFF_MILLIS, reconnectBackoffMillis * 2);
              scheduleReconnect(delay);
            }
          }
        },
        delayMillis,
        TimeUnit.MILLISECONDS);
  }

  private static JsonNode zeroVersion() {
    ObjectNode version =
        ConvexClient.JSON
            .createObjectNode()
            .put("querySet", 0)
            .put("identity", 0)
            .put("ts", INITIAL_TIMESTAMP);
    return version;
  }

  private void ensureOpen() {
    if (closed) throw new IllegalStateException("Convex Live client is closed");
  }

  @Override
  public synchronized void close() {
    if (closed) return;
    closed = true;
    WebSocket previous = socket;
    socket = null;
    if (previous != null) previous.sendClose(WebSocket.NORMAL_CLOSURE, "closed");
    subscriptions.values().forEach(Subscription::finish);
    subscriptions.clear();
    scheduler.shutdownNow();
  }

  public record Update(JsonNode value, Exception error, List<String> logs) {}

  public static final class Subscription implements AutoCloseable {
    private static final Update CLOSED =
        new Update(null, new IllegalStateException("Live subscription is closed"), List.of());
    private final LiveClient manager;
    private final int queryId;
    private final String path;
    private final JsonNode args;
    private final BlockingDeque<Update> updates = new LinkedBlockingDeque<>(16);
    private boolean closed;

    Subscription(LiveClient manager, int queryId, String path, JsonNode args) {
      this.manager = manager;
      this.queryId = queryId;
      this.path = path;
      this.args = args;
    }

    void offer(Update update) {
      if (closed) return;
      if (!updates.offerLast(update)) {
        updates.pollFirst();
        updates.offerLast(update);
      }
    }

    public Update nextUpdate(Duration timeout) throws Exception {
      Update update = updates.poll(timeout.toMillis(), TimeUnit.MILLISECONDS);
      if (update == null) throw new TimeoutException("timed out waiting for Live update");
      if (update == CLOSED) throw new IllegalStateException("Live subscription is closed");
      return update;
    }

    public JsonNode next(Duration timeout) throws Exception {
      Update update = nextUpdate(timeout);
      if (update.error != null) throw update.error;
      return update.value;
    }

    private void finish() {
      closed = true;
      updates.clear();
      updates.offer(CLOSED);
    }

    @Override
    public void close() {
      if (closed) return;
      try {
        manager.unsubscribe(this);
      } catch (Exception error) {
        throw new IllegalStateException("failed to unsubscribe Live query", error);
      }
    }
  }
}
