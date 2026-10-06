import '../../input.dart';

import '../../surfaces.dart';

import 'package:flutter/widgets.dart';

import '../../motion.dart';

/// Internal retained-visibility lifecycle used by the SDK surface host.
/// Plugins consume ShellSurfacePresentation instead of mounting this directly.
class ShellSurfaceTransition extends StatefulWidget {
  const ShellSurfaceTransition({
    required this.visible,
    required this.durationScale,
    required this.child,
    super.key,
  });

  final bool visible;
  final double durationScale;
  final Widget child;

  @override
  State<ShellSurfaceTransition> createState() => _ShellSurfaceTransitionState();
}

class _ShellSurfaceTransitionState extends State<ShellSurfaceTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late bool _hasShown;

  @override
  void initState() {
    super.initState();
    _hasShown = widget.visible;
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1 : 0,
    );
    _opacity = _controller.drive(CurveTween(curve: Motion.standard));
  }

  void _updateDurations() {
    final reduced = MediaQuery.disableAnimationsOf(context);
    Duration scaled(Duration base) => reduced
        ? Duration.zero
        : Duration(
            microseconds: (base.inMicroseconds * widget.durationScale).round(),
          );
    _controller.duration = scaled(Motion.desktopPanelFadeOpen);
    _controller.reverseDuration = scaled(Motion.desktopPanelFadeClose);
    if (reduced || widget.durationScale == 0) {
      _controller.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDurations();
  }

  @override
  void didUpdateWidget(ShellSurfaceTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateDurations();
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _hasShown = true;
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasShown) return const SizedBox.shrink();
    return ShellSurfacePresentation(
      visible: widget.visible,
      opacity: _opacity,
      child: ShellInputScope(
        enabled: widget.visible && ShellInputScope.enabledOf(context),
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeFocus(
            excluding: !widget.visible,
            child: ExcludeSemantics(
              excluding: !widget.visible,
              child: AnimatedBuilder(
                animation: _controller,
                child: widget.child,
                builder: (context, child) {
                  final hidden = !widget.visible && _controller.isDismissed;
                  return TickerMode(
                    enabled: !hidden,
                    child: Offstage(offstage: hidden, child: child),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
