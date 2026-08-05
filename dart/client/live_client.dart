library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'convex_client.dart';
import 'delivery_queue.dart';

const _initialTimestamp = 'AAAAAAAAAAA=';
const _initialBackoff = Duration(milliseconds: 100);
const _maximumBackoff = Duration(seconds: 15);

/// A current query value or a query failure delivered by Convex Live.
class LiveUpdate {
  const LiveUpdate.value(this.value, this.logs) : error = null;
  const LiveUpdate.failure(this.error, this.logs) : value = null;

  final Object? value;
  final ConvexError? error;
  final List<String> logs;
}

/// A reactive query handle. The owner serializes state changes, and a bounded
/// newest-16 relay stops a slow consumer from stopping socket processing.
class LiveSubscription {
  LiveSubscription._(this._owner, this._queryId, this._state);

  final LiveClient _owner;
  final int _queryId;
  final _SubscriptionState _state;
  bool _closed = false;

  Stream<LiveUpdate> get updates => _state.relay.stream;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _owner.unsubscribe(_queryId);
  }
}

/// A single-owner state machine. Socket reads only enqueue events; this class
/// alone creates sockets, writes frames, reconnects, and changes query sets.
class LiveClient {
  LiveClient(Uri deploymentUri, this._clientVersion)
    : _syncUri = deploymentUri.replace(
        scheme: deploymentUri.scheme == 'https' ? 'wss' : 'ws',
        path: '${deploymentUri.path}/api/sync',
      );

  final Uri _syncUri;
  final String _clientVersion;
  final Map<int, _SubscriptionState> _active = {};
  final Map<int, LiveUpdate> _remoteResults = {};
  Future<void> _tail = Future.value();
  WebSocket? _socket;
  Timer? _reconnectTimer;
  int _nextQueryId = 0;
  int _querySetVersion = 0;
  int _generation = 0;
  int _connectionCount = 0;
  String _lastCloseReason = 'InitialConnect';
  String _maxObservedTimestamp = '';
  _Version _remoteVersion = const _Version(0, 0, _initialTimestamp);
  Duration _nextBackoff = _initialBackoff;
  bool _closed = false;

  Future<LiveSubscription> subscribe(String path, Map<String, Object?> args) {
    final completer = Completer<LiveSubscription>();
    _enqueue(() async {
      if (_closed) return completer.completeError(const ClientClosedError());
      final queryId = _nextQueryId++;
      final state = _SubscriptionState(queryId, path, args);
      _active[queryId] = state;
      completer.complete(LiveSubscription._(this, queryId, state));
      if (_socket == null) {
        _scheduleReconnect(Duration.zero);
      } else {
        await _modify([state.addModification], 'subscribe');
      }
    });
    return completer.future;
  }

  Future<void> unsubscribe(int queryId) {
    final completer = Completer<void>();
    _enqueue(() async {
      final state = _active.remove(queryId);
      // Invalidate and close before acknowledging. An old socket event that was
      // already queued cannot look the state up and therefore cannot relay.
      _remoteResults.remove(queryId);
      state?.close();
      if (state != null && _socket != null) {
        await _modify([
          {'type': 'Remove', 'queryId': queryId},
        ], 'unsubscribe');
      }
      if (_active.isEmpty) _cancelReconnect();
      completer.complete();
    });
    return completer.future;
  }

  Future<void> debugDisconnect() {
    final completer = Completer<void>();
    _enqueue(() async {
      if (_socket == null) {
        return completer.completeError(
          const ProtocolError('Live WebSocket is not connected'),
        );
      }
      // Retire the old transport and schedule the replacement before the test
      // adapter sends its acknowledgement. This preserves reconnect ordering.
      await _closeConnection('DebugDisconnect', reconnect: true);
      completer.complete();
    });
    return completer.future;
  }

  Future<void> close() {
    final completer = Completer<void>();
    _enqueue(() async {
      if (_closed) return completer.complete();
      _closed = true;
      _cancelReconnect();
      final socket = _socket;
      _socket = null;
      // Dart exposes a close handshake but no raw destroy operation. Retiring
      // ownership first means a peer stalled mid-frame cannot block shutdown.
      if (socket != null) {
        unawaited(socket.close(WebSocketStatus.normalClosure, 'client closed'));
      }
      for (final state in _active.values) {
        state.close();
      }
      _active.clear();
      completer.complete();
    });
    return completer.future;
  }

  void _enqueue(Future<void> Function() task) {
    _tail = _tail.then((_) => task()).catchError((
      Object error,
      StackTrace stack,
    ) {
      stderr.writeln('dart Live owner error: $error');
    });
  }

