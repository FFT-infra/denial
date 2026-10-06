import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';

class InputLayoutSnapshot {
  const InputLayoutSnapshot({
    required this.epoch,
    required this.shellRegions,
    required this.windows,
    this.visibleSurfaceIds = const <int>[],
    this.softwareKeyboardRegions = const <Rect>[],
    this.keyboardCapture = false,
    this.exclusiveShellMode = false,
    this.observeClientPointerPresses = false,
  });

  final int epoch;
  final List<Rect> shellRegions;
  final List<InputWindowRegion> windows;
  final List<int> visibleSurfaceIds;
  final List<Rect> softwareKeyboardRegions;
  final bool keyboardCapture;
  final bool exclusiveShellMode;
  final bool observeClientPointerPresses;

  bool hasSameRoutingAs(InputLayoutSnapshot other) {
    if (keyboardCapture != other.keyboardCapture ||
        exclusiveShellMode != other.exclusiveShellMode ||
        observeClientPointerPresses != other.observeClientPointerPresses ||
        shellRegions.length != other.shellRegions.length ||
        softwareKeyboardRegions.length !=
            other.softwareKeyboardRegions.length ||
        windows.length != other.windows.length ||
        visibleSurfaceIds.length != other.visibleSurfaceIds.length) {
      return false;
    }
    for (var index = 0; index < shellRegions.length; index += 1) {
      if (!_sameWireRect(shellRegions[index], other.shellRegions[index])) {
        return false;
      }
    }
    for (var index = 0; index < softwareKeyboardRegions.length; index += 1) {
      if (!_sameWireRect(
        softwareKeyboardRegions[index],
        other.softwareKeyboardRegions[index],
      )) {
        return false;
      }
    }
    for (var index = 0; index < windows.length; index += 1) {
      if (!windows[index].hasSameRoutingAs(other.windows[index])) {
        return false;
      }
    }
    for (var index = 0; index < visibleSurfaceIds.length; index += 1) {
      if (visibleSurfaceIds[index] != other.visibleSurfaceIds[index]) {
        return false;
      }
    }
    return true;
  }
}

class InputWindowRegion {
  const InputWindowRegion({
    required this.window,
    required this.rect,
    required this.sourceRect,
    required this.z,
    this.surfaceId,
    this.visible = true,
    this.hitTest = true,
    this.geometryLocked = false,
  });

  final DenialWindow window;
  final Rect rect;
  final Rect sourceRect;
  final int z;
  final int? surfaceId;
  final bool visible;
  final bool hitTest;
  final bool geometryLocked;

  int get targetSurfaceId => surfaceId ?? window.surfaceId;

  bool hasSameRoutingAs(InputWindowRegion other) {
    return window.objectId == other.window.objectId &&
        targetSurfaceId == other.targetSurfaceId &&
        window.windowId == other.window.windowId &&
        z == other.z &&
        visible == other.visible &&
        hitTest == other.hitTest &&
        geometryLocked == other.geometryLocked &&
        _sameWireRect(rect, other.rect) &&
        _sameWireRect(sourceRect, other.sourceRect);
  }
}

bool _sameWireRect(Rect left, Rect right) {
  return _sameWireCoordinate(left.left, right.left) &&
      _sameWireCoordinate(left.top, right.top) &&
      _sameWireCoordinate(left.width, right.width) &&
      _sameWireCoordinate(left.height, right.height);
}

bool _sameWireCoordinate(double left, double right) {
  if (left == right) {
    return true;
  }
  if (!left.isFinite || !right.isFinite) {
    return false;
  }
  return (left * 1000).round() == (right * 1000).round();
}
