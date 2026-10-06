import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import '../services/brightness_service.dart';
import 'display_brightness_model.dart';
import 'display_layout.dart';
import 'notifier_lifecycle.dart';

export 'display_brightness_model.dart' show DisplayBrightnessState;

final displayBrightnessProvider =
    NotifierProvider<DisplayBrightnessController, DisplayBrightnessState>(
      DisplayBrightnessController.new,
    );

class DisplayBrightnessController extends Notifier<DisplayBrightnessState>
    with NotifierLifecycle<DisplayBrightnessState> {
  static const Duration _commitInterval = Duration(milliseconds: 90);

  final Map<int, Timer> _commitTimers = <int, Timer>{};
  late BrightnessService _service;
  late DisplayBrightnessModel _model;
  late List<DisplayOutput> _outputs;
  late int _buildGeneration;

  @override
  DisplayBrightnessState build() {
    _service = ref.watch(brightnessServiceProvider);
    _outputs = List<DisplayOutput>.unmodifiable(
      ref.watch(displayLayoutProvider)?.outputs ?? const <DisplayOutput>[],
    );
    _model = DisplayBrightnessModel(_outputs.map((output) => output.monitorId));
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _service.states.listen(
      (update) => _handleNativeUpdate(update, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      for (final timer in _commitTimers.values) {
        timer.cancel();
      }
      _commitTimers.clear();
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        for (final output in _outputs) {
          unawaited(_refreshOutput(output, generation));
        }
      }
    });
    return _model.state;
  }

  void setLevel(DisplayOutput output, double value) {
    if (!_recordLevel(output, value)) return;
    _commitTimers[output.monitorId] ??= Timer(
      _commitInterval,
      () => _flush(output),
    );
  }

  void commitLevel(DisplayOutput output, double value) {
    if (!_recordLevel(output, value)) return;
    _commitTimers.remove(output.monitorId)?.cancel();
    _flush(output);
  }

  void reset() {
    for (final output in _outputs) {
      commitLevel(output, 0.72);
    }
  }

  bool _recordLevel(DisplayOutput output, double value) {
    if (!state.levels.containsKey(output.monitorId)) return false;
    _publish(_model.setLevel(output.monitorId, value));
    return true;
  }

  void _flush(DisplayOutput output) {
    _commitTimers.remove(output.monitorId)?.cancel();
    final level = state.levels[output.monitorId];
    if (level == null) {
      return;
    }
    _service.apply((level * 100).round(), output);
  }

  Future<void> _refreshOutput(DisplayOutput output, int generation) async {
    final model = _model;
    final token = model.beginRead(output.monitorId);
    if (token == null) return;
    double? level;
    try {
      level = await _service.readLevel(output);
    } on Object {
      // An unreadable backlight still finishes the initial loading state.
    }
    if (!isBuildGenerationActive(generation)) return;
    _publish(model.completeRead(output.monitorId, token, level));
  }

  void _handleNativeUpdate(DenialBrightnessState update, int generation) {
    if (!isBuildGenerationActive(generation)) return;
    _publish(
      _model.nativeLevel(
        update.monitorId,
        update.level,
        completesRead: update.completesRead,
      ),
    );
  }

  void _publish(DisplayBrightnessState next) {
    if (!identical(state, next)) state = next;
  }
}
