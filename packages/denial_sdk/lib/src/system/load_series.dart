import 'dart:collection';

import 'package:meta/meta.dart';

/// A rolling load series: the most recent 0-1 reading plus the trailing
/// window the system bar sparklines draw, oldest first.
@immutable
class LoadSeries {
  const LoadSeries({
    this.current,
    this.history = const <double>[],
    this.temperatureC,
  }) : _repeatedSamples = 0;

  const LoadSeries._({
    required this.current,
    required this.history,
    required this.temperatureC,
    required this._repeatedSamples,
  });

  // Only append-produced, owned histories acquire a nonzero run length.
  // Externally supplied histories still get copied before they can be reused.
  final int _repeatedSamples;

  static const LoadSeries empty = LoadSeries();

  /// Samples each sparkline keeps: 45 readings at the 2 s cadence ≈ 90 s.
  static const int capacity = 45;

  /// The newest reading as a 0-1 fraction, or null before one exists.
  final double? current;

  /// Up to [capacity] readings, oldest first; the newest equals [current].
  final List<double> history;

  /// Latest directly reported package/device temperature, when available.
  final double? temperatureC;

  LoadSeries append(double usage, {double? temperatureC}) {
    final nextTemperature = temperatureC ?? this.temperatureC;
    final repeats = current == usage;
    if (repeats && _repeatedSamples == capacity) {
      if (nextTemperature == this.temperatureC) return this;
      return LoadSeries._(
        current: usage,
        history: history,
        temperatureC: nextTemperature,
        repeatedSamples: capacity,
      );
    }
    final retained = history.length < capacity ? history.length : capacity - 1;
    final next = List<double>.filled(retained + 1, 0.0);
    next.setRange(0, retained, history, history.length - retained);
    next[retained] = usage;
    return LoadSeries._(
      current: usage,
      history: UnmodifiableListView(next),
      temperatureC: nextTemperature,
      repeatedSamples: repeats ? _repeatedSamples + 1 : 1,
    );
  }
}

/// One autodetected GPU with its rolling load series.
@immutable
class GpuLoad {
  const GpuLoad({
    required this.id,
    required this.label,
    this.series = LoadSeries.empty,
  });

  /// Stable identity across polls (`card2`, `nvml0`).
  final String id;

  /// Compact vendor tag shown in the pill (`AMD`, `NV`, `NV0`…).
  final String label;

  final LoadSeries series;
}
