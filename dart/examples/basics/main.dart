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
  if (value is! Map || value['count'] is! num) {
    throw FormatException(
      '$operation did not return a numeric count: ${jsonEncode(value)}',
    );
  }
  return (value['count'] as num).toInt();
}

({bool applied, int count}) _readMutation(Object? value) {
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
  if (actual != expected)
    throw StateError('$operation count was $actual, expected $expected');
}

String _runId() =>
    List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
