import 'package:meta/meta.dart';

import '../models/desktop_notification.dart';
import '../models/notification_policy.dart';

@immutable
class DesktopNotificationRecord {
  const DesktopNotificationRecord({
    required this.notification,
    required this.sequence,
    required this.active,
    required this.unread,
    this.closeReason = 0,
  });

  final DesktopNotification notification;
  final int sequence;
  final bool active;
  final bool unread;
  final int closeReason;

  DesktopNotificationRecord copyWith({
    DesktopNotification? notification,
    bool? active,
    bool? unread,
    int? closeReason,
  }) {
    return DesktopNotificationRecord(
      notification: notification ?? this.notification,
      sequence: sequence,
      active: active ?? this.active,
      unread: unread ?? this.unread,
      closeReason: closeReason ?? this.closeReason,
    );
  }
}

@immutable
class DesktopNotificationsState {
  const DesktopNotificationsState({
    this.active = const <int, DesktopNotification>{},
    this.history = const <DesktopNotificationRecord>[],
    this.bannerQueue = const <int>[],
    this.pendingDismissals = const <int>{},
    this.doNotDisturb = false,
    this.policyLoaded = true,
    this.lockPreview = NotificationPreviewMode.applicationOnly,
    this.lastEvent,
  });

  static const int maxVisibleBanners = 3;
  static const bool criticalBypassesDoNotDisturb = true;

  final Map<int, DesktopNotification> active;
  final List<DesktopNotificationRecord> history;
  final List<int> bannerQueue;
  final Set<int> pendingDismissals;
  final bool doNotDisturb;
  final bool policyLoaded;
  final NotificationPreviewMode lockPreview;
  final DesktopNotificationEvent? lastEvent;

  List<DesktopNotification> get bannerNotifications {
    final visible = <DesktopNotification>[];
    for (final id in bannerQueue) {
      final notification = active[id];
      if (notification == null ||
          notification.historyOnly ||
          pendingDismissals.contains(id)) {
        continue;
      }
      if (doNotDisturb &&
          !(criticalBypassesDoNotDisturb &&
              notification.urgency == DesktopNotificationUrgency.critical)) {
        continue;
      }
      visible.add(notification);
      if (visible.length == maxVisibleBanners) {
        break;
      }
    }
    return List<DesktopNotification>.unmodifiable(visible);
  }

  DesktopNotification? get bannerNotification {
    final notifications = bannerNotifications;
    return notifications.isEmpty ? null : notifications.first;
  }

  int get unreadCount {
    var count = 0;
    for (final record in history) {
      if (record.unread) {
        count += 1;
      }
    }
    return count;
  }

  DesktopNotificationsState copyWith({
    Map<int, DesktopNotification>? active,
    List<DesktopNotificationRecord>? history,
    List<int>? bannerQueue,
    Set<int>? pendingDismissals,
    bool? doNotDisturb,
    bool? policyLoaded,
    NotificationPreviewMode? lockPreview,
    DesktopNotificationEvent? lastEvent,
  }) {
    return DesktopNotificationsState(
      active: active ?? this.active,
      history: history ?? this.history,
      bannerQueue: bannerQueue ?? this.bannerQueue,
      pendingDismissals: pendingDismissals ?? this.pendingDismissals,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      policyLoaded: policyLoaded ?? this.policyLoaded,
      lockPreview: lockPreview ?? this.lockPreview,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}
