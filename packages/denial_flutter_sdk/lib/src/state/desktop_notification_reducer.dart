import 'dart:collection';

import '../models/desktop_notification.dart';
import 'desktop_notifications_state.dart';

/// Applies native events without copying collections that the event leaves
/// untouched. Changed collections are owned by the resulting immutable state.
final class DesktopNotificationReducer {
  static const maxActiveNotifications = 256;
  static const maxHistoryEntries = 100;
  static const maxBannerQueue = 24;

  int _nextSequence = 1;

  ({DesktopNotificationsState state, int? evictedId}) apply(
    DesktopNotificationsState state,
    DesktopNotificationEvent event,
  ) {
    var active = state.active;
    var history = state.history;
    var banners = state.bannerQueue;
    var pending = state.pendingDismissals;
    int? evictedId;

    if (event.kind == DesktopNotificationEventKind.closed) {
      final id = event.notificationId;
      if (active.containsKey(id)) {
        active = UnmodifiableMapView({...active}..remove(id));
      }
      banners = _removeBanner(banners, id);
      pending = _removePending(pending, id);
      final index = history.indexWhere(
        (record) => record.notification.id == id,
      );
      if (index >= 0) {
        final record = history[index];
        if (record.active || record.closeReason != event.closeReason) {
          history = UnmodifiableListView(
            List.of(history)
              ..[index] = record.copyWith(
                active: false,
                closeReason: event.closeReason,
              ),
          );
        }
      }
    } else {
      final notification = event.notification!;
      final id = notification.id;
      final updatedActive = Map<int, DesktopNotification>.of(active);
      if (!active.containsKey(id) && active.length >= maxActiveNotifications) {
        evictedId = active.keys.first;
        updatedActive.remove(evictedId);
        banners = _removeBanner(banners, evictedId);
        pending = _removePending(pending, evictedId);
      }
      updatedActive[id] = notification;
      active = UnmodifiableMapView(updatedActive);
      pending = _removePending(pending, id);

      final showBanner =
          !notification.historyOnly &&
          (!state.doNotDisturb ||
              notification.urgency == DesktopNotificationUrgency.critical);
      if (showBanner) {
        final index = banners.indexOf(id);
        if (index != 0 || banners.length > maxBannerQueue) {
          final updated = List<int>.of(banners);
          if (index >= 0) updated.removeAt(index);
          updated.insert(0, id);
          if (updated.length > maxBannerQueue) updated.length = maxBannerQueue;
          banners = UnmodifiableListView(updated);
        }
      } else {
        banners = _removeBanner(banners, id);
      }

      final index = history.indexWhere(
        (record) => record.notification.id == id,
      );
      if (notification.transient && !notification.historyOnly) {
        if (index >= 0) {
          history = UnmodifiableListView(List.of(history)..removeAt(index));
        }
      } else if (index >= 0) {
        final record = history[index];
        if (!identical(record.notification, notification) ||
            !record.active ||
            !record.unread ||
            record.closeReason != 0) {
          history = UnmodifiableListView(
            List.of(history)
              ..[index] = record.copyWith(
                notification: notification,
                active: true,
                unread: true,
                closeReason: 0,
              ),
          );
        }
      } else {
        final updated = List<DesktopNotificationRecord>.of(history)
          ..insert(
            0,
            DesktopNotificationRecord(
              notification: notification,
              sequence: _nextSequence++,
              active: true,
              unread: true,
            ),
          );
        if (updated.length > maxHistoryEntries) {
          updated.length = maxHistoryEntries;
        }
        history = UnmodifiableListView(updated);
      }
    }

    return (
      state: state.copyWith(
        active: active,
        history: history,
        bannerQueue: banners,
        pendingDismissals: pending,
        lastEvent: event,
      ),
      evictedId: evictedId,
    );
  }

  List<int> _removeBanner(List<int> banners, int id) {
    final index = banners.indexOf(id);
    return index < 0
        ? banners
        : UnmodifiableListView(List.of(banners)..removeAt(index));
  }

  Set<int> _removePending(Set<int> pending, int id) => pending.contains(id)
      ? UnmodifiableSetView({...pending}..remove(id))
      : pending;
}
