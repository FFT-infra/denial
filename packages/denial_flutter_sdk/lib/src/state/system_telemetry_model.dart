import 'dart:collection';

import '../models/shell_power_status.dart';
import '../models/system_telemetry.dart';
import '../services/linux_cpu_usage.dart' show CpuSample;
import '../services/linux_gpu_usage.dart' show GpuSample;

/// Reduces one completed telemetry poll while retaining the CPU counter anchor.
/// A new instance starts a new polling lifetime, without carrying old counters.
final class SystemTelemetryModel {
  CpuSample? _previousCpu;

  SystemTelemetrySnapshot update(
    SystemTelemetrySnapshot current, {
    required CpuSample? cpuSample,
    required List<GpuSample> gpuSamples,
    required ShellPowerStatus powerStatus,
  }) {
    var nextCpu = current.cpu;
    final previousCpu = _previousCpu;
    _previousCpu = cpuSample ?? previousCpu;
    if (cpuSample != null && previousCpu != null) {
      final usage = CpuSample.usageBetween(previousCpu, cpuSample);
      if (usage != null) {
        nextCpu = current.cpu.append(
          usage,
          temperatureC: cpuSample.temperatureC,
        );
      }
    }

    var nextGpus = current.gpus;
    if (gpuSamples.isEmpty) {
      if (nextGpus.isNotEmpty) nextGpus = const [];
    } else {
      // Most desktops expose zero or one GPU; those cases need no lookup map.
      // Multiple entries retain last-match behavior for duplicate identities.
      final previous = current.gpus;
      final byId = previous.length > 1
          ? {for (final load in previous) load.id: load}
          : null;
      final single = previous.length == 1 ? previous.single : null;
      List<GpuLoad>? next;
      for (var index = 0; index < gpuSamples.length; index++) {
        final sample = gpuSamples[index];
        final old = single?.id == sample.id ? single : byId?[sample.id];
        final series = (old?.series ?? LoadSeries.empty).append(
          sample.usage,
          temperatureC: sample.temperatureC,
        );
        final updated =
            old != null &&
                old.label == sample.label &&
                identical(old.series, series)
            ? old
            : GpuLoad(id: sample.id, label: sample.label, series: series);
        if (next != null) {
          next.add(updated);
        } else if (index >= previous.length ||
            !identical(updated, previous[index])) {
          next = [...previous.take(index), updated];
        }
      }
      if (next != null) {
        nextGpus = UnmodifiableListView(next);
      } else if (gpuSamples.length != previous.length) {
        nextGpus = UnmodifiableListView(previous.sublist(0, gpuSamples.length));
      }
    }
    final nextPower = powerStatus == current.power
        ? current.power
        : powerStatus;
    if (identical(nextCpu, current.cpu) &&
        identical(nextGpus, current.gpus) &&
        identical(nextPower, current.power)) {
      return current;
    }
    return SystemTelemetrySnapshot(
      cpu: nextCpu,
      gpus: nextGpus,
      power: nextPower,
    );
  }
}
