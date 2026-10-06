// Run with the pinned Dart SDK; this check needs no Flutter development engine.
import 'dart:io';

import 'package:denial_desktop/src/desktop/window_switcher_order.dart';

void main() {
  var checked = 0;
  for (var length = 2; length <= 128; length++) {
    for (var selected = 0; selected < length; selected++) {
      // Reference the previous enumerate/filter/sort behavior, including the
      // tie between the two sides for exactly opposite windows in even lists.
      final distances = <int>[
        for (var index = 0; index < length; index++)
          switch (index - selected) {
            final delta when delta > length / 2 => delta - length,
            final delta when delta < -length / 2 => delta + length,
            final delta => delta,
          },
      ];
      for (final (index, expectedDistance) in distances.indexed) {
        final distance = windowSwitcherSignedDistance(
          index: index,
          selectedIndex: selected,
          length: length,
        );
        if (distance != expectedDistance) {
          throw StateError('Wrong distance: $length/$selected/$index');
        }
        if (distance == 0) continue;
        final side =
            distances
                .where(
                  (candidate) =>
                      candidate != 0 &&
                      candidate.isNegative == distance.isNegative,
                )
                .toList()
              ..sort((a, b) => a.abs().compareTo(b.abs()));
        final expected = (index: side.indexOf(distance), count: side.length);
        final actual = windowSwitcherRail(
          distance: distance,
          selectedIndex: selected,
          length: length,
        );
        if (actual != expected) {
          throw StateError(
            'Wrong rail: $length/$selected/$index: $actual != $expected',
          );
        }
        checked++;
      }
    }
  }
  stdout.writeln('Verified $checked switcher positions for 2–128 windows.');
}
