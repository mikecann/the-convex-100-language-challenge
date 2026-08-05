package convex

import groovy.json.JsonOutput
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native implementation of the pinned unversioned Convex sync profile.
 * State changes occur on owner only. The WebSocket listener merely queues work
 * there, so a controller thread can never concurrently write or alter a query set.
 */
final class LiveClient implements AutoCloseable {
  static final String INITIAL_TIMESTAMP = 'AAAAAAAAAAA='
  static final long INITIAL_BACKOFF_MS = 100L
  static final long MAX_BACKOFF_MS = 15_000L
  private final URI endpoint
  private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()
  private final ScheduledExecutorService owner = Executors.newSingleThreadScheduledExecutor { r -> new Thread(r, 'convex-groovy-live') }
  private final LinkedHashMap<Integer, Subscription> subscriptions = [:]
  private int nextId = 0
  private int querySetVersion = 0
  private int connectionCount = 0
  private long reconnectBackoffMs = INITIAL_BACKOFF_MS
  private String lastCloseReason = 'InitialConnect'
  private String maxObservedTimestamp
  private Map remoteVersion = zeroVersion()
  private WebSocket socket
  private boolean reconnectScheduled = false
  private boolean closed = false
  private long socketGeneration = 0
  private final StringBuilder fragments = new StringBuilder()

  LiveClient(String deploymentUrl) {
    URI base = URI.create(deploymentUrl.replaceAll('/+$', ''))
    String scheme = base.scheme == 'https' ? 'wss' : base.scheme == 'http' ? 'ws' : null
    if (!scheme || !base.host) throw new IllegalArgumentException('Convex deployment URL must be http(s)')
    endpoint = URI.create("${scheme}://${base.rawAuthority ?: base.authority}${base.rawPath ?: ''}/api/sync")
  }

  Subscription subscribe(String path, Map args) {
    if (!path?.trim()) throw new IllegalArgumentException('Convex function path is required')
    if (args == null) throw new IllegalArgumentException('Convex arguments must be a named JSON object')
    onOwner {
      ensureOpen()
      Subscription sub = new Subscription(this, nextId++, path, deepCopy(args))
      subscriptions[sub.queryId] = sub
      try {
        if (socket == null) connect()
        else modify([addModification(sub)])
        return sub
      } catch (Throwable error) {
        subscriptions.remove(sub.queryId); sub.finish(); throw error
      }
    }
  }

  void unsubscribe(Subscription sub) { onOwner {
    if (subscriptions.remove(sub.queryId) == null) return
    // This invalidates the relay before its caller receives an acknowledgement.
    sub.finish()
    if (socket != null) modify([[type: 'Remove', queryId: sub.queryId]])
  } }

  void debugDisconnect() { onOwner {
    ensureOpen()
    if (socket == null) throw new IllegalStateException('Live WebSocket is not connected')
    retire('DebugDisconnect', true)
  } }

  private void connect() {
    ensureOpen()
    long generation = ++socketGeneration
    WebSocket ws
    try {
      ws = http.newWebSocketBuilder().connectTimeout(Duration.ofSeconds(10)).header('Convex-Client', 'groovy-0.1.0')
        .buildAsync(endpoint, new Listener(this, generation)).get(10, TimeUnit.SECONDS)
    } catch (Exception error) { throw new ConvexClient.TransportException('live dial', error) }
    socket = ws
    querySetVersion = 0; remoteVersion = zeroVersion()
    // A successful handshake resets exponential retry debt before server traffic arrives.
    reconnectBackoffMs = INITIAL_BACKOFF_MS; reconnectScheduled = false
    send([type: 'Connect', sessionId: UUID.randomUUID().toString(), connectionCount: connectionCount,
          lastCloseReason: lastCloseReason, maxObservedTimestamp: maxObservedTimestamp, clientTs: 0].findAll { it.value != null })
    if (!subscriptions.isEmpty()) modify(subscriptions.values().collect { addModification(it) })
  }

