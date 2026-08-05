import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../convex_client.dart';

const _deadline = Duration(seconds: 1);

Future<void> main() async {
  await _stalledUpgradeCanBeInterrupted();
  await _idlePeerHasBoundedLifecycle();
  await _continuousPeerHasBoundedLifecycle();
  stdout.writeln('PASS Dart stalled/idle/continuous lifecycle deadlines');
}

Future<void> _stalledUpgradeCanBeInterrupted() async {
  final fixture = await _StalledUpgradeFixture.start();
  try {
    final queuedClient = ConvexClient(fixture.url);
    await queuedClient.subscribe('demo:state', {'room': 'queued-close'});
    // This can run before the zero-delay reconnect task creates its concrete
    // attempt, so it covers the queued-upgrade cancellation epoch too.
    await _within('close before queued upgrade starts', queuedClient.close());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (fixture.acceptedCount != 0) {
      throw StateError('cancelled queued upgrade still reached the peer');
    }

    final closeClient = ConvexClient(fixture.url);
    final closeAccepted = fixture.nextConnection();
    await closeClient.subscribe('demo:state', {'room': 'stalled-close'});
    final closeSocket = await closeAccepted.timeout(_deadline);
    await _within('close behind stalled upgrade', closeClient.close());
    await fixture.waitForClosed(closeSocket).timeout(_deadline);

    final unsubscribeClient = ConvexClient(fixture.url);
    final unsubscribeAccepted = fixture.nextConnection();
    final subscription = await unsubscribeClient.subscribe('demo:state', {
      'room': 'stalled-unsubscribe',
    });
    final unsubscribeSocket = await unsubscribeAccepted.timeout(_deadline);
    await _within('unsubscribe behind stalled upgrade', subscription.close());
    await fixture.waitForClosed(unsubscribeSocket).timeout(_deadline);
    await _within(
      'close after interrupted unsubscribe',
      unsubscribeClient.close(),
    );
  } finally {
    await fixture.close();
  }
}

Future<void> _idlePeerHasBoundedLifecycle() async {
  final fixture = await _WebSocketLifecycleFixture.start(continuous: false);
  await _exerciseEstablishedPeer(fixture, 'idle');
}

Future<void> _continuousPeerHasBoundedLifecycle() async {
  final fixture = await _WebSocketLifecycleFixture.start(continuous: true);
  await _exerciseEstablishedPeer(fixture, 'continuous');
}

Future<void> _exerciseEstablishedPeer(
  _WebSocketLifecycleFixture fixture,
  String label,
) async {
  final client = ConvexClient(fixture.url);
  final subscription = await client.subscribe('demo:state', {'room': label});
  try {
    await fixture.addSeen.future.timeout(_deadline);
    await _within('$label peer unsubscribe', subscription.close());
    await fixture.removeSeen.future.timeout(_deadline);
    // The fixture deliberately stays idle or keeps sending after Remove, so
    // close cannot rely on a cooperative peer handshake.
    await _within('$label peer close', client.close());
  } finally {
    await client.close();
    await fixture.close();
  }
}

Future<void> _within(String label, Future<void> operation) async {
  final watch = Stopwatch()..start();
  await operation.timeout(_deadline);
  watch.stop();
  if (watch.elapsed >= _deadline) {
    throw StateError('$label exceeded $_deadline: ${watch.elapsed}');
  }
}

class _StalledUpgradeFixture {
  _StalledUpgradeFixture._(this.server, this.listener);

  static Future<_StalledUpgradeFixture> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    late final _StalledUpgradeFixture fixture;
    late final StreamSubscription<Socket> listener;
    listener = server.listen((socket) => fixture._accept(socket));
    fixture = _StalledUpgradeFixture._(server, listener);
    return fixture;
  }

  final ServerSocket server;
  final StreamSubscription<Socket> listener;
  final List<Socket> _sockets = [];
  final List<Completer<Socket>> _waiters = [];
  final List<Socket> _accepted = [];
  final Map<Socket, Completer<void>> _closed = {};

  String get url => 'http://${server.address.address}:${server.port}';

  int get acceptedCount => _sockets.length;

  Future<Socket> nextConnection() {
    if (_accepted.isNotEmpty) return Future.value(_accepted.removeAt(0));
    final waiter = Completer<Socket>();
    _waiters.add(waiter);
    return waiter.future;
  }

  Future<void> waitForClosed(Socket socket) => _closed[socket]!.future;

  void _accept(Socket socket) {
    _sockets.add(socket);
    final closed = Completer<void>();
    _closed[socket] = closed;
    socket.listen(
      (_) {},
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: true,
    );
    // Never answer the HTTP Upgrade request. The client must cancel its own
    // pending handshake rather than waiting for this peer.
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(socket);
    } else {
      _accepted.add(socket);
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await server.close();
  }
}

class _WebSocketLifecycleFixture {
  _WebSocketLifecycleFixture._(this.server, this.continuous);

  static Future<_WebSocketLifecycleFixture> start({
    required bool continuous,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _WebSocketLifecycleFixture._(server, continuous);
    unawaited(server.forEach(fixture._handle));
    return fixture;
  }

  final HttpServer server;
  final bool continuous;
  final Completer<void> addSeen = Completer<void>();
  final Completer<void> removeSeen = Completer<void>();
  final List<WebSocket> _sockets = [];
  final List<Timer> _senders = [];

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> _handle(HttpRequest request) async {
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
      for (final rawModification in message['modifications'] as List) {
        final modification = rawModification as Map<String, dynamic>;
        if (modification['type'] == 'Add') {
          if (!addSeen.isCompleted) addSeen.complete();
          if (continuous && _senders.isEmpty) {
            _senders.add(
              Timer.periodic(const Duration(milliseconds: 1), (_) {
                if (socket.readyState == WebSocket.open) {
                  socket.add('{"type":"Ping"}');
                }
              }),
            );
          }
        } else if (modification['type'] == 'Remove') {
          if (!removeSeen.isCompleted) removeSeen.complete();
        }
      }
    }
  }

  Future<void> close() async {
    for (final sender in _senders) {
      sender.cancel();
    }
    for (final socket in _sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}
