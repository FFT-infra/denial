import '../models/denial_window.dart';
import 'shell_window_index.dart';

/// The shared native window snapshot, focus, and authoritative lock state.
/// Root plugins own their gestures, overlays, and presentation transitions.
class ShellState {
  factory ShellState({
    required List<DenialWindow> windows,
    List<DenialWindow> layerSurfaces = const [],
    required int windowSnapshotSequence,
    required bool locked,
    int? foregroundObjectId,
    int activationRevision = 0,
  }) => ShellState._(
    windowIndex: ShellWindowIndex(windows),
    layerSurfaces: List.unmodifiable(layerSurfaces),
    windowSnapshotSequence: windowSnapshotSequence,
    locked: locked,
    foregroundObjectId: foregroundObjectId,
    activationRevision: activationRevision,
  );

  const ShellState._({
    required this._windowIndex,
    required this.layerSurfaces,
    required this.windowSnapshotSequence,
    required this.locked,
    required this.foregroundObjectId,
    required this.activationRevision,
  });

  factory ShellState.initial({bool locked = false}) =>
      ShellState(windows: const [], windowSnapshotSequence: 0, locked: locked);

  final ShellWindowIndex _windowIndex;
  List<DenialWindow> get windows => _windowIndex.windows;
  List<DenialWindow> get openAppWindows => _windowIndex.apps;
  Map<int, DenialWindow> get openAppWindowsByObjectId =>
      _windowIndex.appsByObjectId;
  List<DenialWindow> get positionedPopupSurfaces =>
      _windowIndex.positionedPopupSurfaces;
  final List<DenialWindow> layerSurfaces;
  final int windowSnapshotSequence;
  final bool locked;
  final int? foregroundObjectId;

  /// Changes for each native activation, including repeated focus on one window.
  final int activationRevision;

  ShellState copyWith({
    List<DenialWindow>? windows,
    List<DenialWindow>? layerSurfaces,
    int? windowSnapshotSequence,
    bool? locked,
    int? foregroundObjectId,
    bool clearForegroundObjectId = false,
    int? activationRevision,
  }) => ShellState._(
    windowIndex: windows == null || identical(windows, this.windows)
        ? _windowIndex
        : ShellWindowIndex(windows),
    layerSurfaces:
        layerSurfaces == null || identical(layerSurfaces, this.layerSurfaces)
        ? this.layerSurfaces
        : List.unmodifiable(layerSurfaces),
    windowSnapshotSequence:
        windowSnapshotSequence ?? this.windowSnapshotSequence,
    locked: locked ?? this.locked,
    foregroundObjectId: clearForegroundObjectId
        ? null
        : foregroundObjectId ?? this.foregroundObjectId,
    activationRevision: activationRevision ?? this.activationRevision,
  );

  DenialWindow? get foregroundWindow {
    final window = windowByObjectId(foregroundObjectId);
    return window != null && window.isUserApp ? window : null;
  }

  DenialWindow? get primaryWindow => foregroundWindow;
  DenialWindow? get inputWindow => locked ? null : foregroundWindow;
  int get openAppWindowCount => openAppWindows.length;

  /// Looks up a neighbor without rebuilding the shared snapshot index.
  DenialWindow? adjacentAppWindow(int? objectId, int direction) {
    if (direction == 0 || openAppWindows.length < 2) return null;
    final currentIndex =
        _windowIndex.appIndex(objectId) ?? openAppWindows.length - 1;
    final targetIndex = currentIndex + direction.sign;
    return targetIndex >= 0 && targetIndex < openAppWindows.length
        ? openAppWindows[targetIndex]
        : null;
  }

  DenialWindow? windowByObjectId(int? objectId) =>
      objectId == null ? null : _windowIndex.byObjectId(objectId);

  DenialWindow? windowByWindowId(int windowId) =>
      _windowIndex.byWindowId(windowId);
}
