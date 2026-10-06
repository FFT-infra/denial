import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'linux_cpu_usage.dart';

export 'linux_cpu_usage.dart';

final cpuUsageServiceProvider = Provider<CpuUsageService>((ref) {
  return CpuUsageService();
});
