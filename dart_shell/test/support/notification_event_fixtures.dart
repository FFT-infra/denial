import 'package:denial_flutter_sdk/models.dart';

DesktopNotificationEvent notificationEvent(
  int id, {
  bool resident = false,
  bool transient = false,
  int timeout = -1,
  int progress = 0,
  DesktopNotificationUrgency urgency = DesktopNotificationUrgency.normal,
  DesktopNotificationEventKind kind = DesktopNotificationEventKind.added,
}) => DesktopNotificationEvent(
  kind: kind,
  notificationId: id,
  closeReason: 0,
  notification: DesktopNotification(
    id: id,
    sender: ':1.5',
    appName: 'Application',
    appIcon: '',
    summary: 'Notification $id',
    body: '',
    actions: const [],
    urgency: urgency,
    category: '',
    desktopEntry: '',
    imagePath: '',
    imageData: null,
    resident: resident,
    transient: transient,
    suppressSound: false,
    actionIcons: false,
    soundName: '',
    soundFile: '',
    x: 0,
    y: 0,
    hasPosition: false,
    progress: progress,
    hasProgress: true,
    expireTimeoutMs: timeout,
  ),
);

DesktopNotificationEvent closeNotification(int id, {int reason = 2}) =>
    DesktopNotificationEvent(
      kind: DesktopNotificationEventKind.closed,
      notificationId: id,
      closeReason: reason,
    );
