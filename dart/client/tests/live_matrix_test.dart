import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../convex_client.dart';
import '../live_client.dart';

Future<void> main() async {
  await _reconnectAndErrorMatrix();
  await _backoffAndTimestampMatrix();
  stdout.writeln('PASS deterministic Dart Live reconnect and error matrix');
}

Future<void> _reconnectAndErrorMatrix() async {
  final fixture = await _LiveFixture.start();
  final client = ConvexClient(fixture.url);
  final subscription = await client.subscribe('demo:state', {'room': 'matrix'});
  final updates = StreamIterator(subscription.updates);
  try {
    _expectValue(await _next(updates), 0, 'initial QueryUpdated');

    for (var reconnect = 1; reconnect <= 5; reconnect += 1) {
      await client.debugDisconnectForAdapter();
      await fixture.waitForConnections(reconnect + 1);
      await fixture.sendValue(reconnect);
      _expectValue(
        await _next(updates),
        reconnect,
        'debug reconnect $reconnect',
      );
    }

    _check(fixture.connectMessages.length == 6, 'expected six real sockets');
    for (var index = 0; index < fixture.connectMessages.length; index += 1) {
      final connect = fixture.connectMessages[index];
      _check(
        connect['connectionCount'] == index,
        'connectionCount was not carried on socket $index',
      );
      if (index > 0) {
        _check(
          connect['lastCloseReason'] == 'DebugDisconnect',
          'debug close reason missing on socket $index',
        );
        _check(
          connect['maxObservedTimestamp'] is String,
          'maxObservedTimestamp missing on socket $index',
        );
      }
      _check(
        fixture.addMessages[index]['type'] == 'Add',
        'active Add was not resent on socket $index',
      );
    }

    await fixture.dropGenuinely();
    final dropped = await _next(updates);
    _check(
      dropped.error is TransportError,
      'genuine socket drop did not publish TransportError',
    );
    await fixture.waitForConnections(7);
    _expectValue(
      await _next(updates),
      5,
      'transport recovery should publish a valid value',
    );

    await fixture.sendQueryFailure('EXPECTED_FAILURE');
    final failed = await _next(updates);
    _check(failed.error is FunctionError, 'QueryFailed was not structured');
    await fixture.sendValue(6);
    _expectValue(await _next(updates), 6, 'QueryFailed recovery');

    await fixture.sendQueryUpdatedWithoutValue();
    final malformed = await _next(updates);
    _check(
      malformed.error is ProtocolError &&
          malformed.error!.message.contains('omitted value'),
      'omitted QueryUpdated value was accepted',
    );
    await fixture.waitForConnections(8);
    _expectValue(await _next(updates), 6, 'protocol reconnect recovery');

    final removeSeen = fixture.removeSeen.future;
    await subscription.close().timeout(const Duration(seconds: 1));
    await removeSeen.timeout(const Duration(seconds: 1));
  } finally {
    await updates.cancel();
    await client.close().timeout(const Duration(seconds: 1));
    await fixture.close();
  }
}

