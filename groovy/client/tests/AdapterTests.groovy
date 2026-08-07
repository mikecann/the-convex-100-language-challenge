package convex.tests

import convex.ConvexClient
import convex.LiveClient
import convex.adapter.Adapter
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Strict command, framing, TCP, relay-barrier, and writer-budget checks. */
final class AdapterTests {
  static void main(String[] args) {
    // This focused entrypoint lets Docker apply the shared 128 MiB ceiling to
    // the stopped-reader fixture without also starting its TCP child JVM.
    stoppedReaderUsesBoundedMemoryAndDoesNotBlockClose()
    println 'Groovy adapter backpressure test passed under the container limit'
  }

  static void run() {
    rejectsMalformedCommandsBeforeSideEffects()
    rejectsPartialInvalidAndOversizedNdjson()
    tcpModeCompletesCleanly()
    staleRelayCannotCrossAcknowledgement()
    stoppedReaderUsesBoundedMemoryAndDoesNotBlockClose()
  }

  private static void rejectsMalformedCommandsBeforeSideEffects() {
    List<String> malformed = [
      '{"protocolVersion":1,"id":"h","op":"hello","extra":true}',
      '{"id":"a","op":"setAuth"}',
      '{"id":"u","op":"unsubscribe"}',
      '{"id":"q","op":"query","path":"demo:x","args":[],"extra":1}',
    ]
    String input = (
      malformed +
      ['{"protocolVersion":1,"id":"ok","op":"hello"}',
       '{"id":"done","op":"close"}']
    ).join('\n') + '\n'
    List<Map> events = runAdapter(input.getBytes(StandardCharsets.UTF_8))
    assert events.take(4)*.type == ['error', 'error', 'error', 'error']
    assert events.take(4)*.error*.name.every { it == 'ProtocolError' }
    assert events[4].type == 'ready'
    assert events[5] == [type: 'closed', id: 'done']
  }

  private static void rejectsPartialInvalidAndOversizedNdjson() {
    byte[] partial = '{"protocolVersion":1,"id":"h","op":"hello"}'
      .getBytes(StandardCharsets.UTF_8)
    List<Map> partialEvents = runAdapter(partial)
    assert partialEvents.size() == 1
    assert partialEvents[0].error.message.contains('partial NDJSON')

    ByteArrayOutputStream invalidUtf8 = new ByteArrayOutputStream()
    invalidUtf8.write([0xc3, 0x28, 0x0a] as byte[])
    invalidUtf8.write('{"id":"done","op":"close"}\n'.getBytes(StandardCharsets.UTF_8))
    List<Map> utf8Events = runAdapter(invalidUtf8.toByteArray())
    assert utf8Events[0].error.message.contains('valid UTF-8')
    assert utf8Events[1].type == 'closed'

    String oversized = ('🚀' * 300_000) + '\n' +
      '{"protocolVersion":1,"id":"ok","op":"hello"}\n' +
      '{"id":"done","op":"close"}\n'
    List<Map> oversizedEvents = runAdapter(
      oversized.getBytes(StandardCharsets.UTF_8),
    )
    assert oversizedEvents[0].error.message.contains('exceeds 1 MiB')
    assert oversizedEvents[1].type == 'ready'
    assert oversizedEvents[2].type == 'closed'
  }

