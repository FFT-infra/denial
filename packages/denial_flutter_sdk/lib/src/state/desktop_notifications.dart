import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/launcher_providers.dart';
import '../models/desktop_notification.dart';
import '../platform/denial_bridge_provider.dart';
import '../services/notification_policy_repository.dart';
import 'desktop_notification_reducer.dart';
import 'desktop_notifications_state.dart';
import 'notifier_lifecycle.dart';

export 'desktop_notifications_state.dart';

final notificationPolicyStoreProvider = Provider<NotificationPolicyStore?>(
  (ref) => NotificationPolicyRepository(paths: ref.watch(runtimePathsProvider)),
);

final desktopNotificationLoggerProvider = Provider<void Function(String)?>(
  (ref) => null,
);

final desktopNotificationsProvider =
    NotifierProvider<DesktopNotificationsController, DesktopNotificationsState>(
      DesktopNotificationsController.new,
    );

class DesktopNotificationsController extends Notifier<DesktopNotificationsState>
    with NotifierLifecycle<DesktopNotificationsState> {
  @override
  DesktopNotificationsState build() {
    final bridge = ref.watch(denialBridgeProvider);
    _dismiss = bridge.dismissNotification;
    _invokeAction = bridge.invokeNotificationAction;
    _invokeDefaultAction = bridge.invokeDefaultNotificationAction;
    _policyStore = ref.watch(notificationPolicyStoreProvider);
    _logger = ref.watch(desktopNotificationLoggerProvider);
    _invokedActions.clear();
    _reducer = DesktopNotificationReducer();
    _policyMutated = false;
    _policyWriteRunning = false;
    _pendingPolicyWrite = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = bridge.notificationEvents.listen(
      (event) => _handleEvent(event, generation),
    );
    cancelOnDispose(subscription);
    if (_policyStore != null) {
      scheduleMicrotask(() {
        if (isBuildGenerationActive(generation)) {
          unawaited(_loadPolicy(generation));
        }
      });
    }
    return DesktopNotificationsState(policyLoaded: _policyStore == null);
  }

  static const int maxActiveNotifications =
      DesktopNotificationReducer.maxActiveNotifications;
  static const int maxHistoryEntries =
      DesktopNotificationReducer.maxHistoryEntries;
  static const int maxBannerQueue = DesktopNotificationReducer.maxBannerQueue;

  late void Function(String message)? _logger;
  late bool Function(int notificationId) _dismiss;
  late bool Function(int notificationId, String actionKey) _invokeAction;
  late bool Function(int notificationId) _invokeDefaultAction;
  late NotificationPolicyStore? _policyStore;
  late int _buildGeneration;

  final Map<int, Set<String>> _invokedActions = <int, Set<String>>{};
  late DesktopNotificationReducer _reducer;
  bool _policyMutated = false;
  bool _policyWriteRunning = false;
  NotificationPolicy? _pendingPolicyWrite;

  bool dismiss(int notificationId) {
    if (!state.active.containsKey(notificationId) ||
        state.pendingDismissals.contains(notificationId)) {
      return false;
    }
    if (!_dismiss(notificationId)) {
      return false;
    }
    _markDismissalPending(notificationId);
    return true;
  }

  bool dismissFromHistory(int notificationId) {
    final active = state.active.containsKey(notificationId);
    if (active &&
        !state.pendingDismissals.contains(notificationId) &&
        !_dismiss(notificationId)) {
      return false;
    }

    final pending = Set<int>.of(state.pendingDismissals);
    if (active) {
      pending.add(notificationId);
    }
    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.where(
          (record) => record.notification.id != notificationId,
        ),
      ),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
      pendingDismissals: Set<int>.unmodifiable(pending),
    );
    return true;
  }

  void clearAll() {
    final pending = Set<int>.of(state.pendingDismissals);
    final failed = <int>{};
    for (final id in state.active.keys) {
      if (pending.contains(id)) {
        continue;
      }
      if (_dismiss(id)) {
        pending.add(id);
      } else {
        failed.add(id);
      }
    }

    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.where(
          (record) => record.active && failed.contains(record.notification.id),
        ),
      ),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where(failed.contains),
      ),
      pendingDismissals: Set<int>.unmodifiable(pending),
    );
  }

  bool invokeAction(int notificationId, String actionKey) {
    final notification = state.active[notificationId];
    if (notification == null ||
        !notification.actions.any((action) => action.key == actionKey)) {
      return false;
    }
    return _invokeOnce(
      notificationId,
      actionKey,
      () => _invokeAction(notificationId, actionKey),
    );
  }

  bool invokeDefaultAction(int notificationId) {
    final notification = state.active[notificationId];
    if (notification == null ||
        !notification.actions.any((action) => action.key == 'default')) {
      return false;
    }
    return _invokeOnce(
      notificationId,
      'default',
      () => _invokeDefaultAction(notificationId),
    );
  }

  void setDoNotDisturb(bool enabled) {
    if (state.doNotDisturb == enabled && state.policyLoaded) {
      return;
    }
    _policyMutated = true;
    final queue = enabled
        ? state.bannerQueue
              .where((id) {
                final notification = state.active[id];
                return notification != null &&
                    notification.urgency == DesktopNotificationUrgency.critical;
              })
              .toList(growable: false)
        : state.bannerQueue;
    state = state.copyWith(
      doNotDisturb: enabled,
      policyLoaded: true,
      bannerQueue: List<int>.unmodifiable(queue),
    );
    _schedulePolicyWrite();
  }

  void toggleDoNotDisturb() => setDoNotDisturb(!state.doNotDisturb);

  void setLockPreview(NotificationPreviewMode mode) {
    if (state.lockPreview == mode && state.policyLoaded) {
      return;
    }
    _policyMutated = true;
    state = state.copyWith(lockPreview: mode, policyLoaded: true);
    _schedulePolicyWrite();
  }

  void markAllRead() {
    if (state.unreadCount == 0) {
      return;
    }
    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.map((record) => record.copyWith(unread: false)),
      ),
    );
  }

  /// Stops a heads-up presentation without closing the notification or
  /// acknowledging its history entry.
  void hideBanner(int notificationId) {
    if (!state.bannerQueue.contains(notificationId)) return;
    state = state.copyWith(
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
    );
  }

  bool _invokeOnce(
    int notificationId,
    String actionKey,
    bool Function() invoke,
  ) {
    final invoked = _invokedActions.putIfAbsent(
      notificationId,
      () => <String>{},
    );
    if (!invoked.add(actionKey)) {
      return false;
    }
    if (invoke()) {
      return true;
    }
    invoked.remove(actionKey);
    if (invoked.isEmpty) {
      _invokedActions.remove(notificationId);
    }
    return false;
  }

  void _markDismissalPending(int notificationId) {
    final pending = Set<int>.of(state.pendingDismissals)..add(notificationId);
    state = state.copyWith(
      pendingDismissals: Set<int>.unmodifiable(pending),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
    );
  }

  void _handleEvent(DesktopNotificationEvent event, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final result = _reducer.apply(state, event);
    final id = event.kind == DesktopNotificationEventKind.closed
        ? event.notificationId
        : event.notification!.id;
    _invokedActions.remove(id);
    if (result.evictedId case final evictedId?) {
      _invokedActions.remove(evictedId);
    }
    state = result.state;
    _logger?.call(event.toReadableString());
  }

  Future<void> _loadPolicy(int generation) async {
    final policy = await _policyStore!.read();
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    if (_policyMutated) {
      state = state.copyWith(policyLoaded: true);
      return;
    }
    state = state.copyWith(
      doNotDisturb: policy.doNotDisturb,
      lockPreview: policy.lockPreview,
      policyLoaded: true,
    );
  }

  void _schedulePolicyWrite() {
    if (_policyStore == null) {
      return;
    }
    _pendingPolicyWrite = NotificationPolicy(
      doNotDisturb: state.doNotDisturb,
      lockPreview: state.lockPreview,
    );
    if (!_policyWriteRunning) {
      unawaited(_drainPolicyWrites(_buildGeneration));
    }
  }

  Future<void> _drainPolicyWrites(int generation) async {
    _policyWriteRunning = true;
    try {
      while (isBuildGenerationActive(generation)) {
        final policy = _pendingPolicyWrite;
        if (policy == null) {
          return;
        }
        _pendingPolicyWrite = null;
        await _policyStore!.write(policy);
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        _policyWriteRunning = false;
      }
    }
  }
}
