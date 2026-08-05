package convex.adapter

import convex.ConvexClient
import convex.LiveClient
import groovy.json.JsonOutput
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Test-only NDJSON adapter protocol v1 endpoint. */
final class Adapter {
  static final int MAX_NDJSON_BYTES = 1024 * 1024
  /** Deterministic adapter-test barrier; never exposed through the protocol. */
  static volatile Closure<?> relayPauseHook

  static void main(String[] args) {
    String listen = System.getenv('ADAPTER_LISTEN')
    if (!listen?.trim()) {
      run(System.in, System.out, System.getenv('CONVEX_URL'))
      return
    }

    ServerSocket server = bind(listen)
    try {
      Socket controller = server.accept()
      controller.tcpNoDelay = true
      try {
        run(
          controller.inputStream,
          controller.outputStream,
          System.getenv('CONVEX_URL'),
        )
      } finally {
        controller.close()
      }
    } finally {
      server.close()
    }
  }

  static ServerSocket bind(String address) {
    int separator = address.lastIndexOf(':')
    if (separator < 1) {
      throw new IllegalArgumentException('ADAPTER_LISTEN must be host:port')
    }
    String host = address.substring(0, separator)
    int port = Integer.parseInt(address.substring(separator + 1))
    ServerSocket server = new ServerSocket()
    server.bind(new InetSocketAddress(InetAddress.getByName(host), port))
    server
  }

  static void run(InputStream input, OutputStream stream, String deploymentUrl) {
    Framer framer = new Framer(input)
    Output output = new Output(stream)
    Map<String, Relay> relays = [:]
    Object relayLock = new Object()
    ConvexClient client
    LiveClient live

    try {
      boolean running = true
      while (running && output.healthy()) {
        Frame frame = framer.next()
        if (frame.eof()) {
          break
        }
        if (frame.error() != null) {
          if (!output.write(failure('', '', frame.error()))) {
            break
          }
          if (frame.terminal()) {
            break
          }
          continue
        }

        Map command
        try {
          Object decoded = ConvexClient.JSON.parseText(frame.text())
          if (!(decoded instanceof Map)) {
            throw new ConvexClient.ProtocolException(
              'adapter command must be a JSON object',
            )
          }
          command = validateCommand((Map) decoded)
        } catch (Throwable error) {
          if (!output.write(failure('', '', asProtocol(error)))) {
            break
          }
          continue
        }

        String id = command.id
        String operation = command.op
        try {
          if (operation == 'hello') {
            requireOutput(output.write([
              type: 'ready',
              id: id,
              protocolVersion: 1,
              language: 'groovy',
              implementation: 'native-groovy-jdk-httpclient',
              runtime: System.getProperty('java.runtime.version'),
            ]))
            continue
          }

          if (operation == 'close') {
            synchronized (relayLock) {
              relays.clear()
              live?.close()
              live = null
              client?.close()
              client = null
              requireOutput(output.write([type: 'closed', id: id]))
            }
            running = false
            continue
          }

          if (!deploymentUrl?.trim()) {
            throw new IllegalStateException('CONVEX_URL is required')
          }
          if (client == null) {
            client = new ConvexClient(deploymentUrl)
          }

          if (operation == 'setAuth') {
            client.setAuth(command.token)
            requireOutput(output.write([type: 'ack', id: id]))
          } else if (operation in ['query', 'mutation', 'action']) {
            ConvexClient.Result result = call(client, command)
            Map event = [type: 'result', id: id, value: result.value()]
            if (result.logs()) {
              event.logs = result.logs()
            }
            requireOutput(output.write(event))
          } else if (operation == 'subscribe') {
            if (live == null) {
              live = new LiveClient(deploymentUrl)
            }
            replaceRelay(command, live, relays, relayLock, output)
          } else if (operation == 'unsubscribe') {
            unsubscribe(command, relays, relayLock, output)
          } else if (operation == 'debugDisconnect') {
            if (live == null) {
              throw new IllegalStateException('Live WebSocket is not connected')
            }
            live.debugDisconnect()
            requireOutput(output.write([type: 'ack', id: id]))
          }
        } catch (OutputBackpressureException error) {
          break
        } catch (Throwable error) {
          if (!output.write(failure(id, '', error))) {
            break
          }
        }
      }
    } finally {
      // EOF, malformed terminal framing, explicit close, and output failure all
      // retire relays before closing networking. No daemon relay survives run().
      synchronized (relayLock) {
        relays.clear()
      }
      live?.close()
      client?.close()
      output.close(Duration.ofSeconds(2))
    }
  }

  private static ConvexClient.Result call(ConvexClient client, Map command) {
    if (command.op == 'query') {
      return client.query(command.path, command.args)
    }
    if (command.op == 'mutation') {
      return client.mutation(command.path, command.args)
    }
    client.action(command.path, command.args)
  }

