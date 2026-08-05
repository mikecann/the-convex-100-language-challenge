/// Test-only NDJSON adapter. This is deliberately separate from the small
/// educational client API and is the only caller of debugDisconnectForAdapter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../convex_client.dart';
import '../../live_client.dart';

const _protocolVersion = 1;

Future<void> main() async {
  final listen = Platform.environment['ADAPTER_LISTEN'];
  if (listen == null || listen.isEmpty) {
    await _Adapter(stdin, stdout).run();
    return;
  }
  final address = _parseListenAddress(listen);
  final server = await ServerSocket.bind(address.host, address.port);
  stderr.writeln(
    'adapter listening on ${server.address.address}:${server.port}',
  );
  try {
    final socket = await server.first;
    await _Adapter(socket, socket).run();
  } finally {
    await server.close();
  }
}

InternetAddress _localhostFor(String host) =>
    host == '::1' ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4;

({InternetAddress host, int port}) _parseListenAddress(String value) {
  final bracketed = RegExp(r'^\[([^]]+)]:(\d+)$').firstMatch(value);
  if (bracketed != null) {
    return (
      host: _localhostFor(bracketed.group(1)!),
      port: int.parse(bracketed.group(2)!),
    );
  }
  final split = value.lastIndexOf(':');
  if (split < 1)
    throw FormatException('ADAPTER_LISTEN must be host:port, got $value');
  return (
    host: _localhostFor(value.substring(0, split)),
    port: int.parse(value.substring(split + 1)),
  );
}

class _Adapter {
  _Adapter(this._input, this._output);

  final Stream<List<int>> _input;
  final IOSink _output;
  final Map<String, LiveSubscription> _subscriptions = {};
  Future<void> _outputTail = Future.value();
  ConvexClient? _client;

  Future<void> run() async {
    await for (final line in _input
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      try {
        final command = jsonDecode(line);
        if (command is! Map<String, dynamic>)
          throw const FormatException('command was not an object');
        final shouldClose = await _handle(command);
        if (shouldClose) return;
      } catch (error) {
        _event({
          'type': 'error',
          'error': _error('ProtocolError', error.toString()),
        });
      }
    }
    // stdin mode can end without a close command during a manual probe. Flush
    // responses already queued for stdout before the process exits.
    await _flush();
  }

  Future<bool> _handle(Map<String, dynamic> command) async {
    final id = command['id']?.toString() ?? '';
    final operation = command['op']?.toString() ?? '';
    try {
      switch (operation) {
        case 'hello':
          if (command['protocolVersion'] != _protocolVersion) {
            throw ProtocolError(
              'unsupported adapter protocol ${command['protocolVersion']}',
            );
          }
          _event({
            'protocolVersion': _protocolVersion,
            'id': id,
            'type': 'ready',
            'language': 'dart',
            'implementation':
                'native-dart-${Platform.version.split(' ').first}',
            'runtime': Platform.version,
          });
        case 'query':
        case 'mutation':
        case 'action':
          final client = _ensureClient();
          final result = switch (operation) {
            'query' => await client.query(_path(command), _args(command)),
            'mutation' => await client.mutation(_path(command), _args(command)),
            _ => await client.action(_path(command), _args(command)),
          };
          _event({
            'id': id,
            'type': 'result',
            'value': result.value,
            if (result.logs.isNotEmpty) 'logs': result.logs,
          });
        case 'setAuth':
          _ensureClient().setAuth(command['token']?.toString() ?? '');
          _event({'id': id, 'type': 'ack'});
        case 'subscribe':
          final subscriptionId = _required(command, 'subscriptionId');
          // Replace invalidates the old relay before this acknowledgement. The
          // old stream's pending values are discarded by LiveSubscription.close.
          await _subscriptions.remove(subscriptionId)?.close();
          final subscription = await _ensureClient().subscribe(
            _path(command),
            _args(command),
          );
          _subscriptions[subscriptionId] = subscription;
          _relay(subscriptionId, subscription);
          _event({'id': id, 'type': 'ack'});
        case 'unsubscribe':
          await _subscriptions
              .remove(command['subscriptionId']?.toString())
              ?.close();
          _event({'id': id, 'type': 'ack'});
        case 'debugDisconnect':
          await _ensureClient().debugDisconnectForAdapter();
          _event({'id': id, 'type': 'ack'});
        case 'close':
          for (final subscription in _subscriptions.values) {
            await subscription.close();
          }
          _subscriptions.clear();
          await _client?.close();
          _event({'id': id, 'type': 'closed'});
          await _flush();
          return true;
        default:
          throw ProtocolError('unknown operation $operation');
      }
    } catch (error) {
      _failure(id, null, error);
    }
    return false;
  }

  void _relay(String id, LiveSubscription subscription) {
    subscription.updates.listen((update) {
      // Replacement and unsubscribe remove the exact subscription before this
      // callback can write. That makes queued stale relays harmless.
      if (!identical(_subscriptions[id], subscription)) return;
      if (update.error != null) {
        _failure('', id, update.error!);
      } else {
        _event({
          'type': 'subscription',
          'subscriptionId': id,
          'value': update.value,
          if (update.logs.isNotEmpty) 'logs': update.logs,
        });
      }
    });
  }

  ConvexClient _ensureClient() {
    if (_client != null) return _client!;
    final url = Platform.environment['CONVEX_URL'];
    if (url == null || url.isEmpty)
      throw const ProtocolError('CONVEX_URL is required');
    _client = ConvexClient(url);
    final token = Platform.environment['CONVEX_AUTH_TOKEN'];
    if (token != null && token.isNotEmpty) _client!.setAuth(token);
    return _client!;
  }

  void _failure(String id, String? subscriptionId, Object error) {
    final kind = switch (error) {
      FunctionError() => 'FunctionError',
      TransportError() => 'TransportError',
      ProtocolError() => 'ProtocolError',
      _ => 'Error',
    };
    final message = error is ConvexError ? error.message : error.toString();
    final data = error is FunctionError ? error.data : null;
    _event({
      if (subscriptionId == null) 'id': id,
      'type': subscriptionId == null ? 'error' : 'subscription',
      if (subscriptionId != null) 'subscriptionId': subscriptionId,
      'error': _error(kind, message, data),
      if (error is FunctionError && error.logs.isNotEmpty) 'logs': error.logs,
    });
  }

  Map<String, Object?> _error(String name, String message, [Object? data]) => {
    'name': name,
    'message': message,
    if (data != null) 'data': data,
  };

  void _event(Map<String, Object?> event) {
    _outputTail = _outputTail.then((_) async {
      _output.writeln(jsonEncode(event));
      await _output.flush();
    });
  }

  Future<void> _flush() => _outputTail;
}

String _required(Map<String, dynamic> command, String key) {
  final value = command[key]?.toString() ?? '';
  if (value.isEmpty) throw ProtocolError('$key is required');
  return value;
}

String _path(Map<String, dynamic> command) => _required(command, 'path');

Map<String, Object?> _args(Map<String, dynamic> command) {
  final value = command['args'];
  if (value == null) return {};
  if (value is! Map)
    throw const ProtocolError('Convex arguments must be a named JSON object');
  return value.map((key, value) => MapEntry(key.toString(), value));
}
