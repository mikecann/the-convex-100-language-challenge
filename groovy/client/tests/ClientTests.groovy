package convex.tests

import com.sun.net.httpserver.HttpServer
import convex.ConvexClient
import convex.LiveClient
import examples.basics.Main
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.time.Duration

/** Deterministic language-local tests for HTTP structure, numeric decoding, and bounded Live delivery. */
final class ClientTests {
  static void main(String[] args) {
    rejectsUnsafeUrlAndPreservesStructuredError(); acceptsIntegralDecimals(); keepsNewestSixteenWithinByteBudget(); adapterErrorShape(); println 'Groovy client tests passed'
  }
  static void rejectsUnsafeUrlAndPreservesStructuredError() {
    try { new ConvexClient('ftp://example.invalid'); assert false } catch (IllegalArgumentException expected) {}
    HttpServer server = HttpServer.create(new InetSocketAddress('127.0.0.1', 0), 0)
    server.createContext('/api/query') { exchange -> byte[] body = '{"status":"error","errorMessage":"empty","errorData":{"code":"ROOM_EMPTY"},"logLines":["checked"]}'.getBytes(StandardCharsets.UTF_8); exchange.sendResponseHeaders(560, body.length); exchange.responseBody.write(body); exchange.close() }
    server.start(); try { new ConvexClient("http://127.0.0.1:${server.address.port}").withCloseable { it.query('demo:state', [:]); assert false } } catch (ConvexClient.FunctionException error) { assert error.data.code == 'ROOM_EMPTY'; assert error.logs == ['checked'] } finally { server.stop(0) }
  }
  static void acceptsIntegralDecimals() { assert Main.count([count: new BigDecimal('1.0')], 'test') == 1; for (Object bad : ['1', new BigDecimal('1.5'), Double.NaN, new BigDecimal('2147483648')]) { try { Main.count([count: bad], 'test'); assert false } catch (IllegalStateException expected) {} } }
  static void keepsNewestSixteenWithinByteBudget() {
    def sub = new LiveClient.Subscription(null, 1, 'demo:state', [:]); (0..<20).each { sub.offer(new LiveClient.Update([count: it], null, [])) }; assert sub.next(Duration.ofMillis(10)).count == 4
    def enormous = new LiveClient.Subscription(null, 2, 'demo:state', [:]); enormous.offer(new LiveClient.Update([value: 'x' * (2 * 1024 * 1024)], null, [])); try { enormous.next(Duration.ofMillis(10)); assert false } catch (ConvexClient.ProtocolException expected) {}
  }
  static void adapterErrorShape() { Map event = convex.adapter.Adapter.failure('a', '', new ConvexClient.ProtocolException('bad')); assert event.type == 'error'; assert event.id == 'a'; assert event.error.name == 'ProtocolError'; assert !event.containsKey('subscriptionId') }
}
