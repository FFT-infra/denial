import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bluetooth_backend.dart';

export 'bluetooth_backend.dart';

final bluetoothServiceProvider = Provider<BluetoothBackend>((ref) {
  final service = BluetoothService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
