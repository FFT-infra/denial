import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/system_tray_item.dart';

/// Incremental snapshots travel only on the worker's ordered event port.
/// Pixel-bearing frames are `[reset, ordered IDs, changed items]`; true in an
/// item's pixmap slot reuses its previous pixels. Null explicitly removes it.
/// Snapshots without pixels send immutable model objects directly.
final class StatusNotifierUpdateEncoder {
  Map<String, SystemTrayItem>? _previous;

  Object encode(List<SystemTrayItem> items, {bool reset = false}) {
    var hasPixmap = false;
    final ids = <String>{};
    for (final item in items) {
      if (!ids.add(item.id)) {
        throw const FormatException('Duplicate StatusNotifier item ID');
      }
      hasPixmap = hasPixmap || item.iconPixmap != null;
    }
    if (!hasPixmap) {
      // Plain immutable metadata is directly sendable between these isolates.
      // Avoid row conversion and delta caches when there are no pixels to save.
      _previous = null;
      return _StatusNotifierFullSnapshot(items);
    }
    reset = reset || _previous == null;
    final previous = reset ? const <String, SystemTrayItem>{} : _previous!;
    final next = <String, SystemTrayItem>{};
    final order = <String>[];
    final changed = <Object?>[];
    for (final item in items) {
      next[item.id] = item;
      order.add(item.id);
      final prior = previous[item.id];
      if (!identical(prior, item) && prior != item) {
        changed.add(
          _encodeTrayItem(
            item,
            reusePixmap:
                prior?.iconPixmap != null &&
                prior!.iconPixmap == item.iconPixmap,
          ),
        );
      }
    }
    _previous = next;
    return [reset, order, changed];
  }
}

/// Applies a frame atomically and retains unchanged objects and pixel buffers.
/// A malformed frame requires a full reset, so later deltas cannot silently
/// refer to stale metadata or pixels from before the rejected update.
final class StatusNotifierUpdateDecoder {
  Map<String, SystemTrayItem> _items = {};
  bool _needsReset = true;

  List<SystemTrayItem> decode(Object? message) {
    try {
      return _decode(message);
    } on Object {
      _needsReset = true;
      rethrow;
    }
  }

  List<SystemTrayItem> _decode(Object? message) {
    if (message case _StatusNotifierFullSnapshot(:final items)) {
      _items = {};
      _needsReset = true;
      return items;
    }
    if (message case [bool reset, List<Object?> order, List<Object?> changed]) {
      if (_needsReset && !reset) {
        throw const FormatException('StatusNotifier snapshot reset required');
      }
      final previous = reset ? const <String, SystemTrayItem>{} : _items;
      final updates = <String, SystemTrayItem>{};
      for (final row in changed) {
        if (row case [String id, ...]) {
          if (updates.containsKey(id)) {
            throw const FormatException('Duplicate StatusNotifier update');
          }
          updates[id] = _decodeTrayItem(row, previous: previous[id]);
        } else {
          throw const FormatException('Invalid StatusNotifier item');
        }
      }
      final next = <String, SystemTrayItem>{};
      final items = <SystemTrayItem>[];
      for (final id in order) {
        if (id is! String || next.containsKey(id)) {
          throw const FormatException('Invalid StatusNotifier item order');
        }
        final item = updates.remove(id) ?? previous[id];
        if (item == null) {
          throw const FormatException('Missing StatusNotifier item');
        }
        next[id] = item;
        items.add(item);
      }
      if (updates.isNotEmpty) {
        throw const FormatException('Unordered StatusNotifier update');
      }
      _items = next;
      _needsReset = false;
      return UnmodifiableListView(items);
    }
    throw const FormatException('Invalid StatusNotifier update frame');
  }
}

final class _StatusNotifierFullSnapshot {
  _StatusNotifierFullSnapshot(List<SystemTrayItem> items)
    : items = List<SystemTrayItem>.unmodifiable(items);

  final List<SystemTrayItem> items;
}

/// Values crossing the tray worker boundary. Full snapshots are self-contained.
abstract final class StatusNotifierProtocol {
  static List<Object?> encodeItems(List<SystemTrayItem> items) =>
      _encodeTrayItems(items);
  static List<SystemTrayItem> decodeItems(Object? response) =>
      _decodeTrayItems(response);
  static List<Object?> encodeMenu(List<SystemTrayMenuEntry> entries) =>
      _encodeMenuEntries(entries);
  static List<SystemTrayMenuEntry>? decodeMenu(Object? response) =>
      _decodeMenuEntries(response);
}

List<Object?> _encodeTrayItems(List<SystemTrayItem> items) => <Object?>[
  for (final item in items) _encodeTrayItem(item),
];

