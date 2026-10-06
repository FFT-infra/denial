enum NotificationPreviewMode {
  hidden,
  applicationOnly,
  full;

  static NotificationPreviewMode parse(Object? value) {
    return switch (value) {
      'hidden' => NotificationPreviewMode.hidden,
      'full' => NotificationPreviewMode.full,
      _ => NotificationPreviewMode.applicationOnly,
    };
  }
}

class NotificationPolicy {
  const NotificationPolicy({
    this.doNotDisturb = false,
    this.lockPreview = NotificationPreviewMode.applicationOnly,
  });

  final bool doNotDisturb;
  final NotificationPreviewMode lockPreview;

  NotificationPolicy copyWith({
    bool? doNotDisturb,
    NotificationPreviewMode? lockPreview,
  }) {
    return NotificationPolicy(
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      lockPreview: lockPreview ?? this.lockPreview,
    );
  }
}
