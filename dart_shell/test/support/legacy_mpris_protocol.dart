// Reference parser retained for differential tests and AOT benchmarks.
import 'package:dbus/dbus.dart';
import 'package:denial_flutter_sdk/models.dart';

MprisPlaybackState? legacyApplyMprisPlayerProperties(
  MprisPlaybackState current,
  Map<String, DBusValue> changed,
  DateTime now,
) {
  const relevant = <String>{
    'PlaybackStatus',
    'Metadata',
    'Position',
    'CanGoNext',
    'CanGoPrevious',
    'CanPlay',
    'CanPause',
  };
  if (!changed.keys.any(relevant.contains)) {
    return null;
  }

  final metadataChanged = changed.containsKey('Metadata');
  final metadata = metadataChanged
      ? _variantDict(changed['Metadata'])
      : const <String, DBusValue>{};
  final lengthMicros = metadataChanged
      ? _integer(metadata['mpris:length'])
            .clamp(0, const Duration(days: 7).inMicroseconds)
            .toInt()
      : current.length.inMicroseconds;
  final positionMicros = changed.containsKey('Position')
      ? _integer(changed['Position'])
            .clamp(
              0,
              lengthMicros > 0
                  ? lengthMicros
                  : const Duration(days: 7).inMicroseconds,
            )
            .toInt()
      : current
            .positionAt(now)
            .inMicroseconds
            .clamp(0, lengthMicros > 0 ? lengthMicros : 1 << 53)
            .toInt();
  final title = metadataChanged
      ? _boundedText(_string(metadata['xesam:title']), 256)
      : current.title;
  final artists = metadataChanged
      ? List<String>.unmodifiable(
          _strings(metadata['xesam:artist'])
              .map((artist) => _boundedText(artist, 128))
              .where((artist) => artist.isNotEmpty)
              .take(8),
        )
      : current.artists;

  return MprisPlaybackState(
    serviceName: current.serviceName,
    identity: current.identity,
    title: metadataChanged
        ? (title.isEmpty ? current.identity : title)
        : current.title,
    artists: artists,
    album: metadataChanged
        ? _boundedText(_string(metadata['xesam:album']), 256)
        : current.album,
    artUrl: metadataChanged
        ? _safeArtworkUrl(_string(metadata['mpris:artUrl']))
        : current.artUrl,
    length: Duration(microseconds: lengthMicros),
    position: Duration(microseconds: positionMicros),
    observedAt: now,
    status: changed.containsKey('PlaybackStatus')
        ? _playbackStatus(_string(changed['PlaybackStatus']))
        : current.status,
    canGoNext: changed.containsKey('CanGoNext')
        ? _boolean(changed['CanGoNext'])
        : current.canGoNext,
    canGoPrevious: changed.containsKey('CanGoPrevious')
        ? _boolean(changed['CanGoPrevious'])
        : current.canGoPrevious,
    canPlay: changed.containsKey('CanPlay')
        ? _boolean(changed['CanPlay'])
        : current.canPlay,
    canPause: changed.containsKey('CanPause')
        ? _boolean(changed['CanPause'])
        : current.canPause,
  );
}

MprisPlaybackStatus _playbackStatus(String value) {
  switch (value) {
    case 'Playing':
      return MprisPlaybackStatus.playing;
    case 'Paused':
      return MprisPlaybackStatus.paused;
    default:
      return MprisPlaybackStatus.stopped;
  }
}

Map<String, DBusValue> _variantDict(DBusValue? value) {
  try {
    return value?.asStringVariantDict() ?? const <String, DBusValue>{};
  } on Object {
    return const <String, DBusValue>{};
  }
}

String _string(DBusValue? value, {String fallback = ''}) {
  return value is DBusString ? value.value : fallback;
}

bool _boolean(DBusValue? value) {
  return value is DBusBoolean && value.value;
}

int _integer(DBusValue? value) {
  if (value is DBusInt64) {
    return value.value;
  }
  if (value is DBusUint64) {
    return value.value;
  }
  return 0;
}

Iterable<String> _strings(DBusValue? value) {
  try {
    return value?.asStringArray() ?? const <String>[];
  } on Object {
    return const <String>[];
  }
}

String _safeArtworkUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'file' && uri.scheme != 'http' && uri.scheme != 'https')) {
    return '';
  }
  return uri.toString();
}

String _boundedText(String value, int maximumRunes) {
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return String.fromCharCodes(
    normalized.runes.take(maximumRunes).toList(growable: false),
  );
}
