import 'glass_configuration.dart';

/// Choose a material by purpose, never by a desired translucency or color.
enum DenialMaterialRole {
  window,
  content,
  card,
  sidebar,
  toolbar,
  dialog,
  popover,
}

/// Client-side backdrop filtering. Where the client remains translucent,
/// Denial separately supplies desktop pixels during final window composition.
enum DenialMaterialBackdrop { none, content }

/// Pure policy shared by Flutter presentation and non-rendering validation.
class DenialMaterialPolicy {
  const DenialMaterialPolicy._(this.backdrop, this.opacity);

  /// Nonzero coverage keeps floating shadows from becoming isolated patches
  /// of compositor glass at a zero cutoff. This applies only to the window.
  static const minimumWindowOpacity = 3 / 255;

  factory DenialMaterialPolicy.resolve({
    required DenialMaterialRole role,
    required ShellTransparencyMode transparency,
    required double windowOpacity,
    required double appPanelOpacity,
  }) {
    if (transparency == ShellTransparencyMode.off ||
        (role != DenialMaterialRole.window &&
            role != DenialMaterialRole.sidebar &&
            role != DenialMaterialRole.toolbar)) {
      return const DenialMaterialPolicy._(DenialMaterialBackdrop.none, 1);
    }
    final requestedOpacity = role == DenialMaterialRole.window
        ? windowOpacity
        : appPanelOpacity;
    final opacity = requestedOpacity.isFinite
        ? requestedOpacity.clamp(0.0, 1.0).toDouble()
        : 1.0;
    if (role == DenialMaterialRole.window) {
      // Desktop sampling belongs to the compositor, not a second client-side
      // backdrop filter covering the whole application.
      return DenialMaterialPolicy._(
        DenialMaterialBackdrop.none,
        opacity.clamp(minimumWindowOpacity, 1.0).toDouble(),
      );
    }
    if (opacity == 1) {
      return const DenialMaterialPolicy._(DenialMaterialBackdrop.none, 1);
    }
    return DenialMaterialPolicy._(DenialMaterialBackdrop.content, opacity);
  }

  final DenialMaterialBackdrop backdrop;
  final double opacity;
}