  void _scheduleReconnect(Duration delay) {
    if (_closed || _active.isEmpty) return;
    _cancelReconnect();
    _reconnectTimer = Timer(delay, () {
      _enqueue(() async {
        _reconnectTimer = null;
        if (_socket != null || _closed || _active.isEmpty) return;
        await _connect();
      });
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> _connect() async {
    try {
      final socket = await WebSocket.connect(
        _syncUri.toString(),
        headers: {'Convex-Client': _clientVersion},
      ).timeout(const Duration(seconds: 10));
      _socket = socket;
      _generation += 1;
      final generation = _generation;
      _querySetVersion = 0;
      _remoteVersion = const _Version(0, 0, _initialTimestamp);
      _remoteResults.clear();
      socket.listen(
        (Object? message) => _enqueue(() => _onMessage(generation, message)),
        onError:
            (Object error, StackTrace stack) =>
                _enqueue(() => _onSocketError(generation, error)),
        onDone:
            () => _enqueue(() => _onSocketError(generation, 'socket closed')),
        cancelOnError: true,
      );
      _write({
        'type': 'Connect',
        'sessionId': _sessionId(),
        'connectionCount': _connectionCount,
        'lastCloseReason': _lastCloseReason,
        // The initial value is absent, not an empty string. The sync protocol
        // encodes a real observed timestamp as eight base64 bytes.
        if (_maxObservedTimestamp.isNotEmpty)
          'maxObservedTimestamp': _maxObservedTimestamp,
        'clientTs': 0,
      });
      final additions = _active.values
          .map((state) => state.addModification)
          .toList(growable: false);
      if (additions.isNotEmpty) await _modify(additions, 'connect');
    } catch (error) {
      final transport = TransportError('live connect', error.toString());
      _publishFailure(transport);
      _lastCloseReason = transport.message;
      _connectionCount += 1;
      _scheduleReconnect(_nextBackoff);
      _nextBackoff = _doubleBackoff(_nextBackoff);
    }
  }

  Future<void> _modify(
    List<Map<String, Object?>> modifications,
    String operation,
  ) async {
    try {
      _write({
        'type': 'ModifyQuerySet',
        'baseVersion': _querySetVersion,
        'newVersion': _querySetVersion + 1,
        'modifications': modifications,
      });
      _querySetVersion += 1;
    } catch (error) {
      await _closeConnection('$operation: $error', reconnect: true);
    }
  }

  void _write(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null)
      throw const TransportError('live write', 'WebSocket is not connected');
    socket.add(jsonEncode(message));
  }

  Future<void> _onSocketError(int generation, Object error) async {
    if (generation != _generation || _socket == null || _closed) return;
    final transport = TransportError('live connection', error.toString());
    _publishFailure(transport);
    await _closeConnection(transport.message, reconnect: true);
  }

  Future<void> _closeConnection(
    String reason, {
    required bool reconnect,
  }) async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      _connectionCount += 1;
      unawaited(socket.close(WebSocketStatus.normalClosure, reason));
    }
    _lastCloseReason = reason;
    _querySetVersion = 0;
    _remoteVersion = const _Version(0, 0, _initialTimestamp);
    _remoteResults.clear();
    if (reconnect && !_closed && _active.isNotEmpty) {
      _scheduleReconnect(_nextBackoff);
      _nextBackoff = _doubleBackoff(_nextBackoff);
    }
  }

  Future<void> _onMessage(int generation, Object? message) async {
    if (generation != _generation || _socket == null || _closed) return;
    try {
      final decoded = jsonDecode(
        message is String ? message : utf8.decode(message as List<int>),
      );
      if (decoded is! Map<String, dynamic>)
        throw const ProtocolError('sync message was not an object');
      switch (decoded['type']) {
        case 'Transition':
          _handleTransition(decoded);
          _nextBackoff = _initialBackoff;
        case 'Ping':
        case 'MutationResponse':
        case 'ActionResponse':
          // Reset only after a recognized, successfully decoded server message.
          _nextBackoff = _initialBackoff;
          break;
        case 'FatalError':
        case 'AuthError':
          throw ProtocolError('${decoded['type']}: ${decoded['error'] ?? ''}');
        case 'TransitionChunk':
          throw const ProtocolError(
            'TransitionChunk assembly is deferred by this educational client',
          );
        default:
          throw ProtocolError('unknown sync message ${decoded['type']}');
      }
    } on ConvexError catch (error) {
      _publishFailure(error);
      await _closeConnection(error.toString(), reconnect: true);
    } catch (error) {
      final protocol = ProtocolError('decode sync message: $error');
      _publishFailure(protocol);
      await _closeConnection(protocol.toString(), reconnect: true);
    }
  }

