import 'dart:async';

import 'package:dbus/dbus.dart';

import '../models/logind.dart';
import 'logind_protocol.dart';

export '../models/logind.dart';
export 'logind_protocol.dart';

class LogindService implements LogindBackend {
  factory LogindService({DBusClient? client}) {
    return LogindService._(client ?? DBusClient.system());
  }

  LogindService._(this._client)
    : _manager = DBusRemoteObject(
        _client,
        name: _serviceName,
        path: DBusObjectPath(_managerPath),
      );

  static const String _serviceName = 'org.freedesktop.login1';
  static const String _managerPath = '/org/freedesktop/login1';
  static const String _managerInterface = 'org.freedesktop.login1.Manager';
  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _actionTimeout = Duration(seconds: 30);
  static const Duration _signalCoalesce = Duration(milliseconds: 75);

  final DBusClient _client;
  final DBusRemoteObject _manager;
  final StreamController<LogindSnapshot> _snapshots =
      StreamController<LogindSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusSignal>? _signalSubscription;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  Timer? _refreshTimer;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  Completer<void>? _refreshSettled;
  LogindSnapshot _current = LogindSnapshot.unavailable();

  @override
  Stream<LogindSnapshot> get snapshots => _snapshots.stream;

  @override
  LogindSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _signalSubscription = DBusSignalStream(
      _client,
      sender: _serviceName,
      path: DBusObjectPath(_managerPath),
    ).listen((_) => _scheduleRefresh(), onError: (_) => _scheduleRefresh());
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name == _serviceName)
        .listen((event) {
          if (event.newOwner == null) {
            _refreshTimer?.cancel();
            _emit(LogindSnapshot.unavailable());
          } else {
            _scheduleRefresh(immediate: true);
          }
        });
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    if (_refreshing) {
      _refreshAgain = true;
      final settled = _refreshSettled ??= Completer<void>();
      await settled.future;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        try {
          final snapshot = await _readSnapshot();
          if (!_disposed) {
            _emit(snapshot);
          }
        } on Object {
          if (!_disposed) {
            _emit(LogindSnapshot.unavailable());
          }
        }
      } while (_refreshAgain && !_disposed);
    } finally {
      _refreshing = false;
      final settled = _refreshSettled;
      _refreshSettled = null;
      if (settled != null && !settled.isCompleted) {
        settled.complete();
      }
    }
  }

  @override
  Future<void> perform(LogindAction action) async {
    if (_disposed) {
      throw const LogindActionUnavailableException(
        'The session service is unavailable',
      );
    }

    // Capability and inhibitor state is intentionally refreshed immediately
    // before a system-changing request. There is no reliable inhibitor-change
    // signal in logind, so this one-shot read is the authoritative guard.
    await refresh();
    if (_disposed) {
      throw const LogindActionUnavailableException(
        'The session service is unavailable',
      );
    }
    final capability = _current.capabilityFor(action);
    if (!capability.canRequest) {
      throw LogindActionUnavailableException(_capabilityFailure(capability));
    }
    for (final inhibitor in _current.inhibitors) {
      if (inhibitor.blocks(action)) {
        throw LogindActionUnavailableException(inhibitor.description);
      }
    }

    await _manager
        .callMethod(_managerInterface, action.method, const <DBusValue>[
          DBusBoolean(true),
        ], replySignature: DBusSignature(''))
        .timeout(_actionTimeout);
  }

  Future<LogindSnapshot> _readSnapshot() async {
    final replies = await Future.wait<DBusMethodSuccessResponse>(
      <Future<DBusMethodSuccessResponse>>[
        for (final action in LogindAction.values)
          _manager
              .callMethod(
                _managerInterface,
                'Can${action.method}',
                const <DBusValue>[],
                replySignature: DBusSignature('s'),
              )
              .timeout(_readTimeout),
        _manager
            .callMethod(
              _managerInterface,
              'ListInhibitors',
              const <DBusValue>[],
              replySignature: DBusSignature('a(ssssuu)'),
            )
            .timeout(_readTimeout),
      ],
    );

    final capabilities = <LogindAction, LogindCapability>{};
    for (var index = 0; index < LogindAction.values.length; index += 1) {
      final values = replies[index].returnValues;
      capabilities[LogindAction.values[index]] = values.length == 1
          ? parseLogindCapability(values.single.asString())
          : LogindCapability.unavailable;
    }
    final inhibitorValues = replies.last.returnValues;
    final inhibitors = inhibitorValues.length == 1
        ? parseLogindInhibitors(inhibitorValues.single)
        : const <LogindInhibitor>[];
    return LogindSnapshot(
      serviceAvailable: true,
      capabilities: capabilities,
      inhibitors: inhibitors,
    );
  }

  void _scheduleRefresh({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer(immediate ? Duration.zero : _signalCoalesce, () {
      _refreshTimer = null;
      unawaited(refresh());
    });
  }

  void _emit(LogindSnapshot snapshot) {
    if (snapshot == _current) {
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
    _refreshTimer?.cancel();
    await _signalSubscription?.cancel();
    await _ownerSubscription?.cancel();
    await _snapshots.close();
    await _client.close();
  }
}

String _capabilityFailure(LogindCapability capability) => switch (capability) {
  LogindCapability.denied => 'This action is not authorized',
  LogindCapability.unsupported => 'This action is not supported',
  _ => 'The session service is unavailable',
};