Future<void> _backoffAndTimestampMatrix() async {
  final fixture = await _BackoffFixture.start();
  final client = ConvexClient(fixture.url);
  final subscription = await client.subscribe('demo:state', {
    'room': 'backoff',
  });
  final updates = StreamIterator(subscription.updates);
  try {
    _expectValue(await _next(updates), 0, 'backoff initial value');
    final firstTimestamp = fixture.lastSentTimestamp;
    _check(firstTimestamp == 'AQAAAAAAAAA=', 'unexpected first timestamp');

    fixture.rejectNextUpgrades(3);
    await fixture.dropGenuinely();
    await fixture.waitForAcceptedConnections(2);
    _expectValue(
      await _nextSuccessful(updates),
      0,
      'value after accumulated handshake failures',
    );
    _check(fixture.rejectedUpgrades == 3, 'did not reject three handshakes');
    final afterFailures = fixture.connectMessages[1];
    _check(
      afterFailures['connectionCount'] == 4,
      'three failed handshakes produced ${afterFailures['connectionCount']}, expected connectionCount 4',
    );
    _check(
      afterFailures['maxObservedTimestamp'] == firstTimestamp,
      'maxObservedTimestamp did not survive failed handshakes',
    );

    final secondTimestamp = fixture.lastSentTimestamp;
    _check(secondTimestamp == 'AgAAAAAAAAA=', 'unexpected second timestamp');
    final reconnectWatch = Stopwatch()..start();
    await fixture.dropGenuinely();
    await fixture.waitForAcceptedConnections(3);
    reconnectWatch.stop();
    _check(
      reconnectWatch.elapsed < const Duration(milliseconds: 500),
      'valid transition did not reset backoff: ${reconnectWatch.elapsed}',
    );
    final afterReset = fixture.connectMessages[2];
    _check(
      afterReset['connectionCount'] == 5,
      'post-reset reconnect had ${afterReset['connectionCount']}, expected connectionCount 5',
    );
    _check(
      afterReset['maxObservedTimestamp'] == secondTimestamp,
      'post-reset Connect did not carry the exact latest timestamp',
    );
    _expectValue(
      await _nextSuccessful(updates),
      0,
      'value after reset backoff reconnect',
    );
    await subscription.close().timeout(const Duration(seconds: 1));
  } finally {
    await updates.cancel();
    await client.close().timeout(const Duration(seconds: 1));
    await fixture.close();
  }
}

Future<LiveUpdate> _next(StreamIterator<LiveUpdate> updates) async {
  final moved = await updates.moveNext().timeout(const Duration(seconds: 3));
  if (!moved) throw StateError('Live stream ended early');
  return updates.current;
}

Future<LiveUpdate> _nextSuccessful(StreamIterator<LiveUpdate> updates) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    final update = await _next(updates);
    if (update.error == null) return update;
  }
  throw StateError('Live stream did not recover after transport failures');
}

void _expectValue(LiveUpdate update, int expected, String label) {
  if (update.error != null || update.value is! Map) {
    throw StateError('$label returned ${update.error ?? update.value}');
  }
  _check((update.value as Map)['count'] == expected, '$label value mismatch');
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _LiveFixture {
  _LiveFixture._(this.server);

  static Future<_LiveFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _LiveFixture._(server);
    unawaited(server.forEach(fixture._handle));
    return fixture;
  }

  final HttpServer server;
  final StreamController<int> _connectionEvents =
      StreamController<int>.broadcast(sync: true);
  final List<Map<String, dynamic>> connectMessages = [];
  final List<Map<String, dynamic>> addMessages = [];
  final Completer<void> removeSeen = Completer<void>();
  WebSocket? _active;
  int _queryId = 0;
  int _count = 0;
  int _timestamp = 0;
  String _remoteTimestamp = 'AAAAAAAAAAA=';
  int _remoteQuerySet = 0;

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> waitForConnections(int expected) async {
    if (connectMessages.length >= expected) return;
    await _connectionEvents.stream
        .firstWhere((count) => count >= expected)
        .timeout(const Duration(seconds: 3));
  }

  Future<void> sendValue(int value) async {
    _count = value;
    _sendModification({
      'type': 'QueryUpdated',
      'queryId': _queryId,
      'value': {'count': value},
      'logLines': <String>[],
    });
  }

  Future<void> sendQueryFailure(String code) async {
    _sendModification({
      'type': 'QueryFailed',
      'queryId': _queryId,
      'errorMessage': 'intentional failure',
      'errorData': {'code': code},
      'logLines': <String>[],
    });
  }

  Future<void> sendQueryUpdatedWithoutValue() async {
    _sendModification({
      'type': 'QueryUpdated',
      'queryId': _queryId,
      'logLines': <String>[],
    });
  }

  Future<void> dropGenuinely() async {
    final socket = _active;
    if (socket == null) throw StateError('no active fixture socket');
    await socket.close(WebSocketStatus.internalServerError, 'fixture drop');
  }

  Future<void> close() async {
    await _active?.close();
    await server.close(force: true);
    await _connectionEvents.close();
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/api/sync') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    var connected = false;
    await for (final raw in socket) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      if (!connected) {
        _active = socket;
        connectMessages.add(message);
        connected = true;
        continue;
      }
      if (message['type'] != 'ModifyQuerySet') continue;
      final modification =
          (message['modifications'] as List).first as Map<String, dynamic>;
      if (modification['type'] == 'Add') {
        addMessages.add(modification);
        _queryId = modification['queryId'] as int;
        _remoteQuerySet = 0;
        _remoteTimestamp = 'AAAAAAAAAAA=';
        _sendModification({
          'type': 'QueryUpdated',
          'queryId': _queryId,
          'value': {'count': _count},
          'logLines': <String>[],
        }, endQuerySet: 1);
        _connectionEvents.add(connectMessages.length);
      } else if (modification['type'] == 'Remove') {
        if (!removeSeen.isCompleted) removeSeen.complete();
      }
    }
  }

  void _sendModification(
    Map<String, Object?> modification, {
    int? endQuerySet,
  }) {
    final socket = _active;
    if (socket == null) throw StateError('no active fixture socket');
    final nextTimestamp = _timestampValue(++_timestamp);
    final nextQuerySet = endQuerySet ?? _remoteQuerySet;
    socket.add(
      jsonEncode({
        'type': 'Transition',
        'startVersion': {
          'querySet': _remoteQuerySet,
          'identity': 0,
          'ts': _remoteTimestamp,
        },
        'endVersion': {
          'querySet': nextQuerySet,
          'identity': 0,
          'ts': nextTimestamp,
        },
        'modifications': [modification],
      }),
    );
    _remoteQuerySet = nextQuerySet;
    _remoteTimestamp = nextTimestamp;
  }
}

