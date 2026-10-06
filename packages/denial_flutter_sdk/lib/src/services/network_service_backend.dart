import 'dart:async';

import 'package:dbus/dbus.dart';

import 'iwd_service.dart';
import 'network_manager_service.dart';

/// Selects one authoritative Wi-Fi manager for the lifetime of each service
/// owner. NetworkManager wins when both names exist because it may itself be
/// using iwd; direct iwd access is enabled only when NetworkManager is absent.
class NetworkService implements NetworkBackend {
  NetworkService({
    DBusClient? client,
    NetworkBackend Function()? networkManagerFactory,
    NetworkBackend Function()? iwdFactory,
  }) : _client = client ?? DBusClient.system(),
       _createNetworkManager =
           networkManagerFactory ?? NetworkManagerService.new,
       _createIwd = iwdFactory ?? IwdService.new;

  static const String _networkManagerName = 'org.freedesktop.NetworkManager';
  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _selectionCoalesce = Duration(milliseconds: 55);

  final DBusClient _client;
  final NetworkBackend Function() _createNetworkManager;
  final NetworkBackend Function() _createIwd;
  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerChanges;
  StreamSubscription<NetworkSnapshot>? _backendSnapshots;
  NetworkBackend? _backend;
  String? _backendName;
  Timer? _selectionTimer;
  Future<void> _transition = Future<void>.value();
  Completer<void>? _selectionCompletion;
  bool _selectionPending = false;
  bool _refreshCurrentPending = false;
  NetworkSnapshot _current = const NetworkSnapshot.unavailable();
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    if (_started) return _selectionCompletion?.future ?? _transition;
    _started = true;
    _ownerChanges = _client.nameOwnerChanged
        .where(
          (event) =>
              event.name == _networkManagerName ||
              event.name == IwdService.serviceName,
        )
        .listen((_) => _scheduleSelection());
    return _queueSelection(refreshCurrent: false);
  }

  @override
  Future<void> refresh() {
    if (!_started) return start();
    return _queueSelection(refreshCurrent: true);
  }

  Future<void> _selectBackend({required bool refreshCurrent}) async {
    if (_disposed) {
      return;
    }
    final preferred = await _preferredBackend();
    if (_disposed) return;
    if (preferred == _backendName) {
      if (refreshCurrent) {
        await _backend?.refresh();
        _emit(_backend?.currentSnapshot ?? const NetworkSnapshot.unavailable());
      }
      return;
    }

    await _backendSnapshots?.cancel();
    _backendSnapshots = null;
    await _backend?.dispose();
    _backend = null;
    _backendName = null;

    if (preferred == null || _disposed) {
      _emit(const NetworkSnapshot.unavailable());
      return;
    }

    final backend = preferred == _networkManagerName
        ? _createNetworkManager()
        : _createIwd();
    _backend = backend;
    _backendName = preferred;
    try {
      _backendSnapshots = backend.snapshots.listen(_emit);
      await backend.start();
      _emit(backend.currentSnapshot);
    } on Object {
      await _backendSnapshots?.cancel();
      _backendSnapshots = null;
      await backend.dispose();
      _backend = null;
      _backendName = null;
      _emit(const NetworkSnapshot.unavailable());
    }
  }

  Future<String?> _preferredBackend() async {
    try {
      if (await _client
          .nameHasOwner(_networkManagerName)
          .timeout(_readTimeout)) {
        return _networkManagerName;
      }
      if (_disposed) return null;
      if (await _client
          .nameHasOwner(IwdService.serviceName)
          .timeout(_readTimeout)) {
        return IwdService.serviceName;
      }
    } on Object {
      return null;
    }
    return null;
  }

  void _scheduleSelection() {
    if (_disposed) {
      return;
    }
    _selectionTimer?.cancel();
    _selectionTimer = Timer(_selectionCoalesce, () {
      _selectionTimer = null;
      // Signals have no caller to receive a refresh failure. A later signal or
      // explicit refresh can retry; keep the current backend in the meantime.
      unawaited(
        _queueSelection(refreshCurrent: true).catchError((Object _) {}),
      );
    });
  }

  // One active selection and one pending selection, regardless of burst size.
  // Callers share completion of the whole drain so actions see the latest
  // selected backend, including a topology change received during a refresh.
  Future<void> _queueSelection({required bool refreshCurrent}) {
    if (_disposed) return Future<void>.value();
    _selectionTimer?.cancel();
    _selectionTimer = null;
    _selectionPending = true;
    _refreshCurrentPending |= refreshCurrent;
    if (_selectionCompletion case final completion?) return completion.future;
    final completion = _selectionCompletion = Completer<void>();
    _transition = completion.future.then<void>((_) {}, onError: (_, _) {});
    unawaited(_drainSelections(completion));
    return completion.future;
  }

  Future<void> _drainSelections(Completer<void> completion) async {
    Object? failure;
    StackTrace? failureStack;
    while (_selectionPending && !_disposed) {
      final refreshCurrent = _refreshCurrentPending;
      _selectionPending = false;
      _refreshCurrentPending = false;
      try {
        await _selectBackend(refreshCurrent: refreshCurrent);
        failure = null;
        failureStack = null;
      } on Object catch (error, stackTrace) {
        // A failed read must not drop a newer request already waiting for it.
        failure = error;
        failureStack = stackTrace;
      }
    }
    _selectionCompletion = null;
    if (failure != null) {
      completion.completeError(failure, failureStack);
    } else {
      completion.complete();
    }
  }

  Future<NetworkBackend> _activeBackend() async {
    await _transition;
    final backend = _backend;
    if (_disposed || backend == null) {
      throw StateError('No supported network service is available');
    }
    return backend;
  }

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    await (await _activeBackend()).setWirelessEnabled(enabled);
  }

  @override
  Future<void> requestScan() async {
    await (await _activeBackend()).requestScan();
  }

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    await (await _activeBackend()).connect(network, password: password);
  }

  @override
  Future<void> disconnect() async {
    await (await _activeBackend()).disconnect();
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    await (await _activeBackend()).forget(network);
  }

  void _emit(NetworkSnapshot snapshot) {
    if (_disposed || snapshot == _current) {
      return;
    }
    _current = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _selectionPending = false;
    _refreshCurrentPending = false;
    _selectionTimer?.cancel();
    await _ownerChanges?.cancel();
    await _transition;
    await _backendSnapshots?.cancel();
    await _backend?.dispose();
    await _snapshots.close();
    await _client.close();
  }
}
