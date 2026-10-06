import 'dart:collection';

class DisplayBrightnessState {
  const DisplayBrightnessState({required this.levels, required this.loading});

  final Map<int, double> levels;
  final Set<int> loading;

  DisplayBrightnessState copyWith({
    Map<int, double>? levels,
    Set<int>? loading,
  }) {
    return DisplayBrightnessState(
      levels: levels == null ? this.levels : Map.unmodifiable(levels),
      loading: loading == null ? this.loading : Set.unmodifiable(loading),
    );
  }
}

/// Reconciles initial reads with local edits and native brightness events.
/// Snapshots own immutable collections and share every unchanged collection.
final class DisplayBrightnessModel {
  DisplayBrightnessModel(Iterable<int> monitorIds) {
    final levels = {for (final id in monitorIds) id: 0.72};
    _state = DisplayBrightnessState(
      levels: UnmodifiableMapView(levels),
      loading: UnmodifiableSetView(levels.keys.toSet()),
    );
  }

  late DisplayBrightnessState _state;
  final Map<int, ({int token, bool invalidated})> _reads = {};
  int _nextRead = 0;

  DisplayBrightnessState get state => _state;

  int? beginRead(int monitorId) {
    if (!_state.levels.containsKey(monitorId)) return null;
    final token = ++_nextRead;
    _reads[monitorId] = (token: token, invalidated: false);
    return token;
  }

  DisplayBrightnessState setLevel(int monitorId, double level) {
    if (!_state.levels.containsKey(monitorId)) return _state;
    // Even an edit to the displayed default invalidates an older initial read.
    _invalidateRead(monitorId);
    return _update(monitorId, level, finishLoading: false);
  }

  DisplayBrightnessState nativeLevel(
    int monitorId,
    double level, {
    required bool completesRead,
  }) {
    if (!_state.levels.containsKey(monitorId)) return _state;
    if (completesRead) {
      // The stream notification satisfies the read before its future resumes.
      // Consume it now so that completion cannot publish the same value again.
      final pending = _reads.remove(monitorId);
      if (pending?.invalidated ?? false) {
        return _update(monitorId, null, finishLoading: true);
      }
    } else {
      _invalidateRead(monitorId);
    }
    return _update(monitorId, level, finishLoading: true);
  }

  DisplayBrightnessState completeRead(int monitorId, int token, double? level) {
    final pending = _reads[monitorId];
    if (pending == null || pending.token != token) return _state;
    _reads.remove(monitorId);
    return _update(
      monitorId,
      pending.invalidated ? null : level,
      finishLoading: true,
    );
  }

  void _invalidateRead(int monitorId) {
    final pending = _reads[monitorId];
    if (pending != null && !pending.invalidated) {
      _reads[monitorId] = (token: pending.token, invalidated: true);
    }
  }

  DisplayBrightnessState _update(
    int monitorId,
    double? level, {
    required bool finishLoading,
  }) {
    final normalized = level?.clamp(0.01, 1.0);
    var levels = _state.levels;
    var loading = _state.loading;
    if (normalized != null && levels[monitorId] != normalized) {
      levels = UnmodifiableMapView(
        Map<int, double>.of(levels)..[monitorId] = normalized,
      );
    }
    if (finishLoading && loading.contains(monitorId)) {
      loading = UnmodifiableSetView(Set<int>.of(loading)..remove(monitorId));
    }
    if (!identical(levels, _state.levels) ||
        !identical(loading, _state.loading)) {
      _state = DisplayBrightnessState(levels: levels, loading: loading);
    }
    return _state;
  }
}
