package convex

import groovy.json.JsonOutput
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Callable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.ExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.Base64

/**
 * Native implementation of the pinned unversioned Convex sync profile.
 *
 * The owner executor is the only code allowed to change socket, reconnect, or
 * query-set state. JDK WebSocket callbacks place bounded immutable events into
 * an inbox; they never run protocol logic or touch that state themselves.
 */
final class LiveClient implements AutoCloseable {
  static final String INITIAL_TIMESTAMP = 'AAAAAAAAAAA='
  static final long INITIAL_BACKOFF_MS = 100L
  static final long MAX_BACKOFF_MS = 15_000L
  static final int MAX_INCOMING_EVENTS = 32
  static final int MAX_INCOMING_BYTES = 4 * 1024 * 1024
  static final int MAX_MESSAGE_BYTES = 2 * 1024 * 1024
  // This is deliberately a process-wide budget, not a per-subscription one.
  // It includes callback events waiting for the owner and delivery events
  // waiting for consumers, leaving generous JVM headroom below 128 MiB.
  static final int MAX_BUFFERED_EVENTS = 128
  static final int MAX_BUFFERED_BYTES = 12 * 1024 * 1024
  static final long MAX_UINT32 = 0xFFFFFFFFL

  private static final Duration HANDSHAKE_TIMEOUT = Duration.ofSeconds(5)
  private static final Duration WRITE_TIMEOUT = Duration.ofSeconds(2)
  private static final Duration OWNER_TIMEOUT = Duration.ofSeconds(6)

  private final URI endpoint
  private final HttpClient http
  private final ScheduledExecutorService owner
  private final LinkedHashMap<Long, Subscription> subscriptions = [:]
  private final DeliveryBudget deliveryBudget = new DeliveryBudget(
    MAX_BUFFERED_EVENTS,
    MAX_BUFFERED_BYTES,
  )
  private final IncomingBuffer incoming = new IncomingBuffer(deliveryBudget)

  private long nextId = 0
  private int querySetVersion = 0
  private int connectionCount = 0
  private long reconnectBackoffMs = INITIAL_BACKOFF_MS
  private String lastCloseReason = 'InitialConnect'
  private String maxObservedTimestamp
  private Map remoteVersion = zeroVersion()
  private WebSocket socket
  private CompletableFuture<WebSocket> pendingConnect
  private ScheduledFuture<?> handshakeDeadline
  private boolean reconnectScheduled = false
  private boolean closed = false
  private long socketGeneration = 0
  private final StringBuilder fragments = new StringBuilder()
  private int fragmentBytes = 0

  LiveClient(String deploymentUrl) {
    URI base = URI.create(deploymentUrl.replaceAll('/+$', ''))
    String scheme = base.scheme == 'https' ? 'wss' : base.scheme == 'http' ? 'ws' : null
    if (!scheme || !base.host || base.userInfo) {
      throw new IllegalArgumentException('Convex deployment URL must be http(s)')
    }

    endpoint = URI.create(
      "${scheme}://${base.rawAuthority ?: base.authority}${base.rawPath ?: ''}/api/sync",
    )
    owner = Executors.newSingleThreadScheduledExecutor { Runnable task ->
      Thread thread = new Thread(task, 'convex-groovy-live-owner')
      thread.daemon = true
      thread
    }
    http = HttpClient.newBuilder()
      .connectTimeout(HANDSHAKE_TIMEOUT)
      .build()
  }

  Subscription subscribe(String path, Map args) {
    if (!path?.trim()) {
      throw new IllegalArgumentException('Convex function path is required')
    }
    if (args == null) {
      throw new IllegalArgumentException('Convex arguments must be a named JSON object')
    }

    onOwner {
      ensureOpen()
      if (nextId > MAX_UINT32) {
        throw new IllegalStateException('Live query ID space is exhausted')
      }
      Subscription subscription = new Subscription(
        this,
        nextId++,
        path,
        deepCopy(args),
      )
      subscriptions[subscription.queryId] = subscription

      try {
        if (socket != null) {
          modify([addModification(subscription)])
        } else if (pendingConnect == null && !reconnectScheduled) {
          startConnect()
        }
        subscription
      } catch (Throwable error) {
        subscriptions.remove(subscription.queryId)
        subscription.finish()
        throw error
      }
    }
  }