  private static void replaceRelay(
    Map command,
    LiveClient live,
    Map<String, Relay> relays,
    Object relayLock,
    Output output
  ) {
    String subscriptionId = command.subscriptionId
    synchronized (relayLock) {
      Relay previous = relays.remove(subscriptionId)
      previous?.subscription?.close()

      LiveClient.Subscription subscription = live.subscribe(
        command.path,
        command.args,
      )
      long generation = (previous?.generation ?: 0L) + 1L
      Relay relay = new Relay(subscription, generation)
      relays[subscriptionId] = relay

      // Relay publication uses this same lock. Once this ack is queued, an old
      // relay paused after dequeue can observe the replacement only and exits.
      requireOutput(output.write([type: 'ack', id: command.id]))
      Thread.startDaemon("groovy-convex-relay-${subscriptionId}") {
        relayLoop(subscriptionId, relay, relays, relayLock, output)
      }
    }
  }

  private static void unsubscribe(
    Map command,
    Map<String, Relay> relays,
    Object relayLock,
    Output output
  ) {
    synchronized (relayLock) {
      Relay relay = relays.remove(command.subscriptionId)
      relay?.subscription?.close()
      requireOutput(output.write([type: 'ack', id: command.id]))
    }
  }

  static void relayLoop(
    String subscriptionId,
    Relay relay,
    Map<String, Relay> relays,
    Object relayLock,
    Output output
  ) {
    while (output.healthy()) {
      LiveClient.Update update
      try {
        update = relay.subscription.nextUpdate(Duration.ofDays(1))
      } catch (Throwable ignored) {
        return
      }

      relayPauseHook?.call()

      synchronized (relayLock) {
        if (relays[subscriptionId] != relay) {
          return
        }
        Map event
        if (update.error() != null) {
          event = failure('', subscriptionId, update.error())
        } else {
          event = [
            type: 'subscription',
            subscriptionId: subscriptionId,
            value: update.value(),
          ]
          if (update.logs()) {
            event.logs = update.logs()
          }
        }
        if (!output.write(event)) {
          relay.subscription.close()
          return
        }
      }
    }
  }

  static Map validateCommand(Map command) {
    String operation = requireIdLike(command.op, 'op')
    Set<String> required
    if (operation == 'hello') {
      required = ['protocolVersion', 'id', 'op'] as Set
    } else if (operation in ['query', 'mutation', 'action']) {
      required = ['id', 'op', 'path', 'args'] as Set
    } else if (operation == 'subscribe') {
      required = ['id', 'op', 'subscriptionId', 'path', 'args'] as Set
    } else if (operation == 'unsubscribe') {
      required = ['id', 'op', 'subscriptionId'] as Set
    } else if (operation == 'setAuth') {
      required = ['id', 'op', 'token'] as Set
    } else if (operation in ['close', 'debugDisconnect']) {
      required = ['id', 'op'] as Set
    } else {
      throw new ConvexClient.ProtocolException(
        "unknown adapter operation: ${operation}",
      )
    }

    if (command.keySet() != required) {
      throw new ConvexClient.ProtocolException(
        "${operation} command has an invalid shape",
      )
    }
    requireIdLike(command.id, 'id')

    if (operation == 'hello') {
      if (!(command.protocolVersion instanceof Number) ||
        new BigDecimal(command.protocolVersion.toString()) != BigDecimal.ONE) {
        throw new ConvexClient.ProtocolException(
          'unsupported adapter protocol version',
        )
      }
    }
    if (operation in ['query', 'mutation', 'action', 'subscribe']) {
      if (!(command.path instanceof String) || command.path.length() < 3) {
        throw new ConvexClient.ProtocolException(
          'path must be a string of at least three characters',
        )
      }
      if (!(command.args instanceof Map)) {
        throw new ConvexClient.ProtocolException('args must be a JSON object')
      }
    }
    if (operation in ['subscribe', 'unsubscribe']) {
      requireIdLike(command.subscriptionId, 'subscriptionId')
    }
    if (operation == 'setAuth' && !(command.token instanceof String)) {
      throw new ConvexClient.ProtocolException('token must be a string')
    }
    command
  }

  private static String requireIdLike(Object candidate, String field) {
    if (!(candidate instanceof String) ||
      candidate.isEmpty() ||
      candidate.length() > 128) {
      throw new ConvexClient.ProtocolException(
        "${field} must be a non-empty string of at most 128 characters",
      )
    }
    candidate
  }

  static Map failure(String id, String subscriptionId, Throwable error) {
    String name
    if (error instanceof ConvexClient.FunctionException) {
      name = 'FunctionError'
    } else if (error instanceof ConvexClient.ProtocolException) {
      name = 'ProtocolError'
    } else if (error instanceof ConvexClient.TransportException) {
      name = 'TransportError'
    } else {
      name = error.class.simpleName
    }

    Map event = [
      type: subscriptionId ? 'subscription' : 'error',
      error: [name: name, message: error.message ?: name],
    ]
    if (id) {
      event.id = id
    }
    if (subscriptionId) {
      event.subscriptionId = subscriptionId
    }
    if (error instanceof ConvexClient.FunctionException && error.data != null) {
      event.error.data = error.data
    }
    if (error instanceof ConvexClient.FunctionException && error.logs) {
      event.logs = error.logs
    }
    event
  }

