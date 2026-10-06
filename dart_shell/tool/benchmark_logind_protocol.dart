import 'package:denial_flutter_sdk/src/services/logind_protocol.dart'
    show parseLogindInhibitors;

import 'dart:io';

import 'package:dbus/dbus.dart';

import '../test/support/legacy_logind_protocol.dart';

void main() {
  var checksum = 0;
  for (final (label, count, classes) in [
    ('ordinary', 4, 'sleep:shutdown:idle'),
    ('full list', 64, 'sleep:shutdown:idle'),
    ('over limit', 4096, 'sleep:shutdown:idle'),
    ('long class list', 4, List.filled(10000, 'sleep').join(':')),
  ]) {
    final value = DBusArray(DBusSignature('(ssssuu)'), [
      for (var i = 0; i < count; i++)
        DBusStruct([
          DBusString(classes),
          const DBusString(' Media player '),
          const DBusString('Playback\n\tin progress'),
          const DBusString('block'),
          const DBusUint32(1000),
          DBusUint32(i),
        ]),
    ]);
    final iterations = label == 'long class list' ? 100 : 1000;
    double measure(bool optimized) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        final result = optimized
            ? parseLogindInhibitors(value)
            : legacyLogindInhibitors(value);
        checksum += result.length + result.first.what.length;
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
      '$label: ${before[3].toStringAsFixed(2)} → ${after[3].toStringAsFixed(2)} µs (${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}
