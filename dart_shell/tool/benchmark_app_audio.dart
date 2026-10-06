import 'package:denial_flutter_sdk/src/state/app_audio_reconciliation.dart'
    show reconcileAppAudioStreams, updateAppAudioStreamVolume;

// Compile with the pinned Dart SDK and run the resulting AOT executable:
// dart compile exe tool/benchmark_app_audio.dart -o /tmp/app-audio-bench
// /tmp/app-audio-bench
import 'dart:io';
import 'dart:math';

import 'package:denial_flutter_sdk/models.dart';

int _checksum = 0;
void main() {
  for (final count in [1, 2, 4, 8, 16, 64]) {
    final streams = List.generate(
      count,
      (id) => AppAudioStream(
        id: id,
        name: 'Media Player $id',
        level: 0.5,
        muted: false,
      ),
    )..shuffle(Random(count));
    _compare(
      '$count streams, no pending writes',
      () => _previous(streams, {}, {}),
      () => reconcileAppAudioStreams(
        streams,
        desiredVolumes: {},
        pendingVolumes: {},
      ),
      20000,
    );
  }
  final streams = List<AppAudioStream>.unmodifiable(
    List.generate(
      16,
      (id) =>
          AppAudioStream(id: id, name: 'Player $id', level: 0.5, muted: false),
    ),
  );
  _compare(
    'Repeated slider percentage, 16 streams',
    () => List<AppAudioStream>.unmodifiable(
      streams.map(
        (s) => s.id == 3
            ? AppAudioStream(id: s.id, name: s.name, level: 0.5, muted: false)
            : s,
      ),
    ),
    () => updateAppAudioStreamVolume(streams, 3, 0.5),
    500000,
  );
  stdout.writeln('checksum=$_checksum');
}

void _compare(
  String label,
  List<AppAudioStream> Function() before,
  List<AppAudioStream> Function() after,
  int iterations,
) {
  _measure(before, iterations ~/ 10);
  _measure(after, iterations ~/ 10);
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
    '$label: ${oldSamples[3].toStringAsFixed(1)} -> ${newSamples[3].toStringAsFixed(1)} ns/update (${(oldSamples[3] / newSamples[3]).toStringAsFixed(2)}x)',
  );
}

double _measure(List<AppAudioStream> Function() operation, int count) {
  final clock = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    final result = operation();
    _checksum += result.length + result.last.id;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}

// Previous controller implementation, including per-comparison name folding.
List<AppAudioStream> _previous(
  List<AppAudioStream> streams,
  Map<int, int> desired,
  Map<int, int> pending,
) {
  final ids = streams.map((stream) => stream.id).toSet();
  desired.removeWhere((id, _) => !ids.contains(id));
  pending.removeWhere((id, _) => !ids.contains(id));
  final result =
      streams
          .map((stream) {
            final percent = desired[stream.id];
            if (percent == null) return stream;
            final observed = (stream.level * 100).round().clamp(0, 100);
            if ((observed - percent).abs() <= 1 && !stream.muted) {
              desired.remove(stream.id);
              return stream;
            }
            return stream.copyWith(level: percent / 100.0, muted: false);
          })
          .toList(growable: false)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return List<AppAudioStream>.unmodifiable(result);
}
