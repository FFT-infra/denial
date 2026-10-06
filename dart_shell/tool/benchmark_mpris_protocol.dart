import 'package:denial_flutter_sdk/src/services/mpris_playback_protocol.dart'
    show applyMprisPlayerProperties, parseMprisPlaybackState;

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../test/support/legacy_mpris_protocol.dart';

void main() {
  final now = DateTime(2026, 1, 1);
  final state = parseMprisPlaybackState(
    'org.mpris.MediaPlayer2.player',
    {
      'PlaybackStatus': const DBusString('Playing'),
      'Metadata': DBusDict.stringVariant({
        'mpris:length': const DBusInt64(10000000),
      }),
    },
    {'Identity': const DBusString('Player')},
    now,
  )!;
  final later = now.add(const Duration(seconds: 1));
  final cases = <String, Map<String, DBusValue>>{
    'unchanged capability': {'CanGoNext': const DBusBoolean(false)},
    'changed capability': {'CanGoNext': const DBusBoolean(true)},
    'position': {'Position': const DBusInt64(5000000)},
    'short metadata': _metadata('A song title', 'Artist', 'Album'),
    'Unicode metadata': _metadata('A song 🎵 — 夜曲', '音楽家', '音楽'),
    'long metadata': _metadata(
      'Long title ' * 50,
      'Long artist ' * 20,
      'Long album ' * 40,
    ),
  };
  var checksum = 0;
  for (final entry in cases.entries) {
    final iterations = entry.key == 'long metadata'
        ? 2000
        : entry.value.containsKey('Metadata')
        ? 20000
        : 200000;
    double measure(
      MprisPlaybackState? Function(
        MprisPlaybackState,
        Map<String, DBusValue>,
        DateTime,
      )
      apply,
    ) {
      final watch = Stopwatch()..start();
      var total = 0;
      for (var i = 0; i < iterations; i++) {
        final next = apply(state, entry.value, later)!;
        total +=
            next.title.length +
            next.position.inMicroseconds +
            (next.canGoNext ? 1 : 0);
      }
      watch.stop();
      checksum += total;
      return watch.elapsedTicks * 1e9 / watch.frequency / iterations;
    }

    measure(legacyApplyMprisPlayerProperties);
    measure(applyMprisPlayerProperties);
    final oldSamples = <double>[];
    final newSamples = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      if (sample.isEven) {
        oldSamples.add(measure(legacyApplyMprisPlayerProperties));
        newSamples.add(measure(applyMprisPlayerProperties));
      } else {
        newSamples.add(measure(applyMprisPlayerProperties));
        oldSamples.add(measure(legacyApplyMprisPlayerProperties));
      }
    }
    oldSamples.sort();
    newSamples.sort();
    stdout.writeln(
      '${entry.key}: ${oldSamples[3].toStringAsFixed(1)} → ${newSamples[3].toStringAsFixed(1)} ns (${(oldSamples[3] / newSamples[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum: $checksum');
}

Map<String, DBusValue> _metadata(String title, String artist, String album) => {
  'Metadata': DBusDict.stringVariant({
    'xesam:title': DBusString(title),
    'xesam:artist': DBusArray.string([artist]),
    'xesam:album': DBusString(album),
    'mpris:length': const DBusInt64(10000000),
  }),
};
