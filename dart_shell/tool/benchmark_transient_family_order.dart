import 'dart:io';

import 'package:denial_desktop/src/desktop/transient_family_order.dart';

import '../test/support/legacy_transient_family_order.dart';

void main() {
  var checksum = 0;
  for (final (label, size, shape) in [
    ('ordinary', 16, 'none'),
    ('parent/dialog', 16, 'pair'),
    ('small family', 8, 'wide'),
    ('wide family', 64, 'wide'),
    ('deep family', 64, 'deep'),
    ('large deep family', 256, 'deep'),
  ]) {
    final placements = {for (var id = 0; id < size; id++) id: size - id};
    final parents = switch (shape) {
      'none' => <int, int>{},
      'pair' => {1: 0},
      'wide' => {for (var id = 1; id < size; id++) id: 0},
      _ => {for (var id = 1; id < size; id++) id: id - 1},
    };
    final iterations = size == 256 ? 200 : 3000;
    double measure(bool optimized) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        final result = optimized
            ? orderTransientFamily(
                activatedObjectId: 0,
                placements: placements,
                parentIds: parents,
                zOrder: (z) => z,
              )
            : legacyTransientFamilyOrder(0, placements, parents);
        checksum += result.length + result.last;
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
      '$label ($size windows): '
      '${before[3].toStringAsFixed(2)} → ${after[3].toStringAsFixed(2)} µs '
      '(${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}
