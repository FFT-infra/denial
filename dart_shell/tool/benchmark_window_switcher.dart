// Compile with the pinned Dart SDK and run the executable to measure AOT:
// dart compile exe tool/benchmark_window_switcher.dart -o /tmp/switcher-bench
// /tmp/switcher-bench
// Measures CPU algorithms only, not Flutter rendering or desktop frame time.
import 'dart:io';

import 'package:denial_desktop/src/desktop/window_switcher_order.dart';

int _sink = 0;

void main() {
  stdout.writeln(
    'Dart ${Platform.version.split(' ').first}; median of 7 samples',
  );
  stdout.writeln('windows,operation,previous_us,current_us,speedup');
  for (final count in [4, 8, 16, 24, 32, 128]) {
    final ids = List<int>.unmodifiable(
      List.generate(count, (index) => index * 7 + 100),
    );
    final order = WindowSwitcherOrder(ids);
    _compare(
      count,
      'lookup pass',
      (iteration) {
        var sum = 0;
        for (var i = 0; i < count; i++) {
          sum += ids.indexOf(ids[(i + iteration) % count]);
        }
        return sum + ids.indexOf(-1);
      },
      (iteration) {
        var sum = 0;
        for (var i = 0; i < count; i++) {
          sum += order.indexOf(ids[(i + iteration) % count]);
        }
        return sum + order.indexOf(-1);
      },
    );
    _compare(
      count,
      'rail pass',
      (iteration) {
        final selected = iteration % count;
        var sum = 0;
        for (var i = 0; i < count; i++) {
          final distance = windowSwitcherSignedDistance(
            index: i,
            selectedIndex: selected,
            length: count,
          );
          if (distance == 0) continue;
          final side =
              [
                  for (var candidate = 0; candidate < count; candidate++)
                    windowSwitcherSignedDistance(
                      index: candidate,
                      selectedIndex: selected,
                      length: count,
                    ),
                ]
                ..removeWhere(
                  (value) =>
                      value == 0 || value.isNegative != distance.isNegative,
                )
                ..sort((a, b) => a.abs().compareTo(b.abs()));
          sum += side.indexOf(distance) + side.length;
        }
        return sum;
      },
      (iteration) {
        final selected = iteration % count;
        var sum = 0;
        for (var i = 0; i < count; i++) {
          final distance = windowSwitcherSignedDistance(
            index: i,
            selectedIndex: selected,
            length: count,
          );
          if (distance == 0) continue;
          final rail = windowSwitcherRail(
            distance: distance,
            selectedIndex: selected,
            length: count,
          );
          sum += rail.index + rail.count;
        }
        return sum;
      },
    );
  }
  stdout.writeln('checksum=$_sink');
}

void _compare(
  int count,
  String label,
  int Function(int) previous,
  int Function(int) current,
) {
  for (var i = 0; i < count; i++) {
    if (previous(i) != current(i)) throw StateError('$label differs at $i');
  }
  final previousIterations = _calibrate(previous);
  final currentIterations = _calibrate(current);
  final before = <double>[];
  final after = <double>[];
  for (var sample = 0; sample < 7; sample++) {
    // Alternate order to reduce bias from CPU frequency and competing work.
    if (sample.isEven) {
      before.add(_measure(previous, previousIterations));
      after.add(_measure(current, currentIterations));
    } else {
      after.add(_measure(current, currentIterations));
      before.add(_measure(previous, previousIterations));
    }
  }
  before.sort();
  after.sort();
  stdout.writeln(
    '$count,$label,${before[3].toStringAsFixed(3)},'
    '${after[3].toStringAsFixed(3)},${(before[3] / after[3]).toStringAsFixed(2)}x',
  );
}

int _calibrate(int Function(int) operation) {
  var iterations = 16;
  while (_measure(operation, iterations) * iterations < 30000) {
    iterations *= 2;
  }
  return iterations;
}

double _measure(int Function(int) operation, int iterations) {
  var sum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    sum += operation(i);
  }
  watch.stop();
  _sink ^= sum;
  return watch.elapsedTicks * 1000000 / watch.frequency / iterations;
}
