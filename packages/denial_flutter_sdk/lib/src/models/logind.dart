import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

enum LogindAction {
  suspend('Suspend', 'sleep'),
  hibernate('Hibernate', 'sleep'),
  reboot('Reboot', 'shutdown'),
  powerOff('PowerOff', 'shutdown');

  const LogindAction(this.method, this.inhibitorClass);

  final String method;
  final String inhibitorClass;
}

enum LogindCapability {
  available,
  authenticationRequired,
  denied,
  unsupported,
  unavailable;

  bool get canRequest =>
      this == LogindCapability.available ||
      this == LogindCapability.authenticationRequired;
}

@immutable
class LogindInhibitor {
  LogindInhibitor({
    required Set<String> what,
    required this.who,
    required this.why,
    required this.mode,
    required this.uid,
    required this.pid,
  }) : what = Set<String>.unmodifiable(what);

  final Set<String> what;
  final String who;
  final String why;
  final String mode;
  final int uid;
  final int pid;

  bool affects(LogindAction action) => what.contains(action.inhibitorClass);

  bool blocks(LogindAction action) => mode == 'block' && affects(action);

  bool delays(LogindAction action) => mode == 'delay' && affects(action);

  String get description {
    if (who.isNotEmpty && why.isNotEmpty) {
      return '$who: $why';
    }
    if (why.isNotEmpty) {
      return why;
    }
    if (who.isNotEmpty) {
      return who;
    }
    return 'An application is preventing this action';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogindInhibitor &&
          const SetEquality<String>().equals(other.what, what) &&
          other.who == who &&
          other.why == why &&
          other.mode == mode &&
          other.uid == uid &&
          other.pid == pid;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(what.toList()..sort()),
    who,
    why,
    mode,
    uid,
    pid,
  );
}

@immutable
class LogindSnapshot {
  LogindSnapshot({
    required this.serviceAvailable,
    required Map<LogindAction, LogindCapability> capabilities,
    required List<LogindInhibitor> inhibitors,
  }) : capabilities = Map<LogindAction, LogindCapability>.unmodifiable(
         capabilities,
       ),
       inhibitors = List<LogindInhibitor>.unmodifiable(inhibitors);

  LogindSnapshot.unavailable()
    : serviceAvailable = false,
      capabilities = Map<LogindAction, LogindCapability>.unmodifiable(
        <LogindAction, LogindCapability>{
          for (final action in LogindAction.values)
            action: LogindCapability.unavailable,
        },
      ),
      inhibitors = const <LogindInhibitor>[];

  final bool serviceAvailable;
  final Map<LogindAction, LogindCapability> capabilities;
  final List<LogindInhibitor> inhibitors;

  LogindCapability capabilityFor(LogindAction action) =>
      capabilities[action] ?? LogindCapability.unavailable;

  List<LogindInhibitor> blockersFor(LogindAction action) => inhibitors
      .where((inhibitor) => inhibitor.blocks(action))
      .toList(growable: false);

  List<LogindInhibitor> delaysFor(LogindAction action) => inhibitors
      .where((inhibitor) => inhibitor.delays(action))
      .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogindSnapshot &&
          other.serviceAvailable == serviceAvailable &&
          const MapEquality<LogindAction, LogindCapability>().equals(
            other.capabilities,
            capabilities,
          ) &&
          const ListEquality<LogindInhibitor>().equals(
            other.inhibitors,
            inhibitors,
          );

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    Object.hashAll(
      LogindAction.values.map(
        (action) => Object.hash(action, capabilities[action]),
      ),
    ),
    Object.hashAll(inhibitors),
  );
}

abstract interface class LogindBackend {
  Stream<LogindSnapshot> get snapshots;

  LogindSnapshot get currentSnapshot;

  Future<void> start();

  Future<void> refresh();

  Future<void> perform(LogindAction action);

  Future<void> dispose();
}

class LogindActionUnavailableException implements Exception {
  const LogindActionUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
