package convex.adapter

import convex.ConvexClient
import convex.LiveClient
import groovy.json.JsonOutput
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.time.Duration

/** Test-only NDJSON adapter protocol v1 endpoint. */
final class Adapter {
  static final int MAX_NDJSON_BYTES = 1024 * 1024
  static void main(String[] args) {
    String listen = System.getenv('ADAPTER_LISTEN')
    if (listen?.trim()) {
      ServerSocket server = bind(listen)
      try { Socket controller = server.accept(); try { run(controller.inputStream, controller.outputStream, System.getenv('CONVEX_URL')) } finally { controller.close() } }
      finally { server.close() }
    } else run(System.in, System.out, System.getenv('CONVEX_URL'))
  }

  static ServerSocket bind(String address) {
    int cut = address.lastIndexOf(':')
    if (cut < 1) throw new IllegalArgumentException('ADAPTER_LISTEN must be host:port')
    ServerSocket server = new ServerSocket(); server.bind(new InetSocketAddress(InetAddress.getByName(address.substring(0, cut)), Integer.parseInt(address.substring(cut + 1)))); server
  }

  static void run(InputStream input, OutputStream outputStream, String deploymentUrl) {
    Output output = new Output(outputStream)
    Map<String, Relay> relays = [:]; Object relayLock = new Object()
    ConvexClient client = null; LiveClient live = null; boolean closing = false
    try {
      while (!closing) {
        String line = readLineBounded(input)
        if (line == null) break
        Map command
        try { command = (Map) ConvexClient.JSON.parseText(line) }
        catch (Throwable error) { output.write(failure('', '', error)); continue }
        String id = command.id?.toString() ?: ''; String op = command.op?.toString() ?: ''
        try {
          if (op == 'hello') {
            if ((command.protocolVersion as Number)?.intValue() != 1) throw new IllegalArgumentException('unsupported adapter protocol version')
            output.write([type: 'ready', id: id, protocolVersion: 1, language: 'groovy', implementation: 'native-groovy-jdk-httpclient', runtime: System.getProperty('java.runtime.version')]); continue
          }
          if (op == 'close') {
            synchronized (relayLock) { closing = true; relays.values()*.subscription*.close(); relays.clear(); output.write([type: 'closed', id: id]) }
            break
          }
          if (!deploymentUrl?.trim()) throw new IllegalStateException('CONVEX_URL is required')
          if (client == null) client = new ConvexClient(deploymentUrl)
          if (op == 'setAuth') { client.setAuth(command.token?.toString() ?: ''); output.write([type: 'ack', id: id]) }
          else if (op in ['query', 'mutation', 'action']) {
            Map args = command.args instanceof Map ? (Map) command.args : [:]
            ConvexClient.Result result = op == 'query' ? client.query(command.path?.toString(), args) : op == 'mutation' ? client.mutation(command.path?.toString(), args) : client.action(command.path?.toString(), args)
            Map event = [type: 'result', id: id, value: result.value()]; if (result.logs()) event.logs = result.logs(); output.write(event)
          } else if (op == 'subscribe') {
            String subscriptionId = command.subscriptionId?.toString() ?: ''; if (!subscriptionId) throw new IllegalArgumentException('subscriptionId is required')
            if (live == null) live = new LiveClient(deploymentUrl)
            Relay old; long generation
            synchronized (relayLock) {
              old = relays.remove(subscriptionId); old?.subscription?.close()
              LiveClient.Subscription sub = live.subscribe(command.path?.toString(), command.args instanceof Map ? (Map) command.args : [:])
              generation = (old?.generation ?: 0L) + 1L
              Relay relay = new Relay(sub, generation); relays[subscriptionId] = relay
              // Relay and acknowledgement share this lock, creating the required stale-event barrier.
              output.write([type: 'ack', id: id])
              Thread.startDaemon("groovy-convex-relay-${subscriptionId}") { relayLoop(subscriptionId, relay, relays, relayLock, output) }
            }
          } else if (op == 'unsubscribe') {
            String subscriptionId = command.subscriptionId?.toString() ?: ''
            synchronized (relayLock) { Relay relay = relays.remove(subscriptionId); relay?.subscription?.close(); output.write([type: 'ack', id: id]) }
          } else if (op == 'debugDisconnect') { if (live == null) throw new IllegalStateException('Live WebSocket is not connected'); live.debugDisconnect(); output.write([type: 'ack', id: id]) }
          else throw new IllegalArgumentException("unknown operation: ${op}")
        } catch (Throwable error) { output.write(failure(id, '', error)) }
      }
    } finally {
      synchronized (relayLock) { relays.values()*.subscription*.close(); relays.clear() }
      live?.close(); client?.close()
    }
  }

  private static void relayLoop(String id, Relay relay, Map<String, Relay> relays, Object lock, Output output) {
    while (true) {
      LiveClient.Update update
      try { update = relay.subscription.nextUpdate(Duration.ofDays(1)) } catch (Throwable error) { return }
      synchronized (lock) {
        if (relays[id] != relay) return
        if (update.error() != null) output.write(failure('', id, update.error()))
        else { Map event = [type: 'subscription', subscriptionId: id, value: update.value()]; if (update.logs()) event.logs = update.logs(); output.write(event) }
      }
    }
  }
  private static String readLineBounded(InputStream input) {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream()
    while (true) { int current = input.read(); if (current < 0) return bytes.size() == 0 ? null : bytes.toString(StandardCharsets.UTF_8); if (current == '\n' as char) return bytes.toString(StandardCharsets.UTF_8).replaceFirst('\\r$', ''); if (bytes.size() >= MAX_NDJSON_BYTES) { while ((current = input.read()) >= 0 && current != '\n' as char) {} ; throw new IllegalArgumentException('NDJSON frame exceeds 1 MiB') }; bytes.write(current) }
  }
  static Map failure(String id, String subscriptionId, Throwable error) {
    String name = error instanceof ConvexClient.FunctionException ? 'FunctionError' : error instanceof ConvexClient.ProtocolException ? 'ProtocolError' : error instanceof ConvexClient.TransportException ? 'TransportError' : error.class.simpleName
    Map event = [type: subscriptionId ? 'subscription' : 'error', error: [name: name, message: error.message ?: name]]
    if (id) event.id = id; if (subscriptionId) event.subscriptionId = subscriptionId
    if (error instanceof ConvexClient.FunctionException && error.data != null) event.error.data = error.data
    if (error instanceof ConvexClient.FunctionException && error.logs) event.logs = error.logs
    event
  }
  static final class Relay { final LiveClient.Subscription subscription; final long generation; Relay(LiveClient.Subscription subscription, long generation) { this.subscription = subscription; this.generation = generation } }
  static final class Output { private final Writer writer; Output(OutputStream stream) { writer = new OutputStreamWriter(stream, StandardCharsets.UTF_8) }; synchronized void write(Map event) { writer.write(JsonOutput.toJson(event)); writer.write('\n'); writer.flush() } }
}