  private static Throwable asProtocol(Throwable error) {
    error instanceof ConvexClient.ProtocolException
      ? error
      : new ConvexClient.ProtocolException(error.message ?: error.class.simpleName)
  }

  private static void requireOutput(boolean accepted) {
    if (!accepted) {
      throw new OutputBackpressureException()
    }
  }

  static final class Framer {
    private final InputStream input

    Framer(InputStream input) {
      this.input = input
    }

    Frame next() {
      ByteArrayOutputStream bytes = new ByteArrayOutputStream()
      boolean oversized = false
      while (true) {
        int current = input.read()
        if (current < 0) {
          if (oversized) {
            return Frame.fromError(
              new ConvexClient.ProtocolException(
                'oversized NDJSON frame ended before newline',
              ),
              true,
            )
          }
          if (bytes.size() > 0) {
            return Frame.fromError(
              new ConvexClient.ProtocolException(
                'partial NDJSON frame ended before newline',
              ),
              true,
            )
          }
          return Frame.endOfInput()
        }

        if (current == (int) '\n') {
          if (oversized) {
            return Frame.fromError(
              new ConvexClient.ProtocolException('NDJSON frame exceeds 1 MiB'),
              false,
            )
          }
          byte[] encoded = bytes.toByteArray()
          if (encoded.length > 0 && encoded[-1] == (byte) '\r') {
            encoded = Arrays.copyOf(encoded, encoded.length - 1)
          }
          try {
            String decoded = StandardCharsets.UTF_8.newDecoder()
              .onMalformedInput(CodingErrorAction.REPORT)
              .onUnmappableCharacter(CodingErrorAction.REPORT)
              .decode(ByteBuffer.wrap(encoded))
              .toString()
            return Frame.fromText(decoded)
          } catch (CharacterCodingException error) {
            return Frame.fromError(
              new ConvexClient.ProtocolException('NDJSON frame is not valid UTF-8'),
              false,
            )
          }
        }

        if (!oversized) {
          if (bytes.size() >= MAX_NDJSON_BYTES) {
            oversized = true
          } else {
            bytes.write(current)
          }
        }
      }
    }
  }

  static record Frame(
    String text,
    Throwable error,
    boolean eof,
    boolean terminal
  ) {
    static Frame fromText(String text) {
      new Frame(text, null, false, false)
    }

    static Frame fromError(Throwable error, boolean terminal) {
      new Frame(null, error, false, terminal)
    }

    static Frame endOfInput() {
      new Frame(null, null, true, true)
    }
  }

  static final class Relay {
    final LiveClient.Subscription subscription
    final long generation

    Relay(LiveClient.Subscription subscription, long generation) {
      this.subscription = subscription
      this.generation = generation
    }
  }

  /** Byte- and count-bounded asynchronous controller writer. */
  static final class Output {
    static final int MAX_EVENTS = 16
    static final int MAX_QUEUED_BYTES = 4 * 1024 * 1024
    static final int MAX_EVENT_BYTES = 1024 * 1024

    private final OutputStream stream
    private final ArrayBlockingQueue<Outbound> queue =
      new ArrayBlockingQueue<>(MAX_EVENTS)
    private final CountDownLatch finished = new CountDownLatch(1)
    private volatile boolean accepting = true
    private volatile boolean failed = false
    private int queuedBytes = 0

    Output(OutputStream stream) {
      this.stream = stream
      Thread writer = new Thread({ drain() }, 'groovy-adapter-output')
      writer.daemon = true
      writer.start()
    }

    synchronized boolean write(Map event) {
      if (!accepting || failed) {
        return false
      }
      byte[] encoded = (JsonOutput.toJson(event) + '\n')
        .getBytes(StandardCharsets.UTF_8)
      if (encoded.length > MAX_EVENT_BYTES ||
        queuedBytes + encoded.length > MAX_QUEUED_BYTES) {
        accepting = false
        failed = true
        return false
      }
      if (!queue.offer(new Outbound(encoded))) {
        accepting = false
        failed = true
        return false
      }
      queuedBytes += encoded.length
      true
    }

    boolean healthy() {
      accepting && !failed
    }

    void close(Duration timeout) {
      accepting = false
      finished.await(timeout.toMillis(), TimeUnit.MILLISECONDS)
    }

    private void drain() {
      try {
        while (accepting || !queue.isEmpty()) {
          Outbound outbound = queue.poll(50, TimeUnit.MILLISECONDS)
          if (outbound == null) {
            continue
          }
          stream.write(outbound.encoded)
          stream.flush()
          synchronized (this) {
            queuedBytes -= outbound.encoded.length
          }
        }
      } catch (Throwable ignored) {
        failed = true
        accepting = false
        queue.clear()
      } finally {
        finished.countDown()
      }
    }
  }

  static record Outbound(byte[] encoded) {}

  static final class OutputBackpressureException extends RuntimeException {
    OutputBackpressureException() {
      super('controller output queue is closed or full')
    }
  }
}