  void unsubscribe(Subscription subscription) {
    onOwner {
      if (subscriptions.remove(subscription.queryId) == null) {
        return
      }

      subscription.finish()
      if (socket != null) {
        modify([[type: 'Remove', queryId: subscription.queryId]])
      }
      if (subscriptions.isEmpty()) {
        cancelReconnect()
      }
    }
  }

  /** Adapter-only hook. It acknowledges only after retirement and retry scheduling. */
  void debugDisconnect() {
    onOwner {
      ensureOpen()
      if (socket == null) {
        throw new IllegalStateException('Live WebSocket is not connected')
      }
      retireConnection('DebugDisconnect', true)
    }
  }

  private void startConnect() {
    ensureOpen()
    if (pendingConnect != null || socket != null || subscriptions.isEmpty()) {
      return
    }

    reconnectScheduled = false
    long generation = ++socketGeneration
    Listener listener = new Listener(this, generation)
    CompletableFuture<WebSocket> candidate = http.newWebSocketBuilder()
      .connectTimeout(HANDSHAKE_TIMEOUT)
      .header('Convex-Client', 'groovy-0.2.0')
      .buildAsync(endpoint, listener)
    pendingConnect = candidate

    handshakeDeadline = owner.schedule({
      if (pendingConnect == candidate) {
        candidate.cancel(true)
        pendingConnect = null
        connectionCount++
        lastCloseReason = 'HandshakeTimeout'
        scheduleReconnect()
      }
    } as Runnable, HANDSHAKE_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)

    candidate.whenComplete { WebSocket connected, Throwable error ->
      enqueueOwner {
        completeConnect(generation, candidate, connected, error)
      }
    }
  }

  private void completeConnect(
    long generation,
    CompletableFuture<WebSocket> candidate,
    WebSocket connected,
    Throwable error
  ) {
    if (pendingConnect != candidate) {
      connected?.abort()
      return
    }

    pendingConnect = null
    handshakeDeadline?.cancel(false)
    handshakeDeadline = null
    if (closed || generation != socketGeneration || subscriptions.isEmpty()) {
      connected?.abort()
      return
    }
    if (error != null) {
      connectionCount++
      lastCloseReason = 'HandshakeFailed:' + concise(error)
      scheduleReconnect()
      return
    }

    socket = connected
    querySetVersion = 0
    remoteVersion = zeroVersion()
    fragments.setLength(0)
    fragmentBytes = 0
    reconnectBackoffMs = INITIAL_BACKOFF_MS
    subscriptions.values().each { it.beginHydration() }

    try {
      Map connect = [
        type: 'Connect',
        sessionId: UUID.randomUUID().toString(),
        connectionCount: connectionCount,
        lastCloseReason: lastCloseReason,
        clientTs: 0,
      ]
      if (maxObservedTimestamp != null) {
        connect.maxObservedTimestamp = maxObservedTimestamp
      }
      send(connect)
      modify(subscriptions.values().collect { addModification(it) })
    } catch (Throwable sendFailure) {
      // A successful handshake followed by a failed initial write must not
      // leave a candidate socket that prevents the scheduled retry.
      retireConnection('InitialWriteFailed:' + concise(sendFailure), true)
    }
  }

  private Map addModification(Subscription subscription) {
    [
      type: 'Add',
      queryId: subscription.queryId,
      udfPath: subscription.path,
      args: [subscription.args],
    ]
  }

  private void modify(List<Map> modifications) {
    if (modifications.isEmpty()) {
      return
    }
    send([
      type: 'ModifyQuerySet',
      baseVersion: querySetVersion,
      newVersion: querySetVersion + 1,
      modifications: modifications,
    ])
    querySetVersion++
  }

