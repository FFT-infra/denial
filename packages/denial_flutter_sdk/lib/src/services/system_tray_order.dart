import 'dart:collection';

import '../models/system_tray_item.dart';

int compareSystemTrayItems(SystemTrayItem left, SystemTrayItem right) {
  final byStatus = _priority(left.status).compareTo(_priority(right.status));
  return byStatus != 0
      ? byStatus
      : left.title.toLowerCase().compareTo(right.title.toLowerCase());
}

List<SystemTrayItem> orderSystemTrayItems(Iterable<SystemTrayItem> items) {
  final ordered = items.toList(growable: false)..sort(compareSystemTrayItems);
  return UnmodifiableListView(ordered);
}

/// Native snapshots are already immutable and ordered by the shared comparator.
/// Reuse them directly when no legacy items exist; otherwise sort just the
/// legacy items and merge, retaining every item and icon object.
List<SystemTrayItem> combineSystemTrayItems(
  List<SystemTrayItem> nativeItems,
  Iterable<SystemTrayItem> legacyItems,
) {
  if (legacyItems.isEmpty) return nativeItems;
  final legacy = orderSystemTrayItems(legacyItems);
  if (nativeItems.isEmpty) return legacy;
  final merged = <SystemTrayItem>[];
  var nativeIndex = 0;
  var legacyIndex = 0;
  while (nativeIndex < nativeItems.length && legacyIndex < legacy.length) {
    if (compareSystemTrayItems(nativeItems[nativeIndex], legacy[legacyIndex]) <=
        0) {
      merged.add(nativeItems[nativeIndex++]);
    } else {
      merged.add(legacy[legacyIndex++]);
    }
  }
  while (nativeIndex < nativeItems.length) {
    merged.add(nativeItems[nativeIndex++]);
  }
  while (legacyIndex < legacy.length) {
    merged.add(legacy[legacyIndex++]);
  }
  return UnmodifiableListView(merged);
}

int _priority(SystemTrayStatus status) => switch (status) {
  SystemTrayStatus.needsAttention => 0,
  SystemTrayStatus.active => 1,
  SystemTrayStatus.passive => 2,
};
