# Convex from Groovy

This small Groovy client makes a normal Convex HTTP query and mutation, then keeps the same query live over `/api/sync` to show the counter changing from `0` to `1`.

It is an educational, unofficial protocol demonstration, not a production SDK or a package intended for publication.

## Start here

[`examples/basics/Main.groovy`](examples/basics/Main.groovy) is the canonical example. It creates one unique room, reads it through HTTP, starts Live before the mutation, applies an idempotent mutation, and proves the resulting Live update agrees.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP query, mutation, action, bearer auth, logs, and structured errors | Implemented, pending root-owned conformance evidence |
| `/api/sync` live queries with reconnect and error recovery | Implemented, pending root-owned conformance evidence |
| Live auth, optimistic mutations, and `TransitionChunk` | Deliberately deferred |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.groovy -->
```text
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
```
<!-- END GENERATED EXAMPLE -->

## Docker checks

```sh
./run test groovy       # Lints, compiles, and runs Groovy-local deterministic tests in Docker.
./run build groovy      # Builds the linux/amd64 non-root conformance runtime image.
./run verify-example groovy  # Root-owned: runs this exact example against the approved local deployment.
./run verify-all groovy      # Root-owned: runs local and hosted black-box conformance serially.
```

The final images run compiled bytecode on the Temurin JRE. They contain no Groovy compiler, build tool, package manager, Node, Python, curl, or Convex CLI. The adapter and example also use separate compiled classpaths, so neither image contains the other's program or the test suite.

## Protocol notes

The client uses the pinned `convex-rs-0.10.4-unversioned-sync` `/api/sync` profile. JDK WebSocket callbacks copy fragments and control messages into a bounded inbox; one single-threaded owner performs protocol parsing, writes, reconnects, and query-set mutations. Each subscription keeps the newest 16 events within a 2 MiB encoded-value budget. The callback inbox is separately bounded to 32 events and 4 MiB. The test-only adapter supports strict, byte-bounded NDJSON on stdin/stdout or one `ADAPTER_LISTEN` TCP connection. Its output queue is bounded to 16 events and 4 MiB, and it exposes `debugDisconnect` only for the shared controller.

## Limitations

This is intentionally narrow: it has no persistence, offline replay, optimistic state, package metadata, or claim of protocol stability. A `QueryFailed` is delivered as a structured subscription error; a later valid `QueryUpdated` on the same subscription recovers it.
