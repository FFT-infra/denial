import 'package:denial_sdk/system.dart';
import 'package:meta/meta.dart';

import 'shell_power_status.dart';

export 'package:denial_sdk/system.dart' show LoadSeries, GpuLoad;

@immutable
class SystemTelemetrySnapshot {
  const SystemTelemetrySnapshot({
    this.cpu = LoadSeries.empty,
    this.gpus = const <GpuLoad>[],
    this.power = ShellPowerStatus.unknown,
  });

  final LoadSeries cpu;
  final List<GpuLoad> gpus;
  final ShellPowerStatus power;
}
