import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'denial_bridge.dart';

/// The connected platform client, independent of any window/UI controller.
final denialBridgeProvider = Provider<DenialBridge>((ref) {
  final bridge = DenialBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});
