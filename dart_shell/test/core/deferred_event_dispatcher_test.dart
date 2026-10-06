import 'dart:collection';
import 'dart:math';

import 'package:denial_flutter_sdk/src/core/deferred_event_dispatcher.dart'
    show DeferredEventDispatcher;
import 'package:test/test.dart';

void main() {
  test('ready events dispatch immediately and empty drains do no work', () {
    final delivered = <int>[];
    var readinessChecks = 0;
    final events = DeferredEventDispatcher<int>(
      capacity: 4,
      isReady: (_) {
        readinessChecks++;
        return true;
      },
      dispatch: delivered.add,
    );
    for (var i = 0; i < 1000; i++) {
      events.add(i);
      expect(delivered.last, i);
      expect(events.length, 0);
      events.drain();
    }
    expect(readinessChecks, 1000);
  });

  test('bounded backlog retains the newest pending events', () {
    var ready = false;
    final delivered = <int>[];
    final events = DeferredEventDispatcher<int>(
      capacity: 2,
      isReady: (_) => ready,
      dispatch: delivered.add,
    );
    events.add(1);
    events.add(2);
    events.add(3);
    expect(events.length, 2);
    ready = true;
    events.drain();
    expect(delivered, [2, 3]);
    expect(events.length, 0);
  });

  test('zero capacity ignores even ready events', () {
    final events = DeferredEventDispatcher<int>(
      capacity: 0,
      isReady: (_) => throw StateError('must not inspect'),
      dispatch: (_) => throw StateError('must not dispatch'),
    );
    events.add(1);
    events.drain();
    expect(events.length, 0);
  });

  test('reentrant additions wait for a later drain', () {
    final delivered = <int>[];
    late final DeferredEventDispatcher<int> events;
    events = DeferredEventDispatcher<int>(
      capacity: 4,
      isReady: (_) => true,
      dispatch: (event) {
        delivered.add(event);
        if (event == 1) {
          events.add(2);
          events.drain();
          expect(delivered, [1]);
        }
      },
    );
    events.add(1);
    expect(delivered, [1]);
    expect(events.length, 1);
    events.drain();
    expect(delivered, [1, 2]);
  });

  test('a drain samples readiness before invoking any dispatch callback', () {
    final ready = <int>{};
    final delivered = <int>[];
    final events = DeferredEventDispatcher<int>(
      capacity: 4,
      isReady: ready.contains,
      dispatch: (event) {
        delivered.add(event);
        ready.add(2);
      },
    );
    events.add(1);
    events.add(2);
    ready.add(1);
    events.drain();
    expect(delivered, [1]);
    events.drain();
    expect(delivered, [1, 2]);
  });

  test('dispatch errors release the reentrancy guard', () {
    final delivered = <int>[];
    final events = DeferredEventDispatcher<int>(
      capacity: 4,
      isReady: (_) => true,
      dispatch: (event) {
        if (event == 1) throw StateError('failed');
        delivered.add(event);
      },
    );
    expect(() => events.add(1), throwsStateError);
    events.add(2);
    expect(delivered, [2]);
  });

  test('random readiness and overflow match the previous queued algorithm', () {
    const capacity = 23;
    final random = Random(921);
    final ready = <int>{};
    final expected = <int>[];
    final actual = <int>[];
    final reference = ListQueue<int>();
    final events = DeferredEventDispatcher<int>(
      capacity: capacity,
      isReady: ready.contains,
      dispatch: actual.add,
    );
    void drainReference() {
      final pending = reference.length;
      for (var i = 0; i < pending; i++) {
        final event = reference.removeFirst();
        if (ready.contains(event)) {
          expected.add(event);
        } else {
          reference.addLast(event);
        }
      }
    }

    for (var step = 0; step < 10000; step++) {
      switch (random.nextInt(4)) {
        case 0 || 1:
          final event = random.nextInt(50);
          if (reference.length >= capacity) reference.removeFirst();
          reference.addLast(event);
          drainReference();
          events.add(event);
        case 2:
          final id = random.nextInt(50);
          if (!ready.remove(id)) ready.add(id);
          drainReference();
          events.drain();
        case 3:
          reference.clear();
          events.clear();
      }
      expect(actual, expected, reason: 'step $step');
      expect(events.length, reference.length, reason: 'step $step');
    }
  });
}
