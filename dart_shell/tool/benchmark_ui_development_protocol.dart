import 'package:denial_flutter_sdk/wire.dart'
    show DenialUiDevelopmentCommand, DenialUiDevelopmentProtocol;

import 'dart:io';

import '../test/support/legacy_ui_development_protocol.dart';
import '../test/support/ui_development_packet.dart';

void main() {
  final before = LegacyUiDevelopmentProtocol();
  final after = DenialUiDevelopmentProtocol();
  var checksum = 0;
  for (final count in [-1, 0, 8, 64]) {
    final packet = uiDevelopmentPacket(diagnostics: count < 0 ? 0 : count);
    final iterations = count == 64 ? 10000 : 50000;
    int oldRun() => count < 0
        ? before
              .encodeCommand(
                command: DenialUiDevelopmentCommand.query,
                requestId: 1,
              )!
              .length
        : before.decodeState(packet)!.diagnostics.length;
    int newRun() => count < 0
        ? after
              .encodeCommand(
                command: DenialUiDevelopmentCommand.query,
                requestId: 1,
              )!
              .length
        : after.decodeState(packet)!.diagnostics.length;
    double measure(int Function() run) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        checksum += run();
      }
      watch.stop();
      return watch.elapsedTicks * 1e6 / watch.frequency / iterations;
    }

    measure(oldRun);
    measure(newRun);
    final oldSamples = <double>[];
    final newSamples = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      if (sample.isEven) {
        oldSamples.add(measure(oldRun));
        newSamples.add(measure(newRun));
      } else {
        newSamples.add(measure(newRun));
        oldSamples.add(measure(oldRun));
      }
    }
    oldSamples.sort();
    newSamples.sort();
    stdout.writeln(
      '${count < 0 ? "query command" : "$count diagnostics"}: '
      '${oldSamples[3].toStringAsFixed(3)} → ${newSamples[3].toStringAsFixed(3)} µs '
      '(${(oldSamples[3] / newSamples[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}
