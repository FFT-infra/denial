import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reference_shell_profile.dart';

/// Scene selection, independent of startup/security policy. Each scene's
/// input publisher also selects its native window-geometry policy.
final referenceShellPresentationProvider =
    NotifierProvider<ReferenceShellPresentation, ReferenceShellProfile>(
      ReferenceShellPresentation.new,
    );

class ReferenceShellPresentation extends Notifier<ReferenceShellProfile> {
  @override
  ReferenceShellProfile build() => ref.read(referenceShellProfileProvider);

  void toggle() {
    state = state == ReferenceShellProfile.desktop
        ? ReferenceShellProfile.mobile
        : ReferenceShellProfile.desktop;
  }
}

/// Native geometry supplies the mobile status strip for either startup profile.
final mobilePresentationTopInsetProvider = Provider<double>((ref) => 0.0);
