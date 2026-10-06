part of 'status_notifier_service.dart';

class _StatusNotifierWorkerHost {
  _StatusNotifierDbusBackend? _backend;
  StreamSubscription<List<SystemTrayItem>>? _snapshots;
  SendPort? _events;
  StatusNotifierUpdateEncoder _updates = StatusNotifierUpdateEncoder();

  FutureOr<Object?> handle(int operation, Object? payload) async {
    return switch (operation) {
      _StatusNotifierWorkerOperation.start => _start(payload),
      _StatusNotifierWorkerOperation.invoke => _invoke(payload),
      _StatusNotifierWorkerOperation.loadMenu => _loadMenu(payload),
      _StatusNotifierWorkerOperation.activateMenuEntry => _activate(payload),
      _StatusNotifierWorkerOperation.dispose => _dispose(),
      _StatusNotifierWorkerOperation.resynchronize => _resynchronize(),
      _ => throw UnsupportedError(
        'Unknown StatusNotifier worker operation $operation',
      ),
    };
  }

  Future<Object?> _start(Object? payload) async {
    if (payload is! SendPort) {
      throw const FormatException('StatusNotifier event port is missing');
    }
    _updates = StatusNotifierUpdateEncoder();
    final existing = _backend;
    if (existing != null) {
      _events = payload;
      return StatusNotifierProtocol.encodeItems(existing.current);
    }
    final backend = _StatusNotifierDbusBackend(DBusClient.session());
    _backend = backend;
    _events = payload;
    _snapshots = backend.snapshots.listen((items) {
      _events?.send(_updates.encode(items));
    });
    try {
      await backend.start();
      return StatusNotifierProtocol.encodeItems(backend.current);
    } on Object {
      await _dispose();
      rethrow;
    }
  }

  Future<bool> _invoke(Object? payload) async {
    final backend = _requireBackend();
    if (payload is! List<Object?> ||
        payload.length != 4 ||
        payload[0] is! String ||
        payload[1] is! int ||
        payload[2] is! double ||
        payload[3] is! double) {
      throw const FormatException('Invalid StatusNotifier action');
    }
    final actionIndex = payload[1]! as int;
    if (actionIndex < 0 || actionIndex >= SystemTrayAction.values.length) {
      throw const FormatException('Invalid StatusNotifier action kind');
    }
    return backend.invoke(
      payload[0]! as String,
      SystemTrayAction.values[actionIndex],
      payload[2]! as double,
      payload[3]! as double,
    );
  }

  Future<Object?> _loadMenu(Object? payload) async {
    if (payload is! List<Object?> ||
        payload.length != 2 ||
        payload[0] is! String ||
        payload[1] is! int) {
      throw const FormatException('Invalid StatusNotifier menu request');
    }
    final entries = await _requireBackend().loadMenu(
      payload[0]! as String,
      parentId: payload[1]! as int,
    );
    return entries == null ? null : StatusNotifierProtocol.encodeMenu(entries);
  }

  Future<bool> _activate(Object? payload) async {
    if (payload is! List<Object?> ||
        payload.length != 2 ||
        payload[0] is! String ||
        payload[1] is! int) {
      throw const FormatException('Invalid StatusNotifier menu action');
    }
    return _requireBackend().activateMenuEntry(
      payload[0]! as String,
      payload[1]! as int,
    );
  }

  _StatusNotifierDbusBackend _requireBackend() {
    return _backend ??
        (throw StateError('StatusNotifier worker has not been started'));
  }

  Object? _resynchronize() {
    final backend = _requireBackend();
    // Resets use the event port too, preserving order relative to later deltas.
    _events?.send(_updates.encode(backend.current, reset: true));
    return null;
  }

  Future<Object?> _dispose() async {
    _events = null;
    await _snapshots?.cancel();
    _snapshots = null;
    final backend = _backend;
    _backend = null;
    await backend?.dispose();
    return null;
  }
}

@visibleForTesting
Object encodeStatusNotifierMenuEntriesForTesting(
  List<SystemTrayMenuEntry> entries,
) => StatusNotifierProtocol.encodeMenu(entries);

@visibleForTesting
List<SystemTrayMenuEntry>? decodeStatusNotifierMenuEntriesForTesting(
  Object? response,
) => StatusNotifierProtocol.decodeMenu(response);
