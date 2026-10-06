import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'linux_gpu_usage.dart';

export 'linux_gpu_usage.dart';

final gpuUsageServiceProvider = Provider<GpuUsageService>((ref) {
  return GpuUsageService();
});
