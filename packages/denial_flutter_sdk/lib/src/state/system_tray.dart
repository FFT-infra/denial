import 'dart:async';
import 'dart:ui' show Offset;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/system_tray_item.dart';
import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';
import '../services/status_notifier_service.dart';
import '../services/system_tray_order.dart';
import 'notifier_lifecycle.dart';

final statusNotifierServiceProvider = Provider<StatusNotifierService>((ref) {
  final service = StatusNotifierService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final systemTrayProvider =
    NotifierProvider<SystemTrayController, List<SystemTrayItem>>(
      SystemTrayController.new,
    );

class SystemTrayController extends Notifier<List<SystemTrayItem>>
    with NotifierLifecycle<List<SystemTrayItem>> {
  @override
  List<SystemTrayItem> build() {
    _bridge = ref.watch(denialBridgeProvider);
    final service = ref.watch(statusNotifierServiceProvider);
    _statusNotifier = service;
    final generation = beginBuildGeneration();
    _statusItems = service.current;
    _xembedItems = Map<int, SystemTrayItem>.of(_bridge.xembedTrayItems);
    final statusSubscription = service.snapshots.listen((items) {
      if (isBuildGenerationActive(generation)) {
        _statusItems = items;
        _publish();
      }
    });
    final xembedSubscription = _bridge.xembedTrayEvents.listen((event) {
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      if (event.kind == XEmbedTrayEventKind.removed) {
        if (_xembedItems.remove(event.windowId) == null) return;
      } else if (event.item case final item?) {
        if (identical(_xembedItems[event.windowId], item)) return;
        _xembedItems[event.windowId] = item;
      } else {
        return;
      }
      _publish();
    });
    cancelOnDispose(statusSubscription);
    cancelOnDispose(xembedSubscription);
    scheduleMicrotask(() async {
      if (!isBuildGenerationActive(generation)) return;
      try {
        await service.start();
        if (isBuildGenerationActive(generation)) {
          _statusItems = service.current;
          _publish();
        }
      } on Object {
        // XEmbed remains usable when the session bus is unavailable or a
        // stricter host already owns the watcher name.
      }
    });
    return _combinedItems();
  }

  late DenialBridge _bridge;
  late StatusNotifierService _statusNotifier;
  List<SystemTrayItem> _statusItems = const <SystemTrayItem>[];
  Map<int, SystemTrayItem> _xembedItems = <int, SystemTrayItem>{};

  Future<bool> invoke(
    SystemTrayItem item,
    SystemTrayAction action,
    Offset position,
  ) async {
    if (item.source == SystemTrayItemSource.statusNotifier) {
      return _statusNotifier.invoke(item, action, position);
    }
    final prefix = 'xembed:';
    final windowId = item.id.startsWith(prefix)
        ? int.tryParse(item.id.substring(prefix.length))
        : null;
    if (windowId != null) {
      _bridge.invokeXEmbedTrayAction(windowId, action, position);
      return true;
    }
    return false;
  }

  Future<List<SystemTrayMenuEntry>?> loadMenu(
    SystemTrayItem item, {
    int parentId = 0,
  }) {
    if (item.source != SystemTrayItemSource.statusNotifier) {
      return Future<List<SystemTrayMenuEntry>?>.value(null);
    }
    return _statusNotifier.loadMenu(item, parentId: parentId);
  }

  Future<bool> activateMenuEntry(SystemTrayItem item, int entryId) {
    if (item.source != SystemTrayItemSource.statusNotifier) {
      return Future<bool>.value(false);
    }
    return _statusNotifier.activateMenuEntry(item, entryId);
  }

  void _publish() {
    final next = _combinedItems();
    if (!const ListEquality<SystemTrayItem>().equals(state, next)) {
      state = next;
    }
  }

  List<SystemTrayItem> _combinedItems() =>
      combineSystemTrayItems(_statusItems, _xembedItems.values);
}