  private void send(Map message) {
    WebSocket active = socket
    if (active == null) {
      throw new IllegalStateException('Live WebSocket is not connected')
    }

    try {
      active.sendText(JsonOutput.toJson(message), true)
        .get(WRITE_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
    } catch (Exception error) {
      // A completed send future is the only proof that the JDK accepted this
      // protocol write. Timeout or failure leaves the peer's query-set state
      // ambiguous, so this owner immediately aborts that generation and
      // reconnects from the subscriptions it still owns.
      retireConnection('WriteFailed:' + concise(error), true)
      throw new ConvexClient.TransportException('live write', error)
    }
  }

  private void acceptText(
    WebSocket webSocket,
    long generation,
    CharSequence data,
    boolean last
  ) {
    String immutable = data.toString()
    int bytes = immutable.getBytes(StandardCharsets.UTF_8).length
    if (!incoming.offer(new SocketEvent(generation, immutable, last, null, null), bytes)) {
      incoming.forceError(
        new SocketEvent(
          generation,
          '',
          true,
          new ConvexClient.TransportException(
            'live read',
            new IllegalStateException('Live callback inbox exceeded its byte budget'),
          ),
          null,
        ),
      )
    }
    scheduleDrain()
  }

  private void acceptFailure(long generation, Throwable error) {
    incoming.forceError(new SocketEvent(generation, '', true, error, null))
    scheduleDrain()
  }

  private void acceptPing(long generation, java.nio.ByteBuffer message) {
    java.nio.ByteBuffer copy = message.asReadOnlyBuffer()
    byte[] payload = new byte[copy.remaining()]
    copy.get(payload)
    if (!incoming.offer(new SocketEvent(generation, '', true, null, payload), payload.length + 64)) {
      incoming.forceError(
        new SocketEvent(
          generation,
          '',
          true,
          new ConvexClient.TransportException(
            'live read',
            new IllegalStateException('Live callback inbox exceeded its byte budget'),
          ),
          null,
        ),
      )
    }
    scheduleDrain()
  }

  private void scheduleDrain() {
    if (incoming.markDrainScheduled()) {
      enqueueOwner { drainIncoming() }
    }
  }

  private void drainIncoming() {
    SocketEvent event
    while ((event = incoming.poll()) != null) {
      if (closed || event.generation != socketGeneration) {
        continue
      }
      if (event.error != null) {
        if (socket == null) {
          // buildAsync owns handshake failures and counts the attempt exactly
          // once. Listener errors before a candidate becomes active are noise.
          continue
        }
        if (remoteVersion == zeroVersion()) {
          // The read side can detect the very same dead-on-arrival connection
          // that completeConnect's own write already guards against: an
          // abortive reset can land after a successful handshake but surface
          // here asynchronously instead of failing the initial Connect/Add
          // write synchronously. No subscriber has observed a Transition on
          // this connection yet, so retry silently instead of surfacing a
          // visible error, exactly like the initial write failure caught in
          // completeConnect.
          retireConnection('InitialWriteFailed:' + concise(event.error), true)
          continue
        }
        subscriptions.values().each {
          it.offerTransition(new Update(null, asTransport(event.error), []))
        }
        retireConnection('TransportError:' + concise(event.error), true)
        continue
      }
      if (socket == null) {
        continue
      }
      if (event.pong != null) {
        try {
          socket.sendPong(java.nio.ByteBuffer.wrap(event.pong))
            .get(WRITE_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
        } catch (Exception error) {
          subscriptions.values().each {
            it.offerTransition(new Update(null, asTransport(error), []))
          }
          retireConnection('TransportError:' + concise(error), true)
        }
        continue
      }

      fragmentBytes += event.encodedBytes()
      if (fragmentBytes > MAX_MESSAGE_BYTES) {
        protocolFailure('Live message exceeds 2 MiB')
        continue
      }
      fragments.append(event.text)
      if (!event.last) {
        continue
      }

      String frame = fragments.toString()
      fragments.setLength(0)
      fragmentBytes = 0
      try {
        Object parsed = ConvexClient.JSON.parseText(frame)
        if (!(parsed instanceof Map)) {
          throw new ConvexClient.ProtocolException('Live message must be a JSON object')
        }
        handle((Map) parsed)
      } catch (Throwable error) {
        protocolFailure(error.message ?: error.class.simpleName)
      }
    }

    incoming.finishDrain()
    if (!incoming.isEmpty()) {
      scheduleDrain()
    }
  }

  private void protocolFailure(String message) {
    ConvexClient.ProtocolException error = new ConvexClient.ProtocolException(message)
    subscriptions.values().each {
      it.offerTransition(new Update(null, error, []))
    }
    retireConnection('ProtocolError:' + message, true)
  }

  /** Validate the complete transition before changing any observable state. */
  private void handle(Map message) {
    String type = requireString(message, 'type')
    if (type in ['Ping', 'MutationResponse', 'ActionResponse']) {
      return
    }
    if (type in ['TransitionChunk', 'FatalError', 'AuthError']) {
      throw new ConvexClient.ProtocolException(
        "${type}: ${message.error ?: 'unsupported'}",
      )
    }
    if (type != 'Transition') {
      throw new ConvexClient.ProtocolException("unknown Live message: ${type}")
    }
    requireShape(
      message,
      ['type', 'startVersion', 'endVersion', 'modifications'] as Set,
      ['clientClockSkew', 'serverTs'] as Set,
      'Transition',
    )
    if (message.containsKey('clientClockSkew')) {
      requireLongInteger(message.clientClockSkew, 'clientClockSkew', false)
    }
    if (message.containsKey('serverTs')) {
      requireLongInteger(message.serverTs, 'serverTs', true)
    }

    Map startVersion = validateVersion(message.startVersion, 'startVersion')
    Map endVersion = validateVersion(message.endVersion, 'endVersion')
    if (startVersion != remoteVersion) {
      throw new ConvexClient.ProtocolException('Live transition version mismatch')
    }
    if (!(message.modifications instanceof List)) {
      throw new ConvexClient.ProtocolException('Transition modifications must be an array')
    }

    LinkedHashMap<Long, Update> planned = [:]
    Set<Long> seen = [] as Set
    message.modifications.each { Object candidate ->
      if (!(candidate instanceof Map)) {
        throw new ConvexClient.ProtocolException('Transition modification must be an object')
      }
      Map modification = (Map) candidate
      long queryId = requireQueryId(modification.queryId)
      if (!seen.add(queryId)) {
        throw new ConvexClient.ProtocolException('Transition repeated a queryId')
      }
      String modificationType = requireString(modification, 'type')

      if (modificationType == 'QueryUpdated') {
        requireShape(
          modification,
          ['type', 'queryId', 'value'] as Set,
          ['journal', 'logLines'] as Set,
          'QueryUpdated',
        )
        if (modification.containsKey('journal') &&
          modification.journal != null &&
          !(modification.journal instanceof String)) {
          throw new ConvexClient.ProtocolException(
            'QueryUpdated journal must be a string or null',
          )
        }
        if (!modification.containsKey('value')) {
          throw new ConvexClient.ProtocolException('QueryUpdated omitted value')
        }
        List<String> logs = requireLogs(modification)
        planned[queryId] = new Update(modification.value, null, logs)
      } else if (modificationType == 'QueryFailed') {
        requireShape(
          modification,
          ['type', 'queryId', 'errorMessage'] as Set,
          ['errorData', 'logLines'] as Set,
          'QueryFailed',
        )
        String errorMessage = requireString(modification, 'errorMessage')
        List<String> logs = requireLogs(modification)
        planned[queryId] = new Update(
          null,
          new ConvexClient.FunctionException(
            'query',
            errorMessage,
            modification.errorData,
            logs,
          ),
          logs,
        )
      } else if (modificationType == 'QueryRemoved') {
        requireShape(
          modification,
          ['type', 'queryId'] as Set,
          ['logLines'] as Set,
          'QueryRemoved',
        )
        requireLogs(modification)
      } else {
        throw new ConvexClient.ProtocolException(
          "unknown Transition modification: ${modificationType}",
        )
      }
    }

    // Commit only after every version and modification has passed validation.
    remoteVersion = deepCopy(endVersion)
    maxObservedTimestamp = maxTimestamp(maxObservedTimestamp, endVersion.ts)
    reconnectBackoffMs = INITIAL_BACKOFF_MS
    planned.each { Long queryId, Update update ->
      subscriptions[queryId]?.offerTransition(update)
    }
  }

  private static Map validateVersion(Object candidate, String field) {
    if (!(candidate instanceof Map)) {
      throw new ConvexClient.ProtocolException("${field} must be an object")
    }
    Map version = (Map) candidate
    if (version.keySet() != ['querySet', 'identity', 'ts'] as Set) {
      throw new ConvexClient.ProtocolException("${field} has an invalid shape")
    }
    int querySet = requireNonnegativeInteger(version.querySet, "${field}.querySet")
    int identity = requireNonnegativeInteger(version.identity, "${field}.identity")
    if (!(version.ts instanceof String) || !version.ts) {
      throw new ConvexClient.ProtocolException("${field}.ts must be a non-empty string")
    }
    [querySet: querySet, identity: identity, ts: version.ts]
  }

  private static long requireQueryId(Object candidate) {
    if (!(candidate instanceof Number)) {
      throw new ConvexClient.ProtocolException('queryId must be an integer')
    }
    BigDecimal decimal
    try {
      decimal = new BigDecimal(candidate.toString())
    } catch (NumberFormatException error) {
      throw new ConvexClient.ProtocolException('queryId must be an integer')
    }
    if (decimal.stripTrailingZeros().scale() > 0 ||
      decimal < 0 ||
      decimal > MAX_UINT32) {
      throw new ConvexClient.ProtocolException(
        'queryId must be an in-range uint32 integer',
      )
    }
    decimal.longValueExact()
  }

  private static int requireNonnegativeInteger(Object candidate, String field) {
    if (!(candidate instanceof Number)) {
      throw new ConvexClient.ProtocolException("${field} must be an integer")
    }
    BigDecimal decimal
    try {
      decimal = new BigDecimal(candidate.toString())
    } catch (NumberFormatException error) {
      throw new ConvexClient.ProtocolException("${field} must be an integer")
    }
    if (decimal.stripTrailingZeros().scale() > 0 ||
      decimal < 0 ||
      decimal > Integer.MAX_VALUE) {
      throw new ConvexClient.ProtocolException("${field} must be an in-range integer")
    }
    decimal.intValueExact()
  }

  private static long requireLongInteger(
    Object candidate,
    String field,
    boolean nonnegative
  ) {
    if (!(candidate instanceof Number)) {
      throw new ConvexClient.ProtocolException("${field} must be an integer")
    }
    BigDecimal decimal
    try {
      decimal = new BigDecimal(candidate.toString())
    } catch (NumberFormatException error) {
      throw new ConvexClient.ProtocolException("${field} must be an integer")
    }
    if (decimal.stripTrailingZeros().scale() > 0 ||
      (nonnegative && decimal < 0) ||
      decimal < Long.MIN_VALUE ||
      decimal > Long.MAX_VALUE) {
      throw new ConvexClient.ProtocolException("${field} must be an in-range integer")
    }
    decimal.longValueExact()
  }

  /** Compare actual sync timestamps as unsigned little-endian byte numbers. */
  static String maxTimestamp(String current, String candidate) {
    if (current == null) {
      return candidate
    }
    try {
      byte[] left = Base64.decoder.decode(current)
      byte[] right = Base64.decoder.decode(candidate)
      if (left.length != right.length) {
        return candidate
      }
      for (int index = left.length - 1; index >= 0; index--) {
        int leftByte = Byte.toUnsignedInt(left[index])
        int rightByte = Byte.toUnsignedInt(right[index])
        if (rightByte != leftByte) {
          return rightByte > leftByte ? candidate : current
        }
      }
      return current
    } catch (IllegalArgumentException ignored) {
      // Local fixtures use readable labels instead of protocol timestamps.
      // Preserve their latest transition while real base64 timestamps use
      // numeric little-endian ordering above.
      return candidate
    }
  }

  private static String requireString(Map source, String field) {
    Object value = source[field]
    if (!(value instanceof String) || !value) {
      throw new ConvexClient.ProtocolException("${field} must be a non-empty string")
    }
    value
  }

  private static List<String> requireLogs(Map modification) {
    if (!modification.containsKey('logLines')) {
      return []
    }
    if (!(modification.logLines instanceof List) ||
      !modification.logLines.every { it instanceof String }) {
      throw new ConvexClient.ProtocolException('logLines must be an array of strings')
    }
    modification.logLines.collect { it.toString() }.asImmutable()
  }

  private static void requireShape(
    Map source,
    Set<String> required,
    Set<String> optional,
    String label
  ) {
    Set<String> keys = source.keySet() as Set<String>
    if (!keys.containsAll(required) || !(keys - required - optional).isEmpty()) {
      throw new ConvexClient.ProtocolException("${label} has an invalid shape")
    }
  }

  private void peerClosed(long generation, int code, String reason) {
    acceptFailure(
      generation,
      new ConvexClient.TransportException(
        'live close',
        new IOException("ServerClosed:${code}:${reason ?: ''}"),
      ),
    )
  }

  private void retireConnection(String reason, boolean reconnect) {
    WebSocket previous = socket
    socket = null
    // Invalidate late callbacks before aborting. JDK may report onClose and
    // onError after abort; neither may affect a replacement connection.
    socketGeneration++
    pendingConnect?.cancel(true)
    pendingConnect = null
    handshakeDeadline?.cancel(false)
    handshakeDeadline = null
    if (previous != null) {
      previous.abort()
      connectionCount++
    }

    lastCloseReason = reason
    querySetVersion = 0
    remoteVersion = zeroVersion()
    fragments.setLength(0)
    fragmentBytes = 0
    incoming.clear()
    if (reconnect && !subscriptions.isEmpty()) {
      scheduleReconnect()
    }
  }

  private void scheduleReconnect() {
    if (closed || reconnectScheduled || subscriptions.isEmpty()) {
      return
    }
    long delay = reconnectBackoffMs
    reconnectBackoffMs = Math.min(MAX_BACKOFF_MS, reconnectBackoffMs * 2L)
    reconnectScheduled = true
    owner.schedule({
      reconnectScheduled = false
      if (!closed && socket == null && pendingConnect == null && !subscriptions.isEmpty()) {
        startConnect()
      }
    } as Runnable, delay, TimeUnit.MILLISECONDS)
  }

  private void cancelReconnect() {
    reconnectScheduled = false
    // Do not bump socketGeneration here. unsubscribe() calls this once the
    // last subscription is removed, but a live socket can still be
    // connected at that moment; startConnect deliberately leaves it open so
    // the next subscribe reuses it instead of forcing a fresh handshake.
    // Every Listener callback keeps tagging that connection's events with
    // the generation captured when it was built, so advancing the counter
    // here would desync it from a connection nobody retired: drainIncoming
    // would then discard that socket's Transitions forever, including the
    // resubscribe's own initial hydration, with no error and no retry.
    // Cancelling an in-flight connect attempt does not need the counter
    // either: nulling pendingConnect below already makes completeConnect's
    // `pendingConnect != candidate` check reject that stale attempt.
    pendingConnect?.cancel(true)
    pendingConnect = null
    handshakeDeadline?.cancel(false)
    handshakeDeadline = null
  }

  int bufferedDeliveryEvents() {
    deliveryBudget.eventCount()
  }

  int bufferedDeliveryBytes() {
    deliveryBudget.byteCount()
  }

  private static Map zeroVersion() {
    [querySet: 0, identity: 0, ts: INITIAL_TIMESTAMP]
  }

  private static Map deepCopy(Map value) {
    (Map) ConvexClient.JSON.parseText(JsonOutput.toJson(value))
  }

  private static Throwable asTransport(Throwable error) {
    error instanceof ConvexClient.TransportException
      ? error
      : new ConvexClient.TransportException('live read', error)
  }

  private static String concise(Throwable error) {
    Throwable actual = error instanceof ExecutionException && error.cause
      ? error.cause
      : error
    actual.message ?: actual.class.simpleName
  }

  private void ensureOpen() {
    if (closed) {
      throw new IllegalStateException('Convex Live client is closed')
    }
  }

  private void enqueueOwner(Closure<?> action) {
    try {
      owner.execute { action.call() }
    } catch (java.util.concurrent.RejectedExecutionException ignored) {
      // Shutdown invalidates late listener callbacks.
    }
  }

  private <T> T onOwner(Closure<T> action) {
    if (Thread.currentThread().name == 'convex-groovy-live-owner') {
      return action.call()
    }
    try {
      owner.submit({ action.call() } as Callable<T>)
        .get(OWNER_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
    } catch (ExecutionException error) {
      Throwable cause = error.cause
      if (cause instanceof RuntimeException) {
        throw (RuntimeException) cause
      }
      throw new RuntimeException(cause)
    }
  }

  @Override
  void close() {
    try {
      onOwner {
        if (closed) {
          return
        }
        closed = true
        reconnectScheduled = false
        socketGeneration++
        pendingConnect?.cancel(true)
        pendingConnect = null
        handshakeDeadline?.cancel(false)
        handshakeDeadline = null

        WebSocket previous = socket
        socket = null
        if (previous != null) {
          try {
            previous.sendClose(WebSocket.NORMAL_CLOSURE, 'closed')
              .get(WRITE_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
          } catch (Exception ignored) {
            // The bounded abort below completes shutdown for an idle peer too.
          } finally {
            previous.abort()
          }
        }
        subscriptions.values().each { it.finish() }
        subscriptions.clear()
        incoming.clear()
      }
    } finally {
      owner.shutdownNow()
      owner.awaitTermination(2, TimeUnit.SECONDS)
    }
  }

  static record Update(Object value, Throwable error, List<String> logs) {}

  static final class Subscription implements AutoCloseable {
    static final int MAX_EVENTS = 16
    static final int MAX_ENCODED_BYTES = 2 * 1024 * 1024

    private final LiveClient manager
    final long queryId
    final String path
    final Map args
    private final ArrayDeque<Update> updates = new ArrayDeque<>()
    private final ArrayDeque<Integer> sizes = new ArrayDeque<>()
    private final DeliveryBudget budget
    private int bytes = 0
    private boolean closed = false
    private boolean hydrationPending = false
    private String lastValue

    Subscription(LiveClient manager, Number queryId, String path, Map args) {
      this.manager = manager
      this.queryId = queryId.longValue()
      this.path = path
      this.args = args
      budget = manager?.deliveryBudget ?: new DeliveryBudget(
        MAX_EVENTS,
        MAX_ENCODED_BYTES,
      )
    }

    synchronized void beginHydration() {
      hydrationPending = lastValue != null
    }

    synchronized void offerTransition(Update update) {
      if (closed) {
        return
      }
      if (update.error != null) {
        // A valid recovery equal to the pre-error value must still be delivered.
        lastValue = null
        hydrationPending = false
        enqueue(update)
        return
      }

      String encoded = JsonOutput.toJson(update.value)
      if (hydrationPending && encoded == lastValue) {
        hydrationPending = false
        return
      }
      hydrationPending = false
      lastValue = encoded
      enqueue(update)
    }

    synchronized void offer(Update update) {
      offerTransition(update)
    }

    private void enqueue(Update update) {
      String encoded = update.error == null
        ? JsonOutput.toJson(update.value)
        : (update.error.message ?: 'error')
      int size = encoded.getBytes(StandardCharsets.UTF_8).length + 256
      if (size > MAX_ENCODED_BYTES) {
        Update replacement = new Update(
          null,
          new ConvexClient.ProtocolException('Live update exceeds queue byte budget'),
          update.logs,
        )
        enqueueSized(replacement, 512)
        return
      }
      enqueueSized(update, size)
    }

    private void enqueueSized(Update update, int size) {
      while (!updates.isEmpty() &&
        (updates.size() >= MAX_EVENTS || bytes + size > MAX_ENCODED_BYTES)) {
        int removed = sizes.removeFirst()
        bytes -= removed
        updates.removeFirst()
        budget.release(removed)
      }
      if (!budget.reserve(size)) {
        // Never let many individually legal subscription queues accumulate
        // into an unbounded process. The live owner keeps running and the
        // consumer sees a precise failure once it drains its prior values.
        Update overflow = new Update(
          null,
          new ConvexClient.ProtocolException('Live delivery budget exceeded'),
          update.logs,
        )
        int overflowSize = 512
        boolean reservedOverflow = budget.reserve(overflowSize)
        while (!updates.isEmpty() && !reservedOverflow) {
          int removed = sizes.removeFirst()
          bytes -= removed
          updates.removeFirst()
          budget.release(removed)
          reservedOverflow = budget.reserve(overflowSize)
        }
        if (!reservedOverflow) {
          return
        }
        updates.addLast(overflow)
        sizes.addLast(overflowSize)
        bytes += overflowSize
        notifyAll()
        return
      }
      updates.addLast(update)
      sizes.addLast(size)
      bytes += size
      notifyAll()
    }

    synchronized Update nextUpdate(Duration timeout) {
      long deadline = System.nanoTime() + timeout.toNanos()
      while (updates.isEmpty() && !closed) {
        long remaining = deadline - System.nanoTime()
        if (remaining <= 0) {
          throw new TimeoutException('timed out waiting for Live update')
        }
        wait(Math.max(1L, TimeUnit.NANOSECONDS.toMillis(remaining)))
      }
      if (updates.isEmpty()) {
        throw new IllegalStateException('Live subscription is closed')
      }
      int removed = sizes.removeFirst()
      bytes -= removed
      Update update = updates.removeFirst()
      budget.release(removed)
      update
    }

    Object next(Duration timeout) {
      Update update = nextUpdate(timeout)
      if (update.error != null) {
        throw update.error
      }
      update.value
    }

    synchronized void finish() {
      closed = true
      sizes.each { budget.release(it) }
      updates.clear()
      sizes.clear()
      bytes = 0
      notifyAll()
    }

    @Override
    void close() {
      manager?.unsubscribe(this) ?: finish()
    }
  }

  private static record SocketEvent(
    long generation,
    String text,
    boolean last,
    Throwable error,
    byte[] pong
  ) {
    int encodedBytes() {
      pong == null
        ? text.getBytes(StandardCharsets.UTF_8).length
        : pong.length + 64
    }
  }

  static final class DeliveryBudget {
    private final int maxEvents
    private final int maxBytes
    private int events = 0
    private int bytes = 0

    DeliveryBudget(int maxEvents, int maxBytes) {
      this.maxEvents = maxEvents
      this.maxBytes = maxBytes
    }

    synchronized boolean reserve(int size) {
      if (size < 0 || events >= maxEvents || bytes + size > maxBytes) {
        return false
      }
      events++
      bytes += size
      true
    }

    synchronized void release(int size) {
      events--
      bytes -= size
      assert events >= 0 && bytes >= 0: 'delivery budget accounting underflow'
    }

    synchronized int eventCount() { events }

    synchronized int byteCount() { bytes }
  }

  private static final class IncomingBuffer {
    private final ArrayBlockingQueue<SocketEvent> events =
      new ArrayBlockingQueue<>(MAX_INCOMING_EVENTS)
    private final AtomicBoolean drainScheduled = new AtomicBoolean(false)
    private final DeliveryBudget budget
    private int bytes = 0

    IncomingBuffer(DeliveryBudget budget) {
      this.budget = budget
    }

    synchronized boolean offer(SocketEvent event, int encodedBytes) {
      int accounted = encodedBytes + 256
      if (accounted > MAX_INCOMING_BYTES || bytes + accounted > MAX_INCOMING_BYTES ||
        !budget.reserve(accounted)) {
        return false
      }
      if (!events.offer(event)) {
        budget.release(accounted)
        return false
      }
      bytes += accounted
      true
    }

    synchronized void forceError(SocketEvent event) {
      events.each { budget.release(it.encodedBytes() + 256) }
      events.clear()
      bytes = 0
      if (budget.reserve(event.encodedBytes() + 256)) {
        events.offer(event)
        bytes = event.encodedBytes() + 256
      }
    }

    synchronized SocketEvent poll() {
      SocketEvent event = events.poll()
      if (event != null) {
        int accounted = event.encodedBytes() + 256
        bytes -= accounted
        budget.release(accounted)
      }
      event
    }

    boolean markDrainScheduled() {
      drainScheduled.compareAndSet(false, true)
    }

    void finishDrain() {
      drainScheduled.set(false)
    }

    boolean isEmpty() {
      events.isEmpty()
    }

    synchronized void clear() {
      events.each { budget.release(it.encodedBytes() + 256) }
      events.clear()
      bytes = 0
    }
  }

  private static final class Listener implements WebSocket.Listener {
    private final LiveClient client
    private final long generation

    Listener(LiveClient client, long generation) {
      this.client = client
      this.generation = generation
    }

    @Override
    void onOpen(WebSocket webSocket) {
      webSocket.request(1)
    }

    @Override
    CompletionStage<?> onText(
      WebSocket webSocket,
      CharSequence data,
      boolean last
    ) {
      client.acceptText(webSocket, generation, data, last)
      webSocket.request(1)
      CompletableFuture.completedFuture(null)
    }

    @Override
    CompletionStage<?> onPing(WebSocket webSocket, java.nio.ByteBuffer message) {
      client.acceptPing(generation, message)
      webSocket.request(1)
      CompletableFuture.completedFuture(null)
    }

    @Override
    CompletionStage<?> onPong(WebSocket webSocket, java.nio.ByteBuffer message) {
      webSocket.request(1)
      CompletableFuture.completedFuture(null)
    }

    @Override
    CompletionStage<?> onClose(
      WebSocket webSocket,
      int statusCode,
      String reason
    ) {
      client.peerClosed(generation, statusCode, reason)
      CompletableFuture.completedFuture(null)
    }

    @Override
    void onError(WebSocket webSocket, Throwable error) {
      client.acceptFailure(generation, error)
    }
  }
}
