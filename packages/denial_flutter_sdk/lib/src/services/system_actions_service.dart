import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';

final systemActionsServiceProvider = Provider<SystemActionsService>((ref) {
  return SystemActionsService(ref.watch(denialBridgeProvider));
});

/// One-shot system actions triggered from the quick-settings shade.
class SystemActionsService {
  const SystemActionsService(this._bridge);

  final DenialBridge _bridge;

  void takeScreenshot() => _bridge.takeScreenshot();
}
