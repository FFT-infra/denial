import 'dart:collection';

import '../models/denial_window.dart';

/// Owns one window snapshot and the lookups shared by event dispatch and UI.
/// Gesture, focus and panel updates retain this index until windows change.
final class ShellWindowIndex {
  factory ShellWindowIndex(Iterable<DenialWindow> source) {
    final windows = List<DenialWindow>.unmodifiable(source);
    final byObjectId = <int, DenialWindow>{};
    final byWindowId = <int, DenialWindow>{};
    final apps = <DenialWindow>[];
    final appIndices = <int, int>{};
    for (final window in windows) {
      byObjectId[window.objectId] = window;
      // Preserve the first-match semantics of the previous native-ID scan.
      byWindowId.putIfAbsent(window.windowId, () => window);
      if (window.isUserApp) {
        appIndices[window.objectId] = apps.length;
        apps.add(window);
      }
    }
    return ShellWindowIndex._(
      windows,
      List<DenialWindow>.unmodifiable(apps),
      byObjectId,
      byWindowId,
      appIndices,
    );
  }

  ShellWindowIndex._(
    this.windows,
    this.apps,
    this._byObjectId,
    this._byWindowId,
    this._appIndices,
  );

  final List<DenialWindow> windows;
  final List<DenialWindow> apps;
  // Desktop-only projections are computed on first use, then retained across
  // gesture and placement updates that keep the same native window snapshot.
  late final Map<int, DenialWindow> appsByObjectId = UnmodifiableMapView({
    for (final window in apps) window.objectId: window,
  });
  late final List<DenialWindow> positionedPopupSurfaces = List.unmodifiable(
    windows.where((window) => window.isPopupSurface && window.geometry != null),
  );
  // These maps are created internally and never exposed or mutated.
  final Map<int, DenialWindow> _byObjectId;
  final Map<int, DenialWindow> _byWindowId;
  final Map<int, int> _appIndices;

  DenialWindow? byObjectId(int? objectId) => _byObjectId[objectId];

  DenialWindow? byWindowId(int windowId) => _byWindowId[windowId];

  int? appIndex(int? objectId) => _appIndices[objectId];
}
