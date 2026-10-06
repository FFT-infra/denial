import 'dart:async';

/// Per-instance asynchronous events, independent of Flutter's rebuild cadence.
/// Equality belongs to the immutable environment type, not this stream owner.
final class SurfaceEvents<T> {
  SurfaceEvents(this._current);

  T _current;
  bool _closed = false;
  final _controller = StreamController<T>.broadcast();
  late final Stream<T> stream = _controller.stream;

  void update(T next) {
    if (_closed) throw StateError('Surface events have been closed');
    if (_current == next) return;
    _current = next;
    _controller.add(next);
  }

  Future<void> close() {
    _closed = true;
    return _controller.close();
  }
}
