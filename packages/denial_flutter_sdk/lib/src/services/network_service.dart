import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_backend.dart';
import 'network_service_backend.dart';

export 'network_backend.dart';
export 'network_service_backend.dart';

final networkServiceProvider = Provider<NetworkBackend>((ref) {
  final service = NetworkService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