  void _handleTransition(Map<String, dynamic> message) {
    final start = _Version.fromJson(message['startVersion']);
    final end = _Version.fromJson(message['endVersion']);
    if (start != _remoteVersion) {
      throw ProtocolError(
        'Transition start version $start did not match local $_remoteVersion',
      );
    }
    final changed = <int, LiveUpdate>{};
    final modifications = message['modifications'];
    if (modifications is! List)
      throw const ProtocolError('Transition omitted modifications');
    for (final item in modifications) {
      if (item is! Map<String, dynamic> || item['queryId'] is! int) {
        throw const ProtocolError('Transition modification was malformed');
      }
      final id = item['queryId'] as int;
      switch (item['type']) {
        case 'QueryUpdated':
          if (!item.containsKey('value')) {
            throw const ProtocolError('QueryUpdated omitted value');
          }
          final update = LiveUpdate.value(
            item['value'],
            _logs(item['logLines']),
          );
          _remoteResults[id] = update;
          changed[id] = update;
        case 'QueryFailed':
          final failure = FunctionError(
            operation: 'query',
            message: item['errorMessage']?.toString() ?? 'Live query failed',
            data: item['errorData'],
            logs: _logs(item['logLines']),
          );
          final update = LiveUpdate.failure(failure, failure.logs);
          _remoteResults[id] = update;
          changed[id] = update;
        case 'QueryRemoved':
          _remoteResults.remove(id);
        default:
          throw ProtocolError(
            'unknown Transition modification ${item['type']}',
          );
      }
    }
    // Commit the full state before any relay runs, so one transition cannot
    // expose a half-updated multi-query view.
    _remoteVersion = end;
    _maxObservedTimestamp = end.timestamp;
    for (final entry in changed.entries) {
      final state = _active[entry.key];
      if (state != null && state.shouldDeliver(entry.value)) {
        state.add(entry.value);
      }
    }
  }

  void _publishFailure(ConvexError error) {
    for (final state in _active.values) {
      final update = LiveUpdate.failure(error, const []);
      if (state.shouldDeliver(update)) state.add(update);
    }
  }
}

class _SubscriptionState {
  _SubscriptionState(this.queryId, this.path, this.args);

  final int queryId;
  final String path;
  final Map<String, Object?> args;
  final BoundedLiveRelay<LiveUpdate> relay = BoundedLiveRelay();
  Object? _lastValue;
  bool _hasLastValue = false;
  bool _lastWasFailure = false;
  bool _closed = false;

  Map<String, Object?> get addModification => {
    'type': 'Add',
    'queryId': queryId,
    'udfPath': path,
    'args': [args],
  };

  void add(LiveUpdate update) {
    if (_closed) return;
    relay.add(update);
  }

  bool shouldDeliver(LiveUpdate update) {
    if (update.error != null) {
      _lastWasFailure = true;
      return true;
    }
    final duplicate =
        _hasLastValue &&
        !_lastWasFailure &&
        _jsonEqual(_lastValue, update.value);
    _lastValue = update.value;
    _hasLastValue = true;
    _lastWasFailure = false;
    return !duplicate;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    relay.close();
  }
}

bool _jsonEqual(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonEqual(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) || !_jsonEqual(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  return false;
}

class _Version {
  const _Version(this.querySet, this.identity, this.timestamp);

  factory _Version.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['querySet'] is! int ||
        value['identity'] is! int ||
        value['ts'] is! String) {
      throw const ProtocolError('invalid state version');
    }
    return _Version(
      value['querySet'] as int,
      value['identity'] as int,
      value['ts'] as String,
    );
  }

  final int querySet;
  final int identity;
  final String timestamp;

  @override
  bool operator ==(Object other) =>
      other is _Version &&
      querySet == other.querySet &&
      identity == other.identity &&
      timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(querySet, identity, timestamp);

  @override
  String toString() => '($querySet, $identity, $timestamp)';
}

Duration _doubleBackoff(Duration value) {
  final milliseconds = min(
    value.inMilliseconds * 2,
    _maximumBackoff.inMilliseconds,
  );
  return Duration(milliseconds: milliseconds);
}

List<String> _logs(Object? value) =>
    value is List
        ? value.whereType<String>().toList(growable: false)
        : const [];

String _sessionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