class _BackoffFixture {
  _BackoffFixture._(this.server);

  static Future<_BackoffFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _BackoffFixture._(server);
    unawaited(server.forEach(fixture._handle));
    return fixture;
  }

  final HttpServer server;
  final List<Map<String, dynamic>> connectMessages = [];
  final StreamController<int> _acceptedEvents = StreamController<int>.broadcast(
    sync: true,
  );
  final List<WebSocket> _sockets = [];
  WebSocket? _active;
  int _rejectRemaining = 0;
  int rejectedUpgrades = 0;
  int _timestamp = 0;
  String lastSentTimestamp = '';

  String get url => 'http://${server.address.address}:${server.port}';

  void rejectNextUpgrades(int count) {
    _rejectRemaining = count;
  }

  Future<void> waitForAcceptedConnections(int expected) async {
    if (connectMessages.length >= expected) return;
    await _acceptedEvents.stream
        .firstWhere((count) => count >= expected)
        .timeout(const Duration(seconds: 6));
  }

  Future<void> dropGenuinely() async {
    final socket = _active;
    if (socket == null) throw StateError('no active backoff fixture socket');
    await socket.close(WebSocketStatus.internalServerError, 'backoff drop');
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await server.close(force: true);
    await _acceptedEvents.close();
  }

  Future<void> _handle(HttpRequest request) async {
    if (_rejectRemaining > 0) {
      _rejectRemaining -= 1;
      rejectedUpgrades += 1;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    var connected = false;
    await for (final raw in socket) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      if (!connected) {
        _active = socket;
        connectMessages.add(message);
        connected = true;
        continue;
      }
      if (message['type'] != 'ModifyQuerySet') continue;
      final modification =
          (message['modifications'] as List).first as Map<String, dynamic>;
      if (modification['type'] != 'Add') continue;
      final timestamp = _timestampValue(++_timestamp);
      lastSentTimestamp = timestamp;
      socket.add(
        jsonEncode({
          'type': 'Transition',
          'startVersion': {'querySet': 0, 'identity': 0, 'ts': 'AAAAAAAAAAA='},
          'endVersion': {'querySet': 1, 'identity': 0, 'ts': timestamp},
          'modifications': [
            {
              'type': 'QueryUpdated',
              'queryId': modification['queryId'],
              'value': {'count': 0},
              'logLines': <String>[],
            },
          ],
        }),
      );
      _acceptedEvents.add(connectMessages.length);
    }
  }
}

String _timestampValue(int value) =>
    base64Encode([value & 0xff, (value >> 8) & 0xff, 0, 0, 0, 0, 0, 0]);
