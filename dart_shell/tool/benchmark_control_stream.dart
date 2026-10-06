import 'package:denial_flutter_sdk/src/platform/bounded_byte_stream.dart'
    show collectBoundedBytes, decodeBoundedUtf8Lines;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

Future<void> main() async {
  var checksum = 0;
  for (final size in [4096, 65536, 262144]) {
    final bytes = utf8.encode('${'x' * (size - 1)}\n');
    final chunks = [
      for (var start = 0; start < bytes.length; start += 4096)
        Uint8List.sublistView(bytes, start, min(start + 4096, bytes.length)),
    ];
    for (final lines in [false, true]) {
      Future<int> before() async {
        if (lines) {
          var length = 0;
          await for (final line
              in utf8.decoder
                  .bind(Stream.fromIterable(chunks))
                  .transform(const LineSplitter())) {
            if (utf8.encode(line).length > size) throw StateError('limit');
            length += line.length;
          }
          return length;
        }
        final buffer = <int>[];
        await for (final chunk in Stream.fromIterable(chunks)) {
          buffer.addAll(chunk);
          if (buffer.length > size) throw StateError('limit');
        }
        return utf8.decode(buffer).length;
      }

      Future<int> after() async {
        if (lines) {
          var length = 0;
          await for (final line in decodeBoundedUtf8Lines(
            Stream.fromIterable(chunks),
            maximumBytes: size,
          )) {
            length += line.length;
          }
          return length;
        }
        return utf8
            .decode(
              await collectBoundedBytes(
                Stream.fromIterable(chunks),
                maximumBytes: size,
              ),
            )
            .length;
      }

      Future<double> measure(Future<int> Function() run) async {
        const iterations = 50;
        final watch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          checksum += await run();
        }
        watch.stop();
        return watch.elapsedTicks * 1e6 / watch.frequency / iterations;
      }

      await measure(before);
      await measure(after);
      final oldSamples = <double>[];
      final newSamples = <double>[];
      for (var sample = 0; sample < 7; sample++) {
        if (sample.isEven) {
          oldSamples.add(await measure(before));
          newSamples.add(await measure(after));
        } else {
          newSamples.add(await measure(after));
          oldSamples.add(await measure(before));
        }
      }
      oldSamples.sort();
      newSamples.sort();
      stdout.writeln(
        '$size bytes, ${lines ? "lines" : "response"}: '
        '${oldSamples[3].toStringAsFixed(1)} → ${newSamples[3].toStringAsFixed(1)} µs '
        '(${(oldSamples[3] / newSamples[3]).toStringAsFixed(2)}x)',
      );
    }
  }
  stdout.writeln('checksum: $checksum');
}
