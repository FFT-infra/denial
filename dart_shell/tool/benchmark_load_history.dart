import 'dart:collection';
import 'dart:io';

import 'package:denial_flutter_sdk/models.dart';

LoadSeries _previousAppend(LoadSeries previous, double usage) {
  // The bounded-copy implementation before unchanged histories were reused.
  final retained = previous.history.length < LoadSeries.capacity
      ? previous.history.length
      : LoadSeries.capacity - 1;
  final next = List<double>.filled(retained + 1, 0.0);
  next.setRange(
    0,
    retained,
    previous.history,
    previous.history.length - retained,
  );
  next[retained] = usage;
  return LoadSeries(
    current: usage,
    history: UnmodifiableListView(next),
    temperatureC: previous.temperatureC,
  );
}

void main() {
  var checksum = 0.0;
  for (final (length, rolling, changing) in [
    (0, false, false),
    (10, false, false),
    (45, false, false),
    (45, true, false),
    (45, true, true),
  ]) {
    final initial = LoadSeries(
      history: List.unmodifiable(
        List.generate(length, (i) => i / (length + 1)),
      ),
    );
    const iterations = 100000;
    double measure(bool optimized) {
      var source = initial;
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        final usage = changing ? (i % 17) / 17 : 0.5;
        final next = optimized
            ? source.append(usage)
            : _previousAppend(source, usage);
        if (rolling) source = next;
        checksum += next.history.first + next.history.length;
      }
      watch.stop();
      return watch.elapsedTicks * 1e6 / watch.frequency / iterations;
    }

    measure(false);
    measure(true);
    final before = <double>[];
    final after = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      if (sample.isEven) {
        before.add(measure(false));
        after.add(measure(true));
      } else {
        after.add(measure(true));
        before.add(measure(false));
      }
    }
    before.sort();
    after.sort();
    stdout.writeln(
      '$length history values${rolling ? " (rolling)" : ""}${changing ? " changing" : " constant"}: ${before[3].toStringAsFixed(3)} → '
      '${after[3].toStringAsFixed(3)} µs (${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}
