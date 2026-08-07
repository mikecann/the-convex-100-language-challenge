package convex.tests

import com.sun.net.httpserver.HttpServer
import convex.ConvexClient
import convex.LiveClient
import examples.basics.Main
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.time.Duration

/** Deterministic HTTP, numeric-decoding, and subscription-buffer checks. */
final class ClientTests {
  static void run() {
    rejectsUnsafeUrlAndPreservesStructuredError()
    acceptsOnlyIntegralJsonNumbers()
    keepsNewestSixteenWithinByteBudget()
  }

  private static void rejectsUnsafeUrlAndPreservesStructuredError() {
    try {
      new ConvexClient('ftp://example.invalid')
      assert false: 'accepted an unsafe deployment URL'
    } catch (IllegalArgumentException expected) {
      // Expected.
    }

    HttpServer server = HttpServer.create(new InetSocketAddress('127.0.0.1', 0), 0)
    server.createContext('/api/query') { exchange ->
      byte[] body = (
        '{"status":"error","errorMessage":"empty",' +
        '"errorData":{"code":"ROOM_EMPTY"},"logLines":["checked"]}'
      ).getBytes(StandardCharsets.UTF_8)
      exchange.sendResponseHeaders(560, body.length)
      exchange.responseBody.write(body)
      exchange.close()
    }
    server.start()
    try {
      new ConvexClient("http://127.0.0.1:${server.address.port}").withCloseable {
        it.query('demo:state', [:])
        assert false: 'structured function failure became a result'
      }
    } catch (ConvexClient.FunctionException error) {
      assert error.data.code == 'ROOM_EMPTY'
      assert error.logs == ['checked']
    } finally {
      server.stop(0)
    }
  }

  private static void acceptsOnlyIntegralJsonNumbers() {
    assert Main.count([count: new BigDecimal('1.0')], 'test') == 1
    List<Object> invalid = [
      '1',
      new BigDecimal('1.5'),
      Double.NaN,
      new BigDecimal('2147483648'),
    ]
    invalid.each { Object value ->
      try {
        Main.count([count: value], 'test')
        assert false: "accepted invalid count ${value}"
      } catch (IllegalStateException expected) {
        // Expected.
      }
    }
  }

  private static void keepsNewestSixteenWithinByteBudget() {
    LiveClient.Subscription newest = new LiveClient.Subscription(
      null,
      1,
      'demo:state',
      [:],
    )
    (0..<20).each {
      newest.offer(new LiveClient.Update([count: it], null, []))
    }
    assert newest.next(Duration.ofMillis(10)).count == 4

    LiveClient.Subscription enormous = new LiveClient.Subscription(
      null,
      2,
      'demo:state',
      [:],
    )
    enormous.offer(new LiveClient.Update([
      value: 'x' * (2 * 1024 * 1024),
    ], null, []))
    try {
      enormous.next(Duration.ofMillis(10))
      assert false: 'accepted a value above the encoded byte budget'
    } catch (ConvexClient.ProtocolException expected) {
      // Expected.
    }
  }
}
