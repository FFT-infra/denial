import 'dart:convert';

import '../runtime_paths.dart';
import '../models/home_grid_item.dart';

class HomeLayoutRepository {
  const HomeLayoutRepository({required this._paths});

  final RuntimePaths _paths;

  Future<List<HomeLayoutSlot?>?> readSavedLayout() async {
    try {
      final file = await _paths.layoutFile();
      if (!await file.exists()) {
        return null;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }

      final rawSlots = decoded['slots'];
      if (rawSlots is! List) {
        return null;
      }

      return rawSlots.map(_decodeSlot).toList(growable: false);
    } on Object {
      return null;
    }
  }

  Future<void> saveLayout(List<HomeGridItem?> slots) async {
    try {
      final file = await _paths.layoutFile();
      final payload = jsonEncode({
        'version': 3,
        'slots': slots.map(_encodeSlot).toList(growable: false),
      });
      await file.writeAsString('$payload\n', flush: true);
    } on Object {
      // Layout persistence is best effort; the in-memory layout remains valid.
    }
  }

  HomeLayoutSlot? _decodeSlot(Object? item) {
    if (item is String && item.isNotEmpty) {
      return HomeLayoutSlot(id: item);
    }

    if (item is Map) {
      final id = item['id'];
      if (id is! String || id.isEmpty) {
        return null;
      }
      final colSpan = item['colSpan'];
      final rowSpan = item['rowSpan'];
      final name = item['name'];
      final apps = item['apps'];
      return HomeLayoutSlot(
        id: id,
        colSpan: colSpan is int ? colSpan : null,
        rowSpan: rowSpan is int ? rowSpan : null,
        name: name is String ? name : null,
        children: apps is List
            ? List<String>.unmodifiable(apps.whereType<String>())
            : null,
      );
    }

    return null;
  }

  Object? _encodeSlot(HomeGridItem? item) {
    if (item == null) {
      return null;
    }

    return switch (item.type) {
      HomeGridItemType.app => item.id,
      HomeGridItemType.clock => {
        'id': item.id,
        'colSpan': item.colSpan,
        'rowSpan': item.rowSpan,
      },
      HomeGridItemType.folder => {
        'id': item.id,
        'name': item.folderName,
        'apps': [for (final app in item.folderApps) app.id],
      },
    };
  }
}
