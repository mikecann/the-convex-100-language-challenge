import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../convex_client.dart';

Future<void> main() async {
  await _httpSuccessAndStructuredError();
  await _liveAddUpdateRemoveAndRecovery();
  stdout.writeln('PASS Dart HTTP and Live owner tests');
}

Future<void> _httpSuccessAndStructuredError() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (decoded['path'] == 'demo:fail') {
        request.response.write(
          jsonEncode({
            'status': 'error',
            'errorMessage': 'expected failure',
            'errorData': {'code': 'TEST_EXPECTED'},
            'logLines': ['demo:fail'],
          }),
        );
      } else {
        request.response.write(
          jsonEncode({
            'status': 'success',
            'value': decoded['args'],
            'logLines': ['demo:echo'],
          }),
        );
      }
      await request.response.close();
    }),
  );
  final client = ConvexClient(
    'http://${server.address.address}:${server.port}',
  );
  final success = await client.query('demo:echo', {'text': '世界 👋'});
  _check(
    (success.value as Map)['text'] == '世界 👋',
    'HTTP should preserve UTF-8 JSON',
  );
  try {
    await client.query('demo:fail', {});
    throw StateError('expected structured error');
  } on FunctionError catch (error) {
    _check(
      (error.data as Map)['code'] == 'TEST_EXPECTED',
      'structured error data was lost',
    );
  }
  await client.close();
  await server.close(force: true);
}

Future<void> _liveAddUpdateRemoveAndRecovery() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final addSeen = Completer<void>();
  final removeSeen = Completer<void>();
  unawaited(
    server.forEach((request) async {
      if (request.uri.path != '/api/sync') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      var sawConnect = false;
      await for (final raw in socket) {
        if (!sawConnect) {
          sawConnect = true; // Connect
          continue;
        }
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final modification =
            (message['modifications'] as List).first as Map<String, dynamic>;
        final queryId = modification['queryId'] as int;
        if (modification['type'] == 'Add') {
          if (!addSeen.isCompleted) addSeen.complete();
          socket.add(
            jsonEncode(
              _transition(0, 1, 'AAAAAAAAAAA=', 'AQAAAAAAAAA=', queryId, {
                'count': 0,
              }),
            ),
          );
          // QueryFailed followed by QueryUpdated verifies recovery on one subscription.
          socket.add(
            jsonEncode(
              _failedTransition(1, 1, 'AQAAAAAAAAA=', 'AgAAAAAAAAA=', queryId),
            ),
          );
          socket.add(
            jsonEncode(
              _transition(1, 1, 'AgAAAAAAAAA=', 'AwAAAAAAAAA=', queryId, {
                'count': 1,
              }),
            ),
          );
        } else if (modification['type'] == 'Remove') {
          if (!removeSeen.isCompleted) removeSeen.complete();
          await socket.close();
          return;
        }
      }
    }),
  );
  final client = ConvexClient(
    'http://${server.address.address}:${server.port}',
  );
  final subscription = await client.subscribe('demo:state', {'room': 'unit'});
  await addSeen.future.timeout(const Duration(seconds: 2));
  final updates = await subscription.updates
      .take(3)
      .toList()
      .timeout(const Duration(seconds: 2));
  _check(
    (updates[0].value as Map)['count'] == 0,
    'initial QueryUpdated missing',
  );
  _check(
    updates[1].error is FunctionError,
    'QueryFailed must be a FunctionError',
  );
  _check(
    (updates[2].value as Map)['count'] == 1,
    'subscription did not recover after QueryFailed',
  );
  await subscription.close();
  await removeSeen.future.timeout(const Duration(seconds: 2));
  await client.close();
  await server.close(force: true);
}

Map<String, Object?> _transition(
  int startSet,
  int endSet,
  String startTs,
  String endTs,
  int id,
  Object value,
) => {
  'type': 'Transition',
  'startVersion': {'querySet': startSet, 'identity': 0, 'ts': startTs},
  'endVersion': {'querySet': endSet, 'identity': 0, 'ts': endTs},
  'modifications': [
    {'type': 'QueryUpdated', 'queryId': id, 'value': value, 'logLines': []},
  ],
};

Map<String, Object?> _failedTransition(
  int startSet,
  int endSet,
  String startTs,
  String endTs,
  int id,
) => {
  'type': 'Transition',
  'startVersion': {'querySet': startSet, 'identity': 0, 'ts': startTs},
  'endVersion': {'querySet': endSet, 'identity': 0, 'ts': endTs},
  'modifications': [
    {
      'type': 'QueryFailed',
      'queryId': id,
      'errorMessage': 'intentional',
      'errorData': {'code': 'FAILED'},
      'logLines': [],
    },
  ],
};

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
