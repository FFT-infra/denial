import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mpris_playback.dart';
import 'media_player_backend.dart';

export '../models/mpris_playback.dart';
export 'media_player_backend.dart';
export 'mpris_playback_protocol.dart' show applyMprisPlayerProperties;

final mediaPlayerServiceProvider = Provider<MediaPlayerService>((ref) {
  final service = MediaPlayerService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final mediaPlaybackProvider = StreamProvider<MprisPlaybackState>((ref) async* {
  final service = ref.watch(mediaPlayerServiceProvider);
  await service.start();
  yield service.current;
  yield* service.snapshots;
});
