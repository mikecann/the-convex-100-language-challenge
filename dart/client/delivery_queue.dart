import 'dart:async';

/// Internal single-listener relay used by Live subscriptions.
///
/// Dart's ordinary asynchronous StreamController buffers without a limit.
/// This relay keeps at most [capacity] values before a listener attaches or
/// while that listener is paused, discarding the oldest value first.
class BoundedLiveRelay<T> {
  BoundedLiveRelay({this.capacity = 16}) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
    _controller = StreamController<T>(
      sync: true,
      onListen: _resume,
      onPause: _pause,
      onResume: _resume,
      onCancel: () {
        _listening = false;
        _paused = true;
      },
    );
  }

  final int capacity;
  late final StreamController<T> _controller;
  final List<T> _pending = [];
  bool _listening = false;
  bool _paused = true;
  bool _closed = false;

  Stream<T> get stream => _controller.stream;

  int get pendingLength => _pending.length;

  void add(T value) {
    if (_closed) return;
    if (_pending.length == capacity) _pending.removeAt(0);
    _pending.add(value);
    _drain();
  }

  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;
    _pending.clear();
    return _controller.close();
  }

  void _pause() {
    _paused = true;
  }

  void _resume() {
    _listening = true;
    _paused = false;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    if (_closed || !_listening || _paused) return;
    while (_pending.isNotEmpty && !_paused && !_closed) {
      _controller.add(_pending.removeAt(0));
    }
  }
}
