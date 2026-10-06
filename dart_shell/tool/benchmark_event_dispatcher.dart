import 'package:denial_flutter_sdk/lifecycle.dart' show DeferredEventDispatcher;

// Compile with the pinned Dart SDK, then run the resulting AOT executable:
// dart compile exe tool/benchmark_event_dispatcher.dart -o /tmp/events-bench
// /tmp/events-bench
import 'dart:collection';
import 'dart:io';

int _sum = 0;
bool _ready(int event) => true;
void _dispatch(int event) => _sum += event;

void main() {
  final previous = _QueuedDispatcher();
  final current = DeferredEventDispatcher<int>(
    capacity: 4096,
    isReady: _ready,
    dispatch: _dispatch,
  );
  const iterations = 1000000;
  _measure(previous.add, iterations ~/ 10);
  _measure(current.add, iterations ~/ 10);
  final before = <double>[];
  final after = <double>[];
  for (var sample = 0; sample < 7; sample++) {
    if (sample.isEven) {
      before.add(_measure(previous.add, iterations));
      after.add(_measure(current.add, iterations));
    } else {
      after.add(_measure(current.add, iterations));
      before.add(_measure(previous.add, iterations));
    }
  }
  before.sort();
  after.sort();
  stdout.writeln('Ready-event dispatch, median of 7 AOT samples:');
  stdout.writeln(
    '${before[3].toStringAsFixed(2)} -> ${after[3].toStringAsFixed(2)} ns/event',
  );
  stdout.writeln(
    '${(before[3] / after[3]).toStringAsFixed(2)}x; checksum=$_sum',
  );
}

double _measure(void Function(int) add, int count) {
  final clock = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    add(i);
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}

// Previous coordinator behavior: enqueue, collect a ready batch, dispatch.
class _QueuedDispatcher {
  final _events = ListQueue<int>();
  bool _draining = false;

  void add(int event) {
    if (_events.length >= 4096) _events.removeFirst();
    _events.addLast(event);
    if (_draining) return;
    _draining = true;
    try {
      final ready = <int>[];
      final pending = _events.length;
      for (var index = 0; index < pending; index++) {
        final event = _events.removeFirst();
        if (_ready(event)) {
          ready.add(event);
        } else {
          _events.addLast(event);
        }
      }
      for (final event in ready) {
        _dispatch(event);
      }
    } finally {
      _draining = false;
    }
  }
}
