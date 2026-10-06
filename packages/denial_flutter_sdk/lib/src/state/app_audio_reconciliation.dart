import 'dart:collection';

import '../models/audio.dart';

/// Applies local volume intent until the native snapshot acknowledges it.
/// Pending commands for streams which disappeared are discarded.
List<AppAudioStream> reconcileAppAudioStreams(
  List<AppAudioStream> streams, {
  required Map<int, int> desiredVolumes,
  required Map<int, int> pendingVolumes,
}) {
  if (streams.isEmpty) {
    desiredVolumes.clear();
    pendingVolumes.clear();
    return const [];
  }
  if (desiredVolumes.isNotEmpty || pendingVolumes.isNotEmpty) {
    final liveIds = {for (final stream in streams) stream.id};
    desiredVolumes.removeWhere((id, _) => !liveIds.contains(id));
    pendingVolumes.removeWhere((id, _) => !liveIds.contains(id));
  }

  // Small lists need only a handful of comparisons; avoid decorating every
  // element when that bookkeeping costs more than folding the names directly.
  if (streams.length <= 8) {
    final result = [
      for (final stream in streams) _resolveStream(stream, desiredVolumes),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return UnmodifiableListView(result);
  }

  final entries = <({String key, AppAudioStream stream})>[];
  var ordered = true;
  String? previousKey;
  for (final stream in streams) {
    final resolved = _resolveStream(stream, desiredVolumes);
    final key = stream.name.toLowerCase();
    if (previousKey != null && previousKey.compareTo(key) > 0) {
      ordered = false;
    }
    previousKey = key;
    entries.add((key: key, stream: resolved));
  }
  if (!ordered) entries.sort((a, b) => a.key.compareTo(b.key));
  return List<AppAudioStream>.unmodifiable(
    entries.map((entry) => entry.stream),
  );
}

AppAudioStream _resolveStream(
  AppAudioStream stream,
  Map<int, int> desiredVolumes,
) {
  final desired = desiredVolumes[stream.id];
  if (desired == null) return stream;
  final observed = (stream.level * 100).round().clamp(0, 100);
  if ((observed - desired).abs() <= 1 && !stream.muted) {
    desiredVolumes.remove(stream.id);
    return stream;
  }
  return stream.copyWith(level: desired / 100.0, muted: false);
}

/// Retains the current immutable snapshot when a slider has not crossed a
/// percentage boundary. Changed snapshots reuse all unaffected stream objects.
List<AppAudioStream> updateAppAudioStreamVolume(
  List<AppAudioStream> streams,
  int streamId,
  double level,
) {
  List<AppAudioStream>? updated;
  for (var index = 0; index < streams.length; index++) {
    final stream = streams[index];
    if (stream.id != streamId) continue;
    final replacement = stream.copyWith(level: level, muted: false);
    if (identical(stream, replacement)) continue;
    updated ??= streams.toList(growable: false);
    updated[index] = replacement;
  }
  return updated == null ? streams : UnmodifiableListView(updated);
}
