package examples.basics

import convex.ConvexClient
import convex.LiveClient
import java.time.Duration

/** The canonical teaching example, also executed unchanged by the verifier. */
final class Main {
  static void main(String[] arguments) {
    // The verifier supplies a unique room as argument one. A friendly default makes local runs clear.
    String room = arguments ? arguments[0] : (System.getenv('EXAMPLE_ROOM') ?: 'groovy-example')
    String url = System.getenv('CONVEX_URL') ?: 'https://usable-reindeer-44.convex.cloud'
    Map roomArgs = [room: room]
    try (ConvexClient client = new ConvexClient(url); LiveClient live = new LiveClient(url)) {
      // Read the current counter through Convex's ordinary JSON HTTP API.
      int before = count(client.query('demo:state', roomArgs).value(), 'HTTP query')

      // Start Live before mutating so this subscription observes the resulting update.
      LiveClient.Subscription subscription = live.subscribe('demo:state', roomArgs)
      int initial = count(subscription.next(Duration.ofSeconds(10)), 'initial Live value')
      if (initial != before) throw new IllegalStateException('Live initial value disagreed with HTTP')

      // The random runId is an idempotency key, so a transport retry cannot increment twice.
      Map mutationArgs = [
        room: room,
        language: 'groovy',
        runId: UUID.randomUUID().toString(),
      ]
      Map mutation = (Map) client.mutation(
        'demo:increment',
        mutationArgs,
      ).value()
      boolean applied = mutation.applied == true
      int after = count(mutation.state, 'mutation result')
      if (!applied || after != before + 1) {
        throw new IllegalStateException(
          'mutation did not produce the expected next count',
        )
      }

      // Decode the actual reactive update rather than issuing a second HTTP query.
      int updated = count(subscription.next(Duration.ofSeconds(10)), 'updated Live value')
      if (updated != after) throw new IllegalStateException('Live update disagreed with mutation')
      subscription.close()

      // This six-line transcript is deliberately the universal verifier contract.
      println "current count: ${before}"
      println "live initial count: ${initial}"
      println "mutation applied: ${applied}"
      println "mutation count: ${after}"
      println "live updated count: ${updated}"
      println "verified count: ${before} -> ${updated}"
    }
  }

  // Convex JSON numbers may be 1.0. Accept only in-range mathematical integers.
  static int count(Object state, String operation) {
    Object value = state instanceof Map ? state.count : null
    if (!(value instanceof Number)) throw new IllegalStateException("${operation} returned a non-numeric count")
    if ((value instanceof Double || value instanceof Float) && !Double.isFinite(((Number) value).doubleValue())) {
      throw new IllegalStateException("${operation} returned a non-finite count")
    }
    BigDecimal number = new BigDecimal(value.toString())
    if (number.stripTrailingZeros().scale() > 0 ||
      number < Integer.MIN_VALUE ||
      number > Integer.MAX_VALUE) {
      throw new IllegalStateException(
        "${operation} returned a non-integral or overflowing count",
      )
    }
    number.intValueExact()
  }
}