  private Map addModification(Subscription sub) { [type: 'Add', queryId: sub.queryId, udfPath: sub.path, args: [sub.args]] }
  private void modify(List<Map> modifications) {
    send([type: 'ModifyQuerySet', baseVersion: querySetVersion, newVersion: querySetVersion + 1, modifications: modifications])
    querySetVersion++
  }
  private void send(Map message) {
    WebSocket active = socket
    if (active == null) throw new IllegalStateException('Live WebSocket is not connected')
    try { active.sendText(JsonOutput.toJson(message), true).get(10, TimeUnit.SECONDS) }
    catch (Exception error) { throw new ConvexClient.TransportException('live write', error) }
  }

  private void received(long generation, CharSequence data, boolean last) { onOwner {
    if (closed || generation != socketGeneration || socket == null) return
    fragments.append(data)
    if (!last) return
    String frame = fragments.toString(); fragments.setLength(0)
    try { handle((Map) ConvexClient.JSON.parseText(frame)) }
    catch (Throwable error) {
      subscriptions.values().each { it.offer(new Update(null, asProtocol(error), [])) }
      retire('ProtocolError', true)
    }
  } }

  private void handle(Map message) {
    String type = message.type?.toString()
    if (type in ['Ping', 'MutationResponse', 'ActionResponse']) return
    if (type in ['TransitionChunk', 'FatalError', 'AuthError']) throw new ConvexClient.ProtocolException("${type}: ${message.error ?: 'unsupported'}")
    if (type != 'Transition') throw new ConvexClient.ProtocolException("unknown Live message: ${type}")
    if (message.startVersion != remoteVersion) throw new ConvexClient.ProtocolException('Live transition version mismatch')
    Map<Integer, Update> changed = [:]
    (message.modifications ?: []).each { Map mod ->
      int id = (mod.queryId as Number).intValue(); List<String> logs = mod.logLines instanceof List ? mod.logLines.collect { it.toString() } : []
      if (mod.type == 'QueryUpdated') changed[id] = new Update(mod.value, null, logs)
      else if (mod.type == 'QueryFailed') changed[id] = new Update(null, new ConvexClient.FunctionException('query', mod.errorMessage?.toString() ?: 'query failed', mod.errorData, logs), logs)
      else if (mod.type != 'QueryRemoved') throw new ConvexClient.ProtocolException("unknown Transition modification: ${mod.type}")
    }
    remoteVersion = deepCopy((Map) message.endVersion)
    maxObservedTimestamp = remoteVersion.ts?.toString()
    // Deterministic hydration: keep only new encoded values across reconnection.
    changed.each { Integer id, Update update -> subscriptions[id]?.offerIfChanged(update) }
    reconnectBackoffMs = INITIAL_BACKOFF_MS
  }

  private void closedByPeer(long generation, String reason) { onOwner { if (!closed && generation == socketGeneration && socket != null) retire(reason, true) } }
  private void retire(String reason, boolean reconnect) {
    WebSocket previous = socket; socket = null
    if (previous != null) { previous.abort(); connectionCount++ }
    lastCloseReason = reason; querySetVersion = 0; remoteVersion = zeroVersion(); fragments.setLength(0)
    if (reconnect && !subscriptions.isEmpty()) scheduleReconnect(reconnectBackoffMs)
  }
  private void scheduleReconnect(long delay) {
    if (closed || reconnectScheduled || subscriptions.isEmpty()) return
    reconnectScheduled = true
    owner.schedule({
      reconnectScheduled = false
      if (closed || socket != null || subscriptions.isEmpty()) return
      try { connect() }
      catch (Throwable error) {
        lastCloseReason = error.message ?: 'TransportError'
        long next = reconnectBackoffMs
        reconnectBackoffMs = Math.min(MAX_BACKOFF_MS, reconnectBackoffMs * 2L)
        scheduleReconnect(next)
      }
    } as Runnable, delay, TimeUnit.MILLISECONDS)
  }

