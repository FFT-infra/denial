import 'package:denial_flutter_sdk/src/state/display_brightness_model.dart'
    show DisplayBrightnessModel;

// Compile with the pinned SDK, then run the resulting AOT executable:
// dart compile exe tool/benchmark_display_brightness.dart -o /tmp/brightness-bench
// /tmp/brightness-bench
import 'dart:io';

import 'package:denial_flutter_sdk/state.dart';

int _checksum = 0;
void main() {
  for (final monitors in [1, 4]) {
    for (final repeated in [true, false]) {
      var previous = DisplayBrightnessState(
        levels: Map.unmodifiable({
          for (var id = 0; id < monitors; id++) id: 0.72,
        }),
        loading: Set.unmodifiable({for (var id = 0; id < monitors; id++) id}),
      );
      final model = DisplayBrightnessModel(List.generate(monitors, (id) => id));
      DisplayBrightnessState before(int index) {
        final level = repeated ? 0.72 : (index.isEven ? 0.4 : 0.8);
        final levels = Map<int, double>.of(previous.levels)..[0] = level;
        final loading = Set<int>.of(previous.loading)..remove(0);
        return previous = DisplayBrightnessState(
          levels: Map.unmodifiable(levels),
          loading: Set.unmodifiable(loading),
        );
      }

      DisplayBrightnessState after(int index) => model.nativeLevel(
        0,
        repeated ? 0.72 : (index.isEven ? 0.4 : 0.8),
        completesRead: false,
      );
      const iterations = 200000;
      _measure(before, 10000);
      _measure(after, 10000);
      final oldSamples = <double>[];
      final newSamples = <double>[];
      for (var sample = 0; sample < 7; sample++) {
        if (sample.isEven) {
          oldSamples.add(_measure(before, iterations));
          newSamples.add(_measure(after, iterations));
        } else {
          newSamples.add(_measure(after, iterations));
          oldSamples.add(_measure(before, iterations));
        }
      }
      oldSamples.sort();
      newSamples.sort();
      stdout.writeln(
        '$monitors monitors, ${repeated ? 'unchanged' : 'changed'} native value: ${oldSamples[3].toStringAsFixed(1)} -> ${newSamples[3].toStringAsFixed(1)} ns/update (${(oldSamples[3] / newSamples[3]).toStringAsFixed(2)}x)',
      );
    }
  }
  stdout.writeln('checksum=$_checksum');
}

double _measure(DisplayBrightnessState Function(int) operation, int count) {
  final clock = Stopwatch()..start();
  for (var index = 0; index < count; index++) {
    final result = operation(index);
    _checksum += (result.levels[0]! * 100).round() + result.loading.length;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}
