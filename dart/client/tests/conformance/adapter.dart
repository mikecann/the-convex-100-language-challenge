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
  final address = parseAdapterListenAddress(listen);
  final server = await ServerSocket.bind(address.host, address.port);
  stderr.writeln(
    'adapter listening on ${server.address.address}:${server.port}',
  );
  try {
    // Keep the listening subscription alive while the one controller socket is
    // in use. `server.first` cancels its subscription as soon as it yields and
    // can reset the accepted socket on some Dart runtimes.
    await for (final socket in server) {
      try {
        await _Adapter(socket, socket).run();
      } finally {
        socket.destroy();
      }
      break;
    }
  } finally {
    await server.close();
  }
}

({String host, int port}) parseAdapterListenAddress(String value) {
  final bracketed = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(value);
  if (bracketed != null) {
    return (host: bracketed.group(1)!, port: int.parse(bracketed.group(2)!));
  }
  final split = value.lastIndexOf(':');
  if (split < 1)
    throw FormatException('ADAPTER_LISTEN must be host:port, got $value');
  return (
    host: value.substring(0, split),
    port: int.parse(value.substring(split + 1)),
  );
}

class _Adapter {
  _Adapter(this._input, IOSink output)
    : _events = SerializedAdapterOutput(output);

  final Stream<List<int>> _input;
  final SerializedAdapterOutput _events;
  final Map<String, LiveSubscription> _subscriptions = {};
  final Map<String, Object> _relayOwners = {};
  final Map<String, StreamSubscription<LiveUpdate>> _relayListeners = {};
  ConvexClient? _client;

  Future<void> run() async {
    await for (final line in _input
        .cast<List<int>>()
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
          await _removeSubscription(subscriptionId);
          final subscription = await _ensureClient().subscribe(
            _path(command),
            _args(command),
          );
          _subscriptions[subscriptionId] = subscription;
          _startRelay(subscriptionId, subscription);
          _event({'id': id, 'type': 'ack'});
        case 'unsubscribe':
          await _removeSubscription(
            command['subscriptionId']?.toString() ?? '',
          );
          _event({'id': id, 'type': 'ack'});
        case 'debugDisconnect':
          await _ensureClient().debugDisconnectForAdapter();
          _event({'id': id, 'type': 'ack'});
        case 'close':
          for (final subscriptionId in _subscriptions.keys.toList()) {
            await _removeSubscription(subscriptionId);
          }
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

  void _startRelay(String id, LiveSubscription subscription) {
    final owner = Object();
    _relayOwners[id] = owner;
    _relayListeners[id] = subscription.updates.listen((update) {
      bool ownsRelay() => identical(_relayOwners[id], owner);
      if (update.error != null) {
        _failure('', id, update.error!, guard: ownsRelay);
      } else {
        _event({
          'type': 'subscription',
          'subscriptionId': id,
          'value': update.value,
          if (update.logs.isNotEmpty) 'logs': update.logs,
        }, guard: ownsRelay);
      }
    });
  }

  Future<void> _removeSubscription(String id) async {
    // Revoke ownership before waiting for either stream cancellation or the
    // client Remove command. A queued output callback rechecks this token.
    _relayOwners.remove(id);
    await _relayListeners.remove(id)?.cancel();
    await _subscriptions.remove(id)?.close();
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

  void _failure(
    String id,
    String? subscriptionId,
    Object error, {
    bool Function()? guard,
  }) {
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
    }, guard: guard);
  }

  Map<String, Object?> _error(String name, String message, [Object? data]) => {
    'name': name,
    'message': message,
    if (data != null) 'data': data,
  };

  void _event(Map<String, Object?> event, {bool Function()? guard}) {
    _events.add(event, guard: guard);
  }

  Future<void> _flush() => _events.flush();
}

/// Serializes adapter events and checks relay ownership at the last possible
/// moment. The hook exists only for deterministic conformance-executable tests
/// which pause an event after dequeue and reproduce stale relay races.
class SerializedAdapterOutput {
  SerializedAdapterOutput(this._output, {this.beforeWriteForTest});

  final IOSink _output;
  final Future<void> Function(Map<String, Object?> event)? beforeWriteForTest;
  Future<void> _tail = Future.value();

  void add(Map<String, Object?> event, {bool Function()? guard}) {
    _tail = _tail.then((_) async {
      await beforeWriteForTest?.call(event);
      if (guard != null && !guard()) return;
      _output.writeln(jsonEncode(event));
      await _output.flush();
    });
  }

  Future<void> flush() => _tail;
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
