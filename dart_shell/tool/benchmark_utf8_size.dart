import 'dart:convert';
import 'dart:io';

import 'package:denial_flutter_sdk/shell.dart';

void main() {
  var checksum = 0;
  for (final (label, text, limit) in [
    ('connector', 'DisplayPort-1', 128),
    ('action', 'notification.default', 4096),
    ('settings 16 KiB', 'x' * 16384, 262144),
    ('ASCII at limit', 'x' * 262144, 262144),
    ('Latin-1 at limit', 'é' * 131072, 262144),
    ('CJK at limit', '界' * 87381, 262143),
    ('emoji at limit', '😀' * 65536, 262144),
    ('oversized ASCII', 'x' * 262145, 262144),
  ]) {
    final iterations = text.length < 100 ? 200000 : 500;
    double measure(bool optimized) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        final fits = optimized
            ? fitsUtf8ByteLimit(text, limit)
            : utf8.encode(text).length <= limit;
        if (fits) checksum++;
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
      '$label: ${before[3].toStringAsFixed(3)} → '
      '${after[3].toStringAsFixed(3)} µs '
      '(${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}
