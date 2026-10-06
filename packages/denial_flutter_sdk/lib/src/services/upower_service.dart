import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'upower_backend.dart';

export 'upower_backend.dart';

final upowerServiceProvider = Provider<UPowerBackend>((ref) {
  final service = UPowerService();
  ref.onDispose(service.dispose);
  return service;
});
