import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'conformance/adapter.dart'
    show SerializedAdapterOutput, parseAdapterListenAddress;

Future<void> main() async {
  final fixture = await _ConvexFixture.start();
  try {
    await _probeTcpAdapter(
      '0.0.0.0:19080',
      InternetAddress.loopbackIPv4,
      19080,
      fixture.url,
    );
  } finally {
    await fixture.close();
  }
  final ipv6 = parseAdapterListenAddress('[::1]:19081');
  if (ipv6.host != '::1' || ipv6.port != 19081) {
    throw StateError('adapter did not preserve bracketed IPv6 bind: $ipv6');
  }
  await _staleRelayCannotCrossAcknowledgement(replacement: false);
  await _staleRelayCannotCrossAcknowledgement(replacement: true);
  stdout.writeln('PASS Dart adapter wildcard IPv4/IPv6 TCP matrix');
}

Future<void> _staleRelayCannotCrossAcknowledgement({
  required bool replacement,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = Completer<Socket>();
  final listener = server.listen(accepted.complete);
  final clientFuture = Socket.connect(server.address, server.port);
  final peer = await accepted.future;
  final client = await clientFuture;
  final pausedAfterDequeue = Completer<void>();
  final resumeWrite = Completer<void>();
  final oldOwner = Object();
  Object? currentOwner = oldOwner;
  final writer = SerializedAdapterOutput(
    client,
    beforeWriteForTest: (event) async {
      if (event['type'] != 'subscription') return;
      pausedAfterDequeue.complete();
      await resumeWrite.future;
    },
  );
  writer.add({
    'type': 'subscription',
    'subscriptionId': 'same-id',
    'value': {'count': 0},
  }, guard: () => identical(currentOwner, oldOwner));
  await pausedAfterDequeue.future.timeout(const Duration(seconds: 1));
  currentOwner = replacement ? Object() : null;
  writer.add({'id': replacement ? 'replace' : 'unsubscribe', 'type': 'ack'});
  resumeWrite.complete();
  await writer.flush().timeout(const Duration(seconds: 1));

  final line = await peer
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 1));
  final event = jsonDecode(line) as Map<String, dynamic>;
  _check(
    event['type'] == 'ack' &&
        event['id'] == (replacement ? 'replace' : 'unsubscribe'),
    'stale relay crossed the ${replacement ? 'replacement' : 'unsubscribe'} acknowledgement: $event',
  );
  client.destroy();
  peer.destroy();
  await listener.cancel();
  await server.close();
}

Future<void> _probeTcpAdapter(
  String listen,
  InternetAddress connectAddress,
  int port,
  String convexUrl,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'client/tests/conformance/adapter.dart'],
    environment: {
      ...Platform.environment,
      'ADAPTER_LISTEN': listen,
      'CONVEX_URL': convexUrl,
    },
  );
  final stderrBuffer = StringBuffer();
  final listeningLine = Completer<String>();
  process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      stderrBuffer.writeln(line);
      if (!listeningLine.isCompleted && line.contains('adapter listening')) {
        listeningLine.complete(line);
      }
    },
  );
  final listening = await listeningLine.future.timeout(
    const Duration(seconds: 10),
  );
  if (!listening.contains('adapter listening')) {
    throw StateError('adapter did not listen on $listen: $listening');
  }

  final socket = await Socket.connect(
    connectAddress,
    port,
    timeout: const Duration(seconds: 3),
  );
  final events = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) => jsonDecode(line) as Map<String, dynamic>),
  );
  try {
    await _send(socket, {'protocolVersion': 1, 'id': 'hello', 'op': 'hello'});
    final ready = await _next(events);
    _check(
      ready['type'] == 'ready' &&
          ready['id'] == 'hello' &&
          ready['language'] == 'dart' &&
          ready['protocolVersion'] == 1,
      'invalid ready event on $listen: $ready',
    );

    await _send(socket, {
      'id': 'query-success',
      'op': 'query',
      'path': 'demo:echo',
      'args': {'text': 'world'},
    });
    final success = await _next(events);
    _check(
      success['type'] == 'result' &&
          success['id'] == 'query-success' &&
          (success['value'] as Map)['text'] == 'world',
      'invalid success event: $success',
    );

    await _send(socket, {
      'id': 'query-failure',
      'op': 'query',
      'path': 'demo:fail',
      'args': <String, Object?>{},
    });
    final failure = await _next(events);
    _check(
      failure['type'] == 'error' &&
          failure['id'] == 'query-failure' &&
          (failure['error'] as Map)['name'] == 'FunctionError' &&
          ((failure['error'] as Map)['data'] as Map)['code'] ==
              'EXPECTED_FAILURE',
      'invalid structured HTTP error: $failure',
    );

    await _send(socket, {
      'id': 'subscribe',
      'op': 'subscribe',
      'subscriptionId': 'live',
      'path': 'demo:state',
      'args': {'room': 'adapter'},
    });
    final subscribeAck = await _next(events);
    final liveValue = await _next(events);
    final liveFailure = await _next(events);
    _check(
      subscribeAck['type'] == 'ack' && subscribeAck['id'] == 'subscribe',
      'invalid subscribe acknowledgement: $subscribeAck',
    );
    _check(
      liveValue['type'] == 'subscription' &&
          liveValue['subscriptionId'] == 'live' &&
          (liveValue['value'] as Map)['count'] == 0 &&
          !liveValue.containsKey('id'),
      'invalid subscription value: $liveValue',
    );
    _check(
      liveFailure['type'] == 'subscription' &&
          liveFailure['subscriptionId'] == 'live' &&
          (liveFailure['error'] as Map)['name'] == 'FunctionError' &&
          !liveFailure.containsKey('id'),
      'invalid subscription error: $liveFailure',
    );

    await _send(socket, {
      'id': 'unsubscribe',
      'op': 'unsubscribe',
      'subscriptionId': 'live',
    });
    final unsubscribeAck = await _next(events);
    _check(
      unsubscribeAck['type'] == 'ack' && unsubscribeAck['id'] == 'unsubscribe',
      'invalid unsubscribe acknowledgement: $unsubscribeAck',
    );

    await _send(socket, {'id': 'close', 'op': 'close'});
    final closed = await _next(events);
    _check(
      closed['type'] == 'closed' && closed['id'] == 'close',
      'invalid close event: $closed',
    );
  } catch (error) {
    process.kill();
    throw StateError('$error\nchild stderr:\n$stderrBuffer');
  } finally {
    await events.cancel();
  }
  await socket.close();
  final exitCode = await process.exitCode.timeout(const Duration(seconds: 3));
  if (exitCode != 0) {
    throw StateError(
      'adapter on $listen exited $exitCode\nchild stderr:\n$stderrBuffer',
    );
  }
}

