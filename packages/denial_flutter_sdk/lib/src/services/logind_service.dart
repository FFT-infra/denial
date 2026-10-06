import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'logind_backend.dart';

export 'logind_backend.dart';

final logindServiceProvider = Provider<LogindBackend>((ref) {
  final service = LogindService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
