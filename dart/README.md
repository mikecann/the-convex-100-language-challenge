# Convex from Dart

This folder shows a small native Dart program that calls Convex queries,
mutations, and actions over HTTP, then keeps a query updated over WebSocket.

This is educational and unofficial. It is not a production SDK or a package
intended for publication.

## Start here

Read the [basic example](examples/basics/main.dart). It queries a fresh counter,
starts Live before a mutation, verifies the initial and updated values, then
cleans up its subscription and client.

## What works

| Capability | Status |
| --- | --- |
| Native Dart implementation | Verified by shared local and hosted conformance |
| HTTP query, mutation, action, and bearer-token lifecycle | Verified by shared local and hosted conformance |
| Experimental Live query and reconnect support | Verified by shared local and hosted conformance |
| Earned capability badges | HTTP and Live |

## Basic example

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

The block is generated from the canonical runnable source. Run `./run
sync-examples` after changing it so the website and README stay identical.

## Docker-only verification

```sh
./run test dart
./run build dart
./run verify-example dart
./run verify dart
./run verify-hosted dart
```

`test` formats, analyses, unit-tests, and compiles the canonical example and
conformance adapter inside Docker. `build` creates the final linux/amd64
runtime image; the coordinator's serial verification also applies the shared
runtime policy and awards any HTTP or Live badges.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` accepts NDJSON protocol
v1 on stdin/stdout or a single `ADAPTER_LISTEN` TCP connection. Its
`debugDisconnect` command is adapter-only and forces a reconnect after retiring
the old socket. It is not part of the educational Dart API.

The client uses Dart's ordinary `dart:io` HTTP/TLS and WebSocket facilities.
Convex-specific request bodies, query-set Add/Remove messages, transitions,
error classes, reconnect metadata, and bounded newest-16 delivery are written
in Dart. The Live profile is the unversioned `/api/sync` profile pinned to
convex-rs 0.10.4 source commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`.
It is an experimental compatibility target, not a stable public protocol.

## Limitations

- Live authentication and token rotation are deferred.
- Full tagged Convex values, WebSocket mutations/actions, journals, optimistic
  updates, and `TransitionChunk` assembly are deferred.
- Shared local and hosted conformance passed on the reviewed commit, earning
  HTTP and Live.
