import 'package:denial_flutter_sdk/src/state/desktop_notification_reducer.dart'
    show DesktopNotificationReducer;

import 'dart:io';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../test/support/legacy_notification_reducer.dart';
import '../test/support/notification_event_fixtures.dart';

typedef _Apply = ({DesktopNotificationsState state, int? evictedId}) Function(
  DesktopNotificationsState,
  DesktopNotificationEvent,
);

void main() {
  var checksum = 0;
  for (final count in [1, 32, 256]) {
    final reducer = DesktopNotificationReducer();
    final legacy = LegacyNotificationReducer();
    var base = const DesktopNotificationsState();
    for (var i = 0; i < count; i++) {
      base = reducer.apply(base, notificationEvent(i, resident: true)).state;
    }
    for (final unknownClose in [false, true]) {
      final events = List.generate(
        100,
        (i) => unknownClose
            ? closeNotification(count + i)
            : notificationEvent(
                count - 1,
                resident: true,
                progress: i,
                kind: DesktopNotificationEventKind.replaced,
              ),
      );
      double measure(_Apply apply) {
        const iterations = 5000;
        var state = base;
        var total = 0;
        final watch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          state = apply(state, events[i % events.length]).state;
          total += state.active.length + state.history.length;
        }
        watch.stop();
        checksum += total;
        return watch.elapsedTicks * 1e9 / watch.frequency / iterations;
      }

      measure(legacy.apply);
      measure(reducer.apply);
      final before = <double>[];
      final after = <double>[];
      for (var sample = 0; sample < 7; sample++) {
        if (sample.isEven) {
          before.add(measure(legacy.apply));
          after.add(measure(reducer.apply));
        } else {
          after.add(measure(reducer.apply));
          before.add(measure(legacy.apply));
        }
      }
      before.sort();
      after.sort();
      stdout.writeln(
        '$count active, ${unknownClose ? "unknown close" : "progress"}: '
        '${before[3].toStringAsFixed(1)} → ${after[3].toStringAsFixed(1)} ns '
        '(${(before[3] / after[3]).toStringAsFixed(2)}x)',
      );
    }
  }
  stdout.writeln('checksum: $checksum');
}
