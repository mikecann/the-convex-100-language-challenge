package convex.tests

import convex.ConvexClient
import convex.LiveClient
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real-socket coverage for Live ordering, recovery, reconnect, and deadlines. */
final class LiveClientTests {
  static void run() {
    addInitialExternalAndRemove()
    queryFailureRecoversToSameValue()
    fragmentedUtf8AndControlFrame()
    malformedTransitionIsTransactional()
    reconnectsFiveTimesWithMetadataAndDedupe()
    failedHandshakeBackoffDoubles()
    peerCloseReasonCarriesToReconnect()
    maxObservedTimestampUsesLittleEndianNumericOrder()
    closeIsBoundedDuringStalledHandshake()
    closeIsBoundedWhilePeerContinuouslySends()
    globalDeliveryBudgetCaps130StoppedSubscriptions()
  }

  private static void addInitialExternalAndRemove() {
    ServerSocket listener = new ServerSocket(0)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-add-remove-fixture') {
      try {
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
        Map connect = peer.readJson()
        assert connect.type == 'Connect'
        Map add = peer.readJson()
        assert add.modifications*.type == ['Add']
        int queryId = add.modifications[0].queryId
        peer.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'initial'),
          [updated(queryId, 0)],
        ))
        peer.sendJson(transition(
          version(1, 'initial'),
          version(1, 'external'),
          [updated(queryId, 1)],
        ))
        Map remove = peer.readJson()
        assert remove.modifications == [[type: 'Remove', queryId: queryId]]
        peer.close()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'add'])
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    assert subscription.next(Duration.ofSeconds(3)).count == 1
    subscription.close()
    live.close()
    finish(listener, server, failure)
  }

  private static void queryFailureRecoversToSameValue() {
    ServerSocket listener = new ServerSocket(0)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-query-failed-fixture') {
      try {
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
        peer.readJson()
        Map add = peer.readJson()
        int queryId = add.modifications[0].queryId
        peer.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'healthy-0'),
          [updated(queryId, 0)],
        ))
        peer.sendJson(transition(
          version(1, 'healthy-0'),
          version(1, 'failed'),
          [[
            type: 'QueryFailed',
            queryId: queryId,
            errorMessage: 'temporary',
            errorData: [code: 'TEMPORARY'],
            logLines: ['failed'],
          ]],
        ))
        peer.sendJson(transition(
          version(1, 'failed'),
          version(1, 'recovered'),
          [updated(queryId, 0)],
        ))
        peer.awaitDisconnect()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'recovery'])
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    LiveClient.Update failed = subscription.nextUpdate(Duration.ofSeconds(3))
    assert failed.error() instanceof ConvexClient.FunctionException
    assert failed.error().data.code == 'TEMPORARY'
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    live.close()
    finish(listener, server, failure)
  }

  private static void fragmentedUtf8AndControlFrame() {
    ServerSocket listener = new ServerSocket(0)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-fragment-fixture') {
      try {
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
        peer.readJson()
        Map add = peer.readJson()
        int queryId = add.modifications[0].queryId
        peer.sendFragmentedJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'fragmented'),
          [[
            type: 'QueryUpdated',
            queryId: queryId,
            value: [count: 0, label: 'snowman ☃ and rocket 🚀'],
            logLines: ['unicode ✓'],
          ]],
        ))
        WebSocketFixture.Frame pong = peer.readFrame()
        assert pong.opcode() == 10
        assert new String(pong.payload(), java.nio.charset.StandardCharsets.UTF_8) == 'ok'
        peer.awaitDisconnect()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'utf8'])
    Map value
    try {
      value = (Map) subscription.next(Duration.ofSeconds(3))
    } catch (Throwable error) {
      live.close()
      finish(listener, server, failure)
      throw error
    }
    assert value.label == 'snowman ☃ and rocket 🚀'
    live.close()
    finish(listener, server, failure)
  }

  private static void malformedTransitionIsTransactional() {
    ServerSocket listener = new ServerSocket(0)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-malformed-fixture') {
      try {
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
        peer.readJson()
        Map add = peer.readJson()
        int queryId = add.modifications[0].queryId
        peer.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'initial'),
          [updated(queryId, 0)],
        ))
        peer.sendJson(transition(
          version(1, 'initial'),
          version(1, 'malformed'),
          [
            updated(queryId, 1),
            [
              type: 'QueryUpdated',
              queryId: queryId + 1,
              value: [count: 2],
              logLines: [],
              unexpected: true,
            ],
          ],
        ))
        peer.awaitDisconnect()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'bad'])
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    LiveClient.Update error = subscription.nextUpdate(Duration.ofSeconds(3))
    assert error.error() instanceof ConvexClient.ProtocolException
    try {
      subscription.next(Duration.ofMillis(30))
      assert false: 'published the valid prefix of a malformed transition'
    } catch (java.util.concurrent.TimeoutException expected) {
      // No partial value crossed the transactional validation boundary.
    }
    live.close()
    finish(listener, server, failure)
  }

  private static void reconnectsFiveTimesWithMetadataAndDedupe() {
    ServerSocket listener = new ServerSocket(0)
    ArrayBlockingQueue<Map> records = new ArrayBlockingQueue<>(6)
    CountDownLatch finalUpdate = new CountDownLatch(1)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-five-reconnect-fixture') {
      try {
        for (int connection = 0; connection <= 5; connection++) {
          WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
          Map connect = peer.readJson()
          Map add = peer.readJson()
          int queryId = add.modifications[0].queryId
          String timestamp = 'hydrated-0'
          peer.sendJson(transition(
            version(0, 'AAAAAAAAAAA='),
            version(1, timestamp),
            [updated(queryId, 0)],
          ))
          records.put([
            index: connection,
            connect: connect,
            add: add,
          ])
          if (connection < 5) {
            peer.awaitDisconnect()
          } else {
            assert finalUpdate.await(3, TimeUnit.SECONDS)
            peer.sendJson(transition(
              version(1, timestamp),
              version(1, 'external-1'),
              [updated(queryId, 1)],
            ))
            peer.awaitDisconnect()
          }
        }
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'reconnect'])
    Map initialRecord = records.poll(3, TimeUnit.SECONDS)
    assert initialRecord.connect.connectionCount == 0
    assert subscription.next(Duration.ofSeconds(3)).count == 0

    for (int connection = 1; connection <= 5; connection++) {
      live.debugDisconnect()
      Map record = records.poll(3, TimeUnit.SECONDS)
      assert record.index == connection
      assert record.connect.connectionCount == connection
      assert record.connect.lastCloseReason == 'DebugDisconnect'
      assert record.connect.maxObservedTimestamp == 'hydrated-0'
      assert record.add.modifications*.type == ['Add']
    }
    finalUpdate.countDown()
    assert subscription.next(Duration.ofSeconds(3)).count == 1
    live.close()
    finish(listener, server, failure)
  }

  private static void failedHandshakeBackoffDoubles() {
    ServerSocket listener = new ServerSocket(0)
    List<Long> acceptedAt = Collections.synchronizedList([])
    ArrayBlockingQueue<Map> connected = new ArrayBlockingQueue<>(1)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-backoff-fixture') {
      try {
        for (int attempt = 0; attempt < 2; attempt++) {
          Socket rejected = listener.accept()
          acceptedAt << System.nanoTime()
          WebSocketFixture.readHeaders(rejected.inputStream)
          rejected.outputStream.write((
            'HTTP/1.1 503 Service Unavailable\r\n' +
            'Content-Length: 0\r\nConnection: close\r\n\r\n'
          ).getBytes(java.nio.charset.StandardCharsets.US_ASCII))
          rejected.outputStream.flush()
          rejected.close()
        }
        Socket accepted = listener.accept()
        acceptedAt << System.nanoTime()
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(accepted)
        Map connect = peer.readJson()
        Map add = peer.readJson()
        connected.put(connect)
        peer.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'backoff-success'),
          [updated(add.modifications[0].queryId, 0)],
        ))
        peer.awaitDisconnect()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'backoff'])
    assert subscription.next(Duration.ofSeconds(5)).count == 0
    Map connect = connected.poll(1, TimeUnit.SECONDS)
    assert connect.connectionCount == 2
    assert connect.lastCloseReason.startsWith('HandshakeFailed:')
    long firstGap = TimeUnit.NANOSECONDS.toMillis(acceptedAt[1] - acceptedAt[0])
    long secondGap = TimeUnit.NANOSECONDS.toMillis(acceptedAt[2] - acceptedAt[1])
    assert firstGap >= 75: "first retry was too early: ${firstGap}ms"
    assert secondGap >= 175: "second retry did not double: ${secondGap}ms"
    live.close()
    finish(listener, server, failure)
  }

  private static void peerCloseReasonCarriesToReconnect() {
    ServerSocket listener = new ServerSocket(0)
    ArrayBlockingQueue<Map> reconnect = new ArrayBlockingQueue<>(1)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-close-reason-fixture') {
      try {
        WebSocketFixture.Peer first = WebSocketFixture.handshake(listener.accept())
        first.readJson()
        Map firstAdd = first.readJson()
        int queryId = firstAdd.modifications[0].queryId
        first.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'before-close'),
          [updated(queryId, 0)],
        ))
        first.sendClose(1001, 'maintenance')
        first.close()

        WebSocketFixture.Peer second = WebSocketFixture.handshake(listener.accept())
        Map connect = second.readJson()
        Map add = second.readJson()
        reconnect.put(connect)
        second.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'after-close'),
          [updated(add.modifications[0].queryId, 1)],
        ))
        second.awaitDisconnect()
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'reason'])
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    LiveClient.Update closeError = subscription.nextUpdate(Duration.ofSeconds(3))
    assert closeError.error() instanceof ConvexClient.TransportException
    assert subscription.next(Duration.ofSeconds(3)).count == 1
    Map connect = reconnect.poll(1, TimeUnit.SECONDS)
    assert connect.lastCloseReason.contains('ServerClosed:1001:maintenance')
    live.close()
    finish(listener, server, failure)
  }

  private static void maxObservedTimestampUsesLittleEndianNumericOrder() {
    byte[] one = [1, 0, 0, 0, 0, 0, 0, 0] as byte[]
    byte[] twoHundredFiftySix = [0, 1, 0, 0, 0, 0, 0, 0] as byte[]
    String smaller = Base64.encoder.encodeToString(one)
    String larger = Base64.encoder.encodeToString(twoHundredFiftySix)

    assert LiveClient.maxTimestamp(smaller, larger) == larger
    assert LiveClient.maxTimestamp(larger, smaller) == larger
  }

  private static void closeIsBoundedDuringStalledHandshake() {
    ServerSocket listener = new ServerSocket(0)
    CountDownLatch accepted = new CountDownLatch(1)
    Thread server = Thread.start('live-stalled-handshake-fixture') {
      Socket socket = listener.accept()
      accepted.countDown()
      try {
        Thread.sleep(2_000)
      } finally {
        socket.close()
      }
    }

    LiveClient live = new LiveClient(url(listener))
    live.subscribe('demo:state', [room: 'stall'])
    assert accepted.await(2, TimeUnit.SECONDS)
    long started = System.nanoTime()
    live.close()
    long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
    assert elapsed < 1_500: "close waited on a stalled handshake for ${elapsed}ms"
    listener.close()
    server.join(3_000)
  }

  private static void closeIsBoundedWhilePeerContinuouslySends() {
    ServerSocket listener = new ServerSocket(0)
    Throwable[] failure = new Throwable[1]
    Thread server = Thread.start('live-continuous-peer-fixture') {
      try {
        WebSocketFixture.Peer peer = WebSocketFixture.handshake(listener.accept())
        peer.readJson()
        Map add = peer.readJson()
        peer.sendJson(transition(
          version(0, 'AAAAAAAAAAA='),
          version(1, 'continuous'),
          [updated(add.modifications[0].queryId, 0)],
        ))
        while (!peer.socket.closed) {
          peer.sendJson([type: 'Ping'])
        }
      } catch (IOException expected) {
        // Client close ends the continuously sending fixture.
      } catch (Throwable error) {
        failure[0] = error
      }
    }

    LiveClient live = new LiveClient(url(listener))
    LiveClient.Subscription subscription = live.subscribe('demo:state', [room: 'busy'])
    assert subscription.next(Duration.ofSeconds(3)).count == 0
    long started = System.nanoTime()
    live.close()
    long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
    assert elapsed < 3_000: "close was unbounded under continuous input: ${elapsed}ms"
    finish(listener, server, failure)
  }

  private static void globalDeliveryBudgetCaps130StoppedSubscriptions() {
    LiveClient live = new LiveClient('http://127.0.0.1:1')
    List<LiveClient.Subscription> subscriptions = (0..<130).collect { int id ->
      new LiveClient.Subscription(live, id, 'demo:state', [room: "pressure-${id}"])
    }
    // Each update is legal on its own. A stopped consumer across 130 queues
    // must still remain under one manager-wide byte and count envelope.
    String nearLimit = 'x' * (96 * 1024 - 1024)
    subscriptions.each {
      it.offer(new LiveClient.Update([payload: nearLimit], null, []))
    }
    assert live.bufferedDeliveryEvents() <= LiveClient.MAX_BUFFERED_EVENTS
    assert live.bufferedDeliveryBytes() <= LiveClient.MAX_BUFFERED_BYTES
    assert live.bufferedDeliveryBytes() < 16 * 1024 * 1024

    subscriptions.each { it.finish() }
    assert live.bufferedDeliveryEvents() == 0
    assert live.bufferedDeliveryBytes() == 0
    live.close()
  }

  private static Map version(int querySet, String timestamp) {
    [querySet: querySet, identity: 0, ts: timestamp]
  }

  private static Map updated(int queryId, int count) {
    [
      type: 'QueryUpdated',
      queryId: queryId,
      value: [count: count],
      logLines: [],
    ]
  }

  private static Map transition(Map start, Map end, List<Map> modifications) {
    [
      type: 'Transition',
      startVersion: start,
      endVersion: end,
      modifications: modifications,
    ]
  }

  private static String url(ServerSocket listener) {
    "http://127.0.0.1:${listener.localPort}"
  }

  private static void finish(
    ServerSocket listener,
    Thread server,
    Throwable[] failure
  ) {
    listener.close()
    server.join(5_000)
    assert !server.alive: 'WebSocket fixture did not finish'
    if (failure[0] != null) {
      throw new AssertionError('WebSocket fixture failed', failure[0])
    }
  }
}