  private static void tcpModeCompletesCleanly() {
    ServerSocket reservation = new ServerSocket(0)
    int port = reservation.localPort
    reservation.close()

    String java = System.getProperty('java.home') + '/bin/java'
    ProcessBuilder builder = new ProcessBuilder(
      java,
      '-cp',
      System.getProperty('java.class.path'),
      'convex.adapter.Adapter',
    )
    builder.environment().put('ADAPTER_LISTEN', "127.0.0.1:${port}".toString())
    Process process = builder.start()

    Socket controller
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
    while (controller == null && System.nanoTime() < deadline) {
      try {
        controller = new Socket('127.0.0.1', port)
      } catch (IOException ignored) {
        Thread.sleep(20)
      }
    }
    assert controller != null: 'TCP adapter did not start listening'
    controller.soTimeout = 3_000
    controller.outputStream.write((
      '{"protocolVersion":1,"id":"hello","op":"hello"}\n' +
      '{"id":"close","op":"close"}\n'
    ).getBytes(StandardCharsets.UTF_8))
    controller.outputStream.flush()
    List<String> lines = controller.inputStream.newReader('UTF-8').readLines()
    controller.close()
    assert process.waitFor(3, TimeUnit.SECONDS)
    assert process.exitValue() == 0
    assert lines.size() == 2
    assert ConvexClient.JSON.parseText(lines[0]).type == 'ready'
    assert ConvexClient.JSON.parseText(lines[1]).type == 'closed'
  }

  private static void staleRelayCannotCrossAcknowledgement() {
    ['unsubscribe', 'replacement'].each { String mode ->
      ByteArrayOutputStream sink = new ByteArrayOutputStream()
      Adapter.Output output = new Adapter.Output(sink)
      Object lock = new Object()
      LiveClient.Subscription subscription = new LiveClient.Subscription(
        null,
        7,
        'demo:state',
        [:],
      )
      Adapter.Relay relay = new Adapter.Relay(subscription, 1)
      Map<String, Adapter.Relay> relays = [same: relay]
      CountDownLatch dequeued = new CountDownLatch(1)
      CountDownLatch release = new CountDownLatch(1)
      Adapter.relayPauseHook = {
        dequeued.countDown()
        release.await(2, TimeUnit.SECONDS)
      }
      Thread worker = Thread.start("relay-barrier-${mode}") {
        Adapter.relayLoop('same', relay, relays, lock, output)
      }
      subscription.offer(new LiveClient.Update([count: 99], null, []))
      assert dequeued.await(2, TimeUnit.SECONDS)

      synchronized (lock) {
        relays.remove('same')
        subscription.finish()
        assert output.write([type: 'ack', id: mode])
      }
      release.countDown()
      worker.join(2_000)
      Adapter.relayPauseHook = null
      output.close(Duration.ofSeconds(1))

      List<Map> events = sink.toString(StandardCharsets.UTF_8)
        .readLines()
        .collect { (Map) ConvexClient.JSON.parseText(it) }
      assert events == [[type: 'ack', id: mode]]
    }
  }

  private static void stoppedReaderUsesBoundedMemoryAndDoesNotBlockClose() {
    BlockingOutputStream sink = new BlockingOutputStream()
    Adapter.Output output = new Adapter.Output(sink)
    int accepted = 0
    String payload = 'x' * (512 * 1024)
    while (output.write([type: 'subscription', subscriptionId: 's', value: payload])) {
      accepted++
    }
    assert accepted <= 8: "writer accepted too much buffered data: ${accepted} events"
    assert !output.healthy()

    long started = System.nanoTime()
    output.close(Duration.ofMillis(250))
    long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
    assert elapsed < 750: "writer close blocked for ${elapsed}ms"
    sink.release.countDown()
  }

  private static List<Map> runAdapter(byte[] input) {
    ByteArrayOutputStream output = new ByteArrayOutputStream()
    Adapter.run(new ByteArrayInputStream(input), output, null)
    output.toString(StandardCharsets.UTF_8)
      .readLines()
      .findAll { it }
      .collect { (Map) ConvexClient.JSON.parseText(it) }
  }

  private static final class BlockingOutputStream extends OutputStream {
    final CountDownLatch release = new CountDownLatch(1)

    @Override
    void write(int value) {
      release.await(5, TimeUnit.SECONDS)
    }

    @Override
    void write(byte[] value, int offset, int length) {
      release.await(5, TimeUnit.SECONDS)
    }
  }
}
