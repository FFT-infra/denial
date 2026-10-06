import 'package:flutter/widgets.dart';

/// Fades and scales [child] while reusing one offscreen layer per animation.
///
/// `Opacity` or `FadeTransition` around `Transform.scale` or `ScaleTransition`
/// renders the faded subtree into a layer measured in screen pixels. The scale
/// changes that measurement on every frame, and a layer that grows allocates
/// new GPU memory at each larger size. See "Growing animated layers allocate
/// GPU memory" in `docs/KNOWN_ISSUES.md`.
///
/// This widget renders [child] at its own size, applies [opacity] to that
/// layer and scales the finished image. The layer keeps one size for the whole
/// animation while the scaled image stays mostly within its clip. At rest, with
/// an opacity of 1 and a scale of 1, the child paints directly without a layer.
/// Hit testing and coordinate conversion follow the scale, as they do for
/// [Transform.scale].
///
/// Content that samples the scene behind it, such as `ShellBackdropBlur`, glass
/// or a Wayland window surface, must not be wrapped: inside the layer it
/// samples the layer instead. Fade those leaves individually.
class ShellFadeScale extends StatelessWidget {
  const ShellFadeScale({
    super.key,
    this.opacity = 1.0,
    this.scale = 1.0,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
    required this.child,
  }) : assert(opacity >= 0.0 && opacity <= 1.0),
       assert(scale >= 0.0);

  final double opacity;
  final double scale;
  final AlignmentGeometry alignment;

  /// Sampling quality for the scaled image while [scale] differs from 1.
  final FilterQuality filterQuality;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Both render objects stay mounted at rest so the child keeps its state
    // when motion starts or stops. An opacity of 1 creates no engine layer,
    // and an identity transform without filter quality paints directly.
    return Opacity(
      opacity: opacity,
      child: Transform(
        transform: Matrix4.diagonal3Values(scale, scale, 1.0),
        alignment: alignment,
        // A filter quality makes the transform a matrix image filter: the
        // child is drawn once at its own size and the result is scaled. The
        // outer opacity is applied by that same layer. A zero scale keeps the
        // regular transform, which paints nothing for a singular matrix.
        filterQuality: scale == 1.0 || scale == 0.0 ? null : filterQuality,
        child: child,
      ),
    );
  }
}
