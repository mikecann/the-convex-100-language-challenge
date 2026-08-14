<img src="logo.png" alt="Dart logo" width="160">
<!-- Logo source: https://services.google.com/fh/files/misc/dart_brand_guidelines_assets.zip -->

# Dart

[Dart](https://dart.dev/) is a type-safe, garbage-collected language with
familiar C-style syntax. It was first released in 2011 as an embeddable,
multi-platform language, then [Dart 2 refocused it on client development](https://dart.dev/blog/announcing-dart-2-optimized-for-client-side-development).
Today its best-known niche is powering Flutter apps, though the SDK can also
compile command-line and server programs to native machine code or target the
web through JavaScript and WebAssembly.

This repository's client is educational, unofficial, and not a production SDK
or publishable package. Dart and the related logo are trademarks of Google LLC.
We are not endorsed by or affiliated with Google LLC.

## Getting Started

Start with the [canonical basic example](examples/basics/main.dart). It queries
a fresh counter, opens a Live subscription before mutating that counter, checks
the reactive update, and cleans up both resources. From the repository root,
Docker builds and runs that exact program against a unique test room:

```sh
./run verify-example dart
```

The command needs Docker, but it does not require a Dart SDK on your host.

## Interesting Parts

### A mutation reply is a record, not a class

Dart 3 (2023) added records: anonymous, immutable tuples with named fields.
The basics example uses one to hand back both halves of `demo:increment`'s
reply without declaring a throwaway class. Notice how the `is!` checks also
*promote* `value` from `Object?` to `Map` — Dart's flow analysis makes the
casts unnecessary after the guard:

```dart
({bool applied, int count}) _readMutation(Object? value) {
  if (value is! Map || value['applied'] is! bool || value['state'] is! Map) {
    throw FormatException('mutation did not return the expected shape');
  }
  return (applied: value['applied'] as bool, count: _count(value['state']));
}

final result = await client.mutation('demo:increment',
    {'room': room, 'language': 'dart', 'runId': _runId()});
// TypeScript: const { applied, state } = await increment({ room, ... });
final reply = _readMutation(result.value);
print('applied=${reply.applied} count=${reply.count}');
```

The return type `({bool applied, int count})` is the whole contract, written
inline where a TypeScript developer would reach for an interface.

### Forget an error case and it won't compile

Everything this client can throw lives under one `sealed class ConvexError`.
Sealing tells the compiler the subclass list is closed, so a `switch`
expression over an error is checked for exhaustiveness — miss a case and the
build fails, which is how the conformance adapter labels failures:

```dart
// TypeScript: instanceof chains, and nothing warns about a forgotten case.
final kind = switch (error) {
  FunctionError() => 'FunctionError',         // your Convex function threw
  TransportError() => 'TransportError',       // network, TLS, or timeout
  ProtocolError() => 'ProtocolError',         // reply broke the pinned contract
  ClientClosedError() => 'ClientClosedError', // used after close()
};
```

Those `FunctionError()` shapes are object patterns; they can also pull fields
out in the same breath, like `FunctionError(:final data)`.

### A Live query is a stream you pull

Dart shipped `async`/`await` and `Stream` in 2015, before JavaScript had
either, so Convex's reactive side maps straight onto the standard library:
`subscribe` returns a `LiveSubscription` whose `updates` getter is a
`Stream<LiveUpdate>`, and a `StreamIterator` lets a command-line program pull
each update exactly when it is ready:

```dart
final subscription = await client.subscribe('demo:state', {'room': room});
// TypeScript: const state = useQuery(api.demo.state, { room }); auto re-render
final updates = StreamIterator<LiveUpdate>(subscription.updates);

await updates.moveNext(); // First value: the server's current state.
print('initial: ${updates.current.value}');

await client.mutation('demo:increment',
    {'room': room, 'language': 'dart', 'runId': _runId()});

await updates.moveNext(); // Pushed by Convex — no second query.
print('updated: ${updates.current.value}');

await subscription.close();
```

The iterator stays attached across both reads, so the update triggered by the
mutation cannot slip through a gap between polls.

## Status

| Capability | Status |
| --- | --- |
| Native Dart implementation | Verified by shared local and hosted conformance |
| HTTP query, mutation, action, and bearer-token lifecycle | Verified by shared local and hosted conformance |
| Experimental Live query and reconnect support | Verified by shared local and hosted conformance |
| Earned capability badges | HTTP and Live |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.dart -->
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../client/convex_client.dart';
import '../../client/live_client.dart';

Future<void> main(List<String> arguments) async {
  final deploymentUrl = Platform.environment['CONVEX_URL'];
  if (deploymentUrl == null || deploymentUrl.isEmpty) {
    stderr.writeln('CONVEX_URL is required');
    exitCode = 2;
    return;
  }

  // Create a Convex client connected to the deployment selected by the environment.
  final client = ConvexClient(deploymentUrl);
  final room = arguments.isEmpty ? 'dart-example' : arguments.first;
  try {
    // Run a Convex query over HTTP to get this room's current counter state.
    final current = await client.query('demo:state', {'room': room});
    final currentCount = _count('current query', current.value);
    stdout.writeln('current count: $currentCount');

    // Start Live before changing the counter so the initial snapshot and next
    // update prove that the subscription observed this exact mutation.
    final subscription = await client.subscribe('demo:state', {'room': room});
    // Keep one listener attached for both values. A Live stream is a sequence,
    // so reopening a one-listener stream after the mutation could miss an update.
    final updates = StreamIterator(subscription.updates);
    try {
      // The first Live value is the server's current state, not a cached HTTP result.
      final initial = await _nextValue(updates);
      final initialCount = _count('initial Live value', initial);
      _expect('initial Live value', initialCount, currentCount);
      stdout.writeln('live initial count: $initialCount');

      // Give the mutation a fresh idempotency key. Retrying this same key asks
      // Convex for the existing result instead of incrementing the room twice.
      final mutation = await client.mutation('demo:increment', {
        'room': room,
        'language': 'dart',
        'runId': _runId(),
      });
      final applied = _readMutation(mutation.value);
      if (!applied.applied) throw StateError('mutation was not applied');
      stdout.writeln('mutation applied: ${applied.applied}');
      final expected = currentCount + 1;
      _expect('mutation', applied.count, expected);
      stdout.writeln('mutation count: ${applied.count}');

      // Receive the changed counter from the existing Live stream, without a second HTTP query.
      final updated = await _nextValue(updates);
      final updatedCount = _count('updated Live value', updated);
      _expect('updated Live value', updatedCount, expected);
      stdout.writeln('live updated count: $updatedCount');

      // Only print the universal final verification line after every included operation agrees.
      stdout.writeln('verified count: $currentCount -> $updatedCount');
    } finally {
      // Stop the reactive query before the client closes its socket.
      await updates.cancel();
      await subscription.close();
    }
  } finally {
    // Close the HTTP client and its Live socket when this teaching example exits.
    await client.close();
  }
}

Future<Object?> _nextValue(StreamIterator<LiveUpdate> updates) async {
  // Bound the wait so a broken Live connection fails the example instead of
  // hanging forever, and turn a structured Live failure back into an error.
  final hasUpdate = await updates.moveNext().timeout(
    const Duration(seconds: 10),
  );
  if (!hasUpdate)
    throw StateError('Live subscription closed before delivering an update');
  final update = updates.current;
  if (update.error != null) throw update.error!;
  return update.value;
}

int _count(String operation, Object? value) {
  // Decode the JSON object into the simple Dart value this example needs while
  // rejecting a surprising server result rather than printing false success.
  if (value is! Map || value['count'] is! num) {
    throw FormatException(
      '$operation did not return a numeric count: ${jsonEncode(value)}',
    );
  }
  return (value['count'] as num).toInt();
}

({bool applied, int count}) _readMutation(Object? value) {
  // The mutation returns both idempotency status and the new counter state, so
  // validate both fields before trusting either one.
  if (value is! Map || value['applied'] is! bool || value['state'] is! Map) {
    throw FormatException(
      'mutation did not return the expected shape: ${jsonEncode(value)}',
    );
  }
  return (
    applied: value['applied'] as bool,
    count: _count('mutation state', value['state']),
  );
}

void _expect(String operation, int actual, int expected) {
  // Each demonstrated step must agree with the expected 0 -> 1 journey.
  if (actual != expected)
    throw StateError('$operation count was $actual, expected $expected');
}

String _runId() =>
    // A random key makes this run unique while still allowing Convex to dedupe
    // a retry of the same mutation request.
    List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
```
<!-- END GENERATED EXAMPLE -->

The block above is generated from the canonical runnable source. If that source
changes, `./run sync-examples` updates both the README and website copy.

## Implementation Notes

The public client has no third-party package dependencies. It uses Dart's
standard `dart:io` HTTP, TLS, and WebSocket support plus `dart:convert` for JSON,
then implements the Convex-specific request and Live behavior in Dart. HTTP
calls return `Future<ConvexResult>` values and distinguish function, protocol,
transport, and closed-client failures with a sealed error hierarchy.

One `LiveClient` serializes socket ownership, reconnects, and subscription
changes. Each subscription feeds a single-listener stream through a bounded
newest-16 relay, dropping the oldest queued update if a consumer falls behind.
That protects socket processing from an unbounded Dart `StreamController`
queue. The implementation also suppresses an unchanged value after reconnect.

Docker pins Dart SDK 3.7.2 and compiles the example and test adapter into
`linux/amd64` AOT executables. The final images include their runtime library
closure and CA certificates, but no Dart command, compiler, package manager,
Node.js, Python, or Convex CLI. The experimental Live implementation targets
the unversioned `/api/sync` behavior pinned to convex-rs 0.10.4 source commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

## Known Issues

1. Live authentication and token rotation are not implemented.
2. Values are limited to JSON-safe data. Full tagged Convex value types are not
   decoded by this demonstration.
3. WebSocket mutations and actions, query journals, optimistic updates, and
   `TransitionChunk` assembly are deferred. The HTTP and Live capabilities in
   the status table are still backed by shared local and hosted conformance.
