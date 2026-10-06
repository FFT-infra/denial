import 'package:meta/meta.dart';

enum MprisPlaybackStatus { playing, paused, stopped }

@immutable
class MprisPlaybackState {
  const MprisPlaybackState({
    required this.serviceName,
    required this.identity,
    required this.title,
    required this.artists,
    required this.album,
    required this.artUrl,
    required this.length,
    required this.position,
    required this.observedAt,
    required this.status,
    required this.canGoNext,
    required this.canGoPrevious,
    required this.canPlay,
    required this.canPause,
  });

  MprisPlaybackState.unavailable()
    : serviceName = '',
      identity = '',
      title = '',
      artists = const <String>[],
      album = '',
      artUrl = '',
      length = Duration.zero,
      position = Duration.zero,
      observedAt = DateTime.fromMillisecondsSinceEpoch(0),
      status = MprisPlaybackStatus.stopped,
      canGoNext = false,
      canGoPrevious = false,
      canPlay = false,
      canPause = false;

  final String serviceName;
  final String identity;
  final String title;
  final List<String> artists;
  final String album;
  final String artUrl;
  final Duration length;
  final Duration position;
  final DateTime observedAt;
  final MprisPlaybackStatus status;
  final bool canGoNext;
  final bool canGoPrevious;
  final bool canPlay;
  final bool canPause;

  bool get available =>
      serviceName.isNotEmpty &&
      (status == MprisPlaybackStatus.playing ||
          status == MprisPlaybackStatus.paused);

  bool get playing => status == MprisPlaybackStatus.playing;

  String get artistLabel => artists.join(', ');

  Duration positionAt(DateTime now) {
    if (!playing || length <= Duration.zero) {
      return position;
    }
    final elapsed = now.difference(observedAt);
    if (elapsed.isNegative) {
      return position;
    }
    final advanced = position + elapsed;
    return advanced > length ? length : advanced;
  }
}