List<Object?> _encodeTrayItem(SystemTrayItem item, {bool reusePixmap = false}) {
  final pixmap = item.iconPixmap;
  return <Object?>[
    item.id,
    item.source.index,
    item.title,
    item.status.index,
    item.iconName,
    item.iconThemePath,
    pixmap == null
        ? null
        : reusePixmap
        ? true
        : <Object?>[
            pixmap.width,
            pixmap.height,
            TransferableTypedData.fromList(<Uint8List>[pixmap.rgba]),
          ],
    item.menuAvailable,
    item.primaryOpensMenu,
    item.menuPath,
  ];
}

List<SystemTrayItem> _decodeTrayItems(Object? response) {
  if (response is! List<Object?>) {
    throw const FormatException('Invalid StatusNotifier snapshot');
  }
  return List<SystemTrayItem>.unmodifiable(response.map(_decodeTrayItem));
}

SystemTrayItem _decodeTrayItem(Object? response, {SystemTrayItem? previous}) {
  if (response case [
    String id,
    int sourceIndex,
    String title,
    int statusIndex,
    String iconName,
    String iconThemePath,
    final pixmap,
    bool menuAvailable,
    bool primaryOpensMenu,
    String menuPath,
  ]) {
    if (sourceIndex < 0 ||
        sourceIndex >= SystemTrayItemSource.values.length ||
        statusIndex < 0 ||
        statusIndex >= SystemTrayStatus.values.length) {
      throw const FormatException('Invalid StatusNotifier item enum');
    }
    final icon = pixmap == true
        ? previous?.iconPixmap
        : _decodeTrayPixmap(pixmap);
    if (pixmap == true && icon == null) {
      throw const FormatException('Missing retained StatusNotifier pixmap');
    }
    return SystemTrayItem(
      id: id,
      source: SystemTrayItemSource.values[sourceIndex],
      title: title,
      status: SystemTrayStatus.values[statusIndex],
      iconName: iconName,
      iconThemePath: iconThemePath,
      iconPixmap: icon,
      menuAvailable: menuAvailable,
      primaryOpensMenu: primaryOpensMenu,
      menuPath: menuPath,
    );
  }
  throw const FormatException('Invalid StatusNotifier item');
}

SystemTrayIconPixmap? _decodeTrayPixmap(Object? response) {
  if (response == null) {
    return null;
  }
  if (response is! List<Object?> ||
      response.length != 3 ||
      response[0] is! int ||
      response[1] is! int ||
      response[2] is! TransferableTypedData) {
    throw const FormatException('Invalid StatusNotifier pixmap');
  }
  final width = response[0]! as int;
  final height = response[1]! as int;
  final rgba = (response[2]! as TransferableTypedData)
      .materialize()
      .asUint8List();
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw const FormatException('Invalid StatusNotifier pixmap dimensions');
  }
  return SystemTrayIconPixmap(width: width, height: height, rgba: rgba);
}

List<Object?> _encodeMenuEntries(List<SystemTrayMenuEntry> entries) =>
    <Object?>[for (final entry in entries) _encodeMenuEntry(entry)];

List<Object?> _encodeMenuEntry(SystemTrayMenuEntry entry) => <Object?>[
  entry.id,
  entry.label,
  entry.enabled,
  entry.visible,
  entry.separator,
  entry.toggleType.index,
  entry.toggleState,
  entry.destructive,
  entry.hasSubmenu,
  _encodeMenuEntries(entry.children),
];

List<SystemTrayMenuEntry>? _decodeMenuEntries(Object? response) {
  if (response == null) {
    return null;
  }
  if (response is! List<Object?>) {
    throw const FormatException('Invalid StatusNotifier menu');
  }
  return List<SystemTrayMenuEntry>.unmodifiable(response.map(_decodeMenuEntry));
}

SystemTrayMenuEntry _decodeMenuEntry(Object? response) {
  if (response is! List<Object?> ||
      response.length != 10 ||
      response[0] is! int ||
      response[1] is! String ||
      response[2] is! bool ||
      response[3] is! bool ||
      response[4] is! bool ||
      response[5] is! int ||
      response[6] is! int ||
      response[7] is! bool ||
      response[8] is! bool) {
    throw const FormatException('Invalid StatusNotifier menu entry');
  }
  final toggleIndex = response[5]! as int;
  if (toggleIndex < 0 ||
      toggleIndex >= SystemTrayMenuToggleType.values.length) {
    throw const FormatException('Invalid StatusNotifier menu toggle');
  }
  return SystemTrayMenuEntry(
    id: response[0]! as int,
    label: response[1]! as String,
    enabled: response[2]! as bool,
    visible: response[3]! as bool,
    separator: response[4]! as bool,
    toggleType: SystemTrayMenuToggleType.values[toggleIndex],
    toggleState: response[6]! as int,
    destructive: response[7]! as bool,
    hasSubmenu: response[8]! as bool,
    children: _decodeMenuEntries(response[9]) ?? const <SystemTrayMenuEntry>[],
  );
}
