import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/power_profile.dart';
import 'system_io.dart';

export '../models/power_profile.dart';

final powerProfileServiceProvider = Provider<PowerProfileService>((ref) {
  return const PowerProfileService();
});

/// Reads and writes the system power profile through denia-powerd.
class PowerProfileService {
  const PowerProfileService();

  static const String _envPath = '/run/denia-powerd/power_profile.env';
  static const String _socketPath = '/run/denia-powerd/profile.sock';

  Future<String?> read() async {
    final fields = await readKeyValueFile(_envPath);
    return PowerProfile.normalize(fields['POWER_PROFILE']);
  }

  Future<void> write(String profile) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(_socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 700),
      );
      socket.write('$profile\n');
      await socket.flush();
    } on Object {
      // Powerd may be absent during local runs.
    } finally {
      socket?.destroy();
    }
  }
}