Future<void> _send(Socket socket, Map<String, Object?> command) async {
  socket.writeln(jsonEncode(command));
  await socket.flush();
}

Future<Map<String, dynamic>> _next(
  StreamIterator<Map<String, dynamic>> events,
) async {
  if (!await events.moveNext().timeout(const Duration(seconds: 3))) {
    throw StateError('adapter event stream ended early');
  }
  return events.current;
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _ConvexFixture {
  _ConvexFixture._(this.server);

  static Future<_ConvexFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _ConvexFixture._(server);
    unawaited(server.forEach(fixture._handle));
    return fixture;
  }

  final HttpServer server;
  final List<WebSocket> _sockets = [];

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/api/sync') {
      await _handleSync(request);
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    request.response.headers.contentType = ContentType.json;
    if (body['path'] == 'demo:fail') {
      request.response.write(
        jsonEncode({
          'status': 'error',
          'errorMessage': 'expected adapter failure',
          'errorData': {'code': 'EXPECTED_FAILURE'},
          'logLines': ['adapter failure'],
        }),
      );
    } else {
      request.response.write(
        jsonEncode({
          'status': 'success',
          'value': body['args'],
          'logLines': ['adapter success'],
        }),
      );
    }
    await request.response.close();
  }

  Future<void> _handleSync(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    var connected = false;
    await for (final raw in socket) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      if (!connected) {
        connected = true;
        continue;
      }
      if (message['type'] != 'ModifyQuerySet') continue;
      final modification =
          (message['modifications'] as List).first as Map<String, dynamic>;
      if (modification['type'] != 'Add') continue;
      final queryId = modification['queryId'] as int;
      socket.add(
        jsonEncode(
          _transition(0, 1, 'AAAAAAAAAAA=', 'AQAAAAAAAAA=', queryId, {
            'type': 'QueryUpdated',
            'value': {'count': 0},
          }),
        ),
      );
      socket.add(
        jsonEncode(
          _transition(1, 1, 'AQAAAAAAAAA=', 'AgAAAAAAAAA=', queryId, {
            'type': 'QueryFailed',
            'errorMessage': 'expected subscription failure',
            'errorData': {'code': 'EXPECTED_SUBSCRIPTION_FAILURE'},
          }),
        ),
      );
    }
  }
}

Map<String, Object?> _transition(
  int startSet,
  int endSet,
  String startTimestamp,
  String endTimestamp,
  int queryId,
  Map<String, Object?> modification,
) => {
  'type': 'Transition',
  'startVersion': {'querySet': startSet, 'identity': 0, 'ts': startTimestamp},
  'endVersion': {'querySet': endSet, 'identity': 0, 'ts': endTimestamp},
  'modifications': [
    {...modification, 'queryId': queryId, 'logLines': <String>[]},
  ],
};
