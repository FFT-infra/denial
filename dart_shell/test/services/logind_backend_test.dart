import 'package:denial_flutter_sdk/service_backends.dart' show LogindService;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:test/test.dart';

void main() {
  test('capabilities and inhibitors are read concurrently', () async {
    final gate = Completer<void>();
    final client = _Client()..beforeRead = (_) => gate.future;
    final service = LogindService(client: client);
    try {
      final refresh = service.refresh();
      expect(client.reads, [
        'CanSuspend',
        'CanHibernate',
        'CanReboot',
        'CanPowerOff',
        'ListInhibitors',
      ]);
      gate.complete();
      await refresh;
      expect(service.currentSnapshot.serviceAvailable, isTrue);
      expect(
        service.currentSnapshot.capabilityFor(LogindAction.reboot),
        LogindCapability.available,
      );
    } finally {
      if (!gate.isCompleted) gate.complete();
      await service.dispose();
    }
  });

  test(
    'a pending action waits for the coalesced fresh inhibitor read',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final client = _Client();
      client.beforeRead = (_) =>
          client.reads.length <= 5 ? firstGate.future : secondGate.future;
      final service = LogindService(client: client);
      try {
        final refresh = service.refresh();
        final action = service.perform(LogindAction.reboot);
        final rejected = expectLater(
          action,
          throwsA(isA<LogindActionUnavailableException>()),
        );
        firstGate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(client.reads, hasLength(10));
        expect(client.actions, isEmpty);
        client.inhibitors = [_inhibitor('block')];
        secondGate.complete();
        await refresh;
        await rejected;
        expect(client.actions, isEmpty);
      } finally {
        if (!firstGate.isCompleted) firstGate.complete();
        if (!secondGate.isCompleted) secondGate.complete();
        await service.dispose();
      }
    },
  );

  test(
    'denied capabilities block actions and delay inhibitors do not',
    () async {
      final client = _Client()..capability = 'no';
      final service = LogindService(client: client);
      try {
        await expectLater(
          service.perform(LogindAction.reboot),
          throwsA(isA<LogindActionUnavailableException>()),
        );
        expect(client.actions, isEmpty);
        client.capability = 'challenge';
        client.inhibitors = [_inhibitor('delay')];
        await service.perform(LogindAction.reboot);
        expect(client.actions, ['Reboot']);
        expect(client.interactiveArguments, [const DBusBoolean(true)]);
      } finally {
        await service.dispose();
      }
    },
  );

  test('disposal during preflight prevents a later action dispatch', () async {
    final gate = Completer<void>();
    final client = _Client();
    final service = LogindService(client: client);
    await service.refresh();
    client.beforeRead = (_) => gate.future;
    final action = service.perform(LogindAction.reboot);
    final rejected = expectLater(
      action,
      throwsA(isA<LogindActionUnavailableException>()),
    );
    await service.dispose();
    gate.complete();
    await rejected;
    expect(client.actions, isEmpty);
  });

  test('unchanged refreshes retain the snapshot and emit only once', () async {
    final client = _Client()..inhibitors = [_inhibitor('delay')];
    final service = LogindService(client: client);
    final events = <LogindSnapshot>[];
    final subscription = service.snapshots.listen(events.add);
    try {
      await service.refresh();
      final first = service.currentSnapshot;
      await service.refresh();
      expect(service.currentSnapshot, same(first));
      expect(events, [first]);
    } finally {
      await subscription.cancel();
      await service.dispose();
    }
  });
}

DBusStruct _inhibitor(String mode) => DBusStruct([
  const DBusString('shutdown'),
  const DBusString('Test'),
  const DBusString('Testing'),
  DBusString(mode),
  const DBusUint32(1000),
  const DBusUint32(2000),
]);

// In-memory replies only. This client never opens a bus or controls a session.
class _Client implements DBusClient {
  final reads = <String>[];
  final actions = <String>[];
  List<DBusValue> interactiveArguments = [];
  String capability = 'yes';
  List<DBusValue> inhibitors = [];
  Future<void> Function(String name)? beforeRead;

  @override
  Future<DBusMethodSuccessResponse> callMethod({
    String? destination,
    required DBusObjectPath path,
    String? interface,
    required String name,
    Iterable<DBusValue> values = const [],
    DBusSignature? replySignature,
    bool noReplyExpected = false,
    bool noAutoStart = false,
    bool allowInteractiveAuthorization = false,
  }) async {
    if (name.startsWith('Can') || name == 'ListInhibitors') {
      reads.add(name);
      await beforeRead?.call(name);
      return DBusMethodSuccessResponse([
        if (name == 'ListInhibitors')
          DBusArray(DBusSignature('(ssssuu)'), inhibitors)
        else
          DBusString(capability),
      ]);
    }
    if (name != 'Reboot') throw StateError('Unexpected method $name');
    actions.add(name);
    interactiveArguments = values.toList();
    return DBusMethodSuccessResponse();
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
