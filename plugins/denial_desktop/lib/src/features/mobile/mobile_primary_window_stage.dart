import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Keeps both app subtrees laid out while the switch gesture moves their layers.
class MobilePrimaryWindowStage extends StatefulWidget {
  const MobilePrimaryWindowStage({
    super.key,
    this.currentWindow,
    required this.switchTargetWindow,
    required this.drag,
    required this.switching,
    required this.opacity,
  });

  /// Null on home, where only the switch target slides in.
  final DenialWindow? currentWindow;
  final DenialWindow? switchTargetWindow;

  /// The bottom gesture's drag; its horizontal part moves the stage.
  final ValueListenable<Offset> drag;

  /// A horizontal pill drag is moving the stage.
  final bool switching;
  final double opacity;

  @override
  State<MobilePrimaryWindowStage> createState() =>
      _MobilePrimaryWindowStageState();
}

class _MobilePrimaryWindowStageState extends State<MobilePrimaryWindowStage> {
  final _currentTranslation = ValueNotifier(Offset.zero);
  final _targetTranslation = ValueNotifier(Offset.zero);
  late final _motion = Listenable.merge([
    _currentTranslation,
    _targetTranslation,
  ]);
  double _width = 0;

  @override
  void initState() {
    super.initState();
    widget.drag.addListener(_updateTranslations);
  }

  @override
  void didUpdateWidget(covariant MobilePrimaryWindowStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drag != widget.drag) {
      oldWidget.drag.removeListener(_updateTranslations);
      widget.drag.addListener(_updateTranslations);
    }
    _updateTranslations();
  }

  @override
  void dispose() {
    widget.drag.removeListener(_updateTranslations);
    _currentTranslation.dispose();
    _targetTranslation.dispose();
    super.dispose();
  }

  void _updateTranslations() {
    final drag = widget.drag.value.dx;
    if (widget.switchTargetWindow == null) {
      // No app that way: the current app stretches elastically and springs
      // back with the drag.
      _currentTranslation.value = Offset(_rubberBand(drag, _width), 0);
      _targetTranslation.value = Offset.zero;
      return;
    }
    final travel = _width + ReferenceShellMetrics.appSwitchGap;
    final dx = drag.clamp(-travel, travel).toDouble();
    _currentTranslation.value = Offset(dx, 0);
    _targetTranslation.value = Offset(dx > 0 ? dx - travel : dx + travel, 0);
  }

  /// The familiar overscroll resistance: ever smaller steps toward [extent].
  static double _rubberBand(double drag, double extent) {
    if (extent <= 0 || drag == 0) return 0;
    const resistance = 0.55;
    final stretch = 1 - 1 / (drag.abs() * resistance / extent + 1);
    return drag.sign * stretch * extent;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentWindow;
    final target = widget.switchTargetWindow;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final radius = widget.switching
        ? context.shellTheme.borderRadius(18)
        : BorderRadius.zero;
    // Each app moves as its own layer, so a switch repaints nothing. The
    // parent chain and the Stack child keys stay stable across idle,
    // switching, cancellation and target promotion. A key below a newly
    // inserted LayoutBuilder cannot preserve the surface element.
    final stage = LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        _updateTranslations();
        return Stack(
          fit: StackFit.expand,
          children: [
            if (current != null)
              CompositedTranslation(
                key: _WindowStageKey(current.objectId),
                translation: _currentTranslation,
                devicePixelRatio: pixelRatio,
                child: WindowContentRect(
                  contentPadding: const EdgeInsets.only(
                    top: ReferenceShellMetrics.appStatusBarHeight,
                  ),
                  key: ValueKey<int>(current.objectId),
                  window: current,
                  active: true,
                  borderRadius: radius,
                ),
              ),
            if (target != null)
              CompositedTranslation(
                key: _WindowStageKey(target.objectId),
                translation: _targetTranslation,
                devicePixelRatio: pixelRatio,
                child: WindowContentRect(
                  contentPadding: const EdgeInsets.only(
                    top: ReferenceShellMetrics.appStatusBarHeight,
                  ),
                  key: ValueKey<int>(target.objectId),
                  window: target,
                  borderRadius: radius,
                ),
              ),
          ],
        );
      },
    );
    // Keep the surface and its backdrop mounted while the overview hero owns
    // presentation. Inserting/removing this wrapper recreates the whole app
    // subtree on gesture cancellation, including a transparent app's glass.
    return Opacity(
      opacity: widget.opacity,
      // Translucent apps draw the cached wallpaper glass of the mobile scene.
      child: WindowBackdropMotion(motion: _motion, child: stage),
    );
  }
}

class _WindowStageKey extends ValueKey<int> {
  const _WindowStageKey(super.value);
}