  private static Map zeroVersion() { [querySet: 0, identity: 0, ts: INITIAL_TIMESTAMP] }
  private static Map deepCopy(Map value) { (Map) ConvexClient.JSON.parseText(JsonOutput.toJson(value)) }
  private static Throwable asProtocol(Throwable error) { error instanceof ConvexClient.ProtocolException ? error : new ConvexClient.ProtocolException(error.message ?: error.class.simpleName) }
  private void ensureOpen() { if (closed) throw new IllegalStateException('Convex Live client is closed') }
  private <T> T onOwner(Closure<T> action) {
    if (Thread.currentThread().name == 'convex-groovy-live') return action.call()
    try { return owner.submit({ action.call() } as Callable<T>).get(15, TimeUnit.SECONDS) }
    catch (ExecutionException error) { Throwable cause = error.cause; if (cause instanceof RuntimeException) throw (RuntimeException) cause; throw new RuntimeException(cause) }
  }
  @Override void close() { onOwner {
    if (closed) return
    closed = true; WebSocket previous = socket; socket = null
    if (previous != null) { try { previous.sendClose(WebSocket.NORMAL_CLOSURE, 'closed').get(2, TimeUnit.SECONDS) } catch (Exception ignored) { previous.abort() } }
    subscriptions.values().each { it.finish() }; subscriptions.clear()
  }; owner.shutdownNow() }

  static record Update(Object value, Throwable error, List<String> logs) {}
  static final class Subscription implements AutoCloseable {
    static final int MAX_EVENTS = 16; static final int MAX_ENCODED_BYTES = 2 * 1024 * 1024
    private final LiveClient manager; final int queryId; final String path; final Map args
    private final ArrayDeque<Update> updates = new ArrayDeque<>(); private final ArrayDeque<Integer> sizes = new ArrayDeque<>()
    private int bytes = 0; private boolean closed = false; private String lastValue
    Subscription(LiveClient manager, int id, String path, Map args) { this.manager = manager; queryId = id; this.path = path; this.args = args }
    synchronized void offerIfChanged(Update update) {
      if (closed) return
      String encoded = update.error == null ? JsonOutput.toJson(update.value) : null
      if (encoded != null && encoded == lastValue) return
      if (encoded != null) lastValue = encoded
      int size = (encoded ?: (update.error?.message ?: 'error')).getBytes(StandardCharsets.UTF_8).length + 256
      if (size > MAX_ENCODED_BYTES) { offer(new Update(null, new ConvexClient.ProtocolException('Live update exceeds queue byte budget'), update.logs)); return }
      while (!updates.isEmpty() && (updates.size() >= MAX_EVENTS || bytes + size > MAX_ENCODED_BYTES)) { bytes -= sizes.removeFirst(); updates.removeFirst() }
      updates.addLast(update); sizes.addLast(size); bytes += size; notifyAll()
    }
    synchronized void offer(Update update) { offerIfChanged(update) }
    synchronized Update nextUpdate(Duration timeout) {
      long deadline = System.nanoTime() + timeout.toNanos()
      while (updates.isEmpty() && !closed) { long remaining = deadline - System.nanoTime(); if (remaining <= 0) throw new TimeoutException('timed out waiting for Live update'); wait(Math.max(1L, TimeUnit.NANOSECONDS.toMillis(remaining))) }
      if (updates.isEmpty()) throw new IllegalStateException('Live subscription is closed')
      bytes -= sizes.removeFirst(); return updates.removeFirst()
    }
    Object next(Duration timeout) { Update update = nextUpdate(timeout); if (update.error != null) throw update.error; return update.value }
    synchronized void finish() { closed = true; updates.clear(); sizes.clear(); bytes = 0; notifyAll() }
    @Override void close() { manager?.unsubscribe(this) ?: finish() }
  }

  private static final class Listener implements WebSocket.Listener {
    private final LiveClient client; private final long generation
    Listener(LiveClient client, long generation) { this.client = client; this.generation = generation }
    @Override void onOpen(WebSocket ws) { ws.request(1) }
    @Override CompletionStage<?> onText(WebSocket ws, CharSequence data, boolean last) { client.received(generation, data, last); ws.request(1); CompletableFuture.completedFuture(null) }
    @Override CompletionStage<?> onClose(WebSocket ws, int code, String reason) { client.closedByPeer(generation, "ServerClosed:${code}"); CompletableFuture.completedFuture(null) }
    @Override void onError(WebSocket ws, Throwable error) { client.closedByPeer(generation, 'TransportError') }
  }
}
