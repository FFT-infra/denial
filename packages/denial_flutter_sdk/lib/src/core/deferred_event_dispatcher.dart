import 'dart:collection';

/// Dispatches ready events synchronously and bounds the deferred backlog.
///
/// Ready events bypass queueing when the backlog is empty. During a drain,
/// readiness is sampled before dispatch, so callbacks cannot change which
/// events belong to that batch. Reentrant events wait for the next drain.
final class DeferredEventDispatcher<Event> {
  DeferredEventDispatcher({
    required this.capacity,
    required this._isReady,
    required this._dispatch,
  }) : assert(capacity >= 0);

  final int capacity;
  final bool Function(Event) _isReady;
  final void Function(Event) _dispatch;
  final _events = ListQueue<Event>();
  bool _processing = false;

  int get length => _events.length;

  void add(Event event) {
    if (capacity <= 0) return;
    if (!_processing && _events.isEmpty) {
      _processing = true;
      try {
        if (_isReady(event)) {
          _dispatch(event);
        } else {
          _enqueue(event);
        }
      } finally {
        _processing = false;
      }
      return;
    }
    _enqueue(event);
    drain();
  }

  void _enqueue(Event event) {
    if (_events.length >= capacity) _events.removeFirst();
    _events.addLast(event);
  }

  void drain() {
    if (_processing || _events.isEmpty) return;
    _processing = true;
    try {
      final ready = <Event>[];
      final pending = _events.length;
      for (var index = 0; index < pending; index++) {
        final event = _events.removeFirst();
        if (_isReady(event)) {
          ready.add(event);
        } else {
          _events.addLast(event);
        }
      }
      for (final event in ready) {
        _dispatch(event);
      }
    } finally {
      _processing = false;
    }
  }

  void clear() => _events.clear();
}
