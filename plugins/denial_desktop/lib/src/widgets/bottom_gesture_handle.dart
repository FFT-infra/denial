import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart' show CompositedTranslation;

import 'gesture_pill.dart';

/// The home pill at the bottom of the screen. An upward pull opens recents;
/// a fast flick sends an app home or opens recents from home. A downward swipe
/// closes recents, and a horizontal swipe switches between adjacent apps.
class BottomGestureHandle extends ConsumerStatefulWidget {
  const BottomGestureHandle({super.key});

  @override
  ConsumerState<BottomGestureHandle> createState() =>
      _BottomGestureHandleState();
}

class _BottomGestureHandleState extends ConsumerState<BottomGestureHandle>
    with SingleTickerProviderStateMixin {
  static const double _closeDistance = 72.0;
  static const double _switchDistance = 82.0;
  static const double _flickVelocity = 650.0;
  static const double _switchFlickVelocity = 720.0;
  static const double _axisLockRatio = 1.18;

  /// A faster upward fling sends an app home or opens recents from home. A
  /// slower pull opens recents after [_recentsTravelFraction] of the screen.
  static const double _homeFlickVelocity = 1100.0;
  static const double _recentsTravelFraction = 0.16;

  late final AnimationController _switchController;
  Animation<double>? _switchAnimation;
  int _switchDirection = 0;

  // The pill follows the drag without rebuilding: its lift moves a retained
  // layer, and only a change of [_armed] rebuilds it.
  late final ValueListenable<Offset> _drag;
  final _lift = ValueNotifier(Offset.zero);
  final _armed = ValueNotifier(false);
  bool _overviewVisible = false;
  bool _hasSwitchTarget = false;
  double _recentsTravel = double.infinity;

  // Swipes made while a switch animates wait for it, in order, instead of
  // cutting it short.
  bool _panQueued = false;
  final _queuedPans = <({Offset drag, Offset velocity})>[];

  // Keep an independent velocity estimate for compositor-generated pointer
  // streams, where event coalescing can otherwise under-report a short flick.
  final Stopwatch _panClock = Stopwatch();
  VelocityTracker _panVelocity = VelocityTracker.withKind(
    PointerDeviceKind.touch,
  );
  Offset _panTravel = Offset.zero;

  @override
  void initState() {
    super.initState();
    _switchController = AnimationController(vsync: this)
      ..addListener(_syncSwitchAnimation)
      ..addStatusListener(_handleSwitchStatus);
    _drag = ref.read(referenceShellProvider.notifier).gestureDrag
      ..addListener(_syncPill);
  }

  @override
  void dispose() {
    _drag.removeListener(_syncPill);
    _switchController.dispose();
    _lift.dispose();
    _armed.dispose();
    super.dispose();
  }

  void _syncPill() {
    final drag = _drag.value;
    final lift = (-drag.dy / ReferenceShellMetrics.gesturePillLiftTravel).clamp(
      0.0,
      1.0,
    );
    _lift.value = Offset(0, -lift * 8.0);
    _armed.value = _overviewVisible
        ? drag.dy > _closeDistance
        : -drag.dy > _recentsTravel ||
              _horizontalSwitchArmed(drag, hasTarget: _hasSwitchTarget);
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(
      referenceShellProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          hasSwitchTarget: state.appSwitchTargetWindow != null,
        ),
      ),
    );
    _overviewVisible = shell.overviewVisible;
    _hasSwitchTarget = shell.hasSwitchTarget;
    _recentsTravel = MediaQuery.sizeOf(context).height * _recentsTravelFraction;
    _syncPill();
    final controller = ref.read(referenceShellProvider.notifier);

    return Positioned(
      left: 0,
      right: 0,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      child: Center(
        child: RepaintBoundary(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _beginPanTracking();
              _panQueued = _switchAnimation != null;
              if (_panQueued) return;
              controller.resetGestureDrag();
            },
            onPanUpdate: (details) {
              _trackPan(details.delta);
              if (!_panQueued) controller.updateGestureDrag(details.delta);
            },
            onPanCancel: () {
              if (_panQueued) {
                _panQueued = false;
              } else {
                controller.resetGestureDrag();
              }
            },
            onPanEnd: (details) => _handlePanEnd(controller, details),
            child: SizedBox(
              width: ReferenceShellMetrics.gestureHitWidth,
              height: ReferenceShellMetrics.gestureHitHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Center(
                  child: CompositedTranslation(
                    translation: _lift,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _armed,
                      builder: (context, armed, _) => GesturePill(armed: armed),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handlePanEnd(
    ReferenceShellController controller,
    DragEndDetails details,
  ) {
    _panClock.stop();
    // Raw travel (not the axis-locked visual drag, which is zeroed for short
    // gestures) and the stronger of our / Flutter's velocity estimate.
    final drag = _panTravel;
    final velocity = _strongerVelocity(
      _panVelocity.getVelocity().pixelsPerSecond,
      details.velocity.pixelsPerSecond,
    );
    final queued = _panQueued;
    _panQueued = false;
    if (queued && _switchAnimation != null) {
      _queuedPans.add((drag: drag, velocity: velocity));
      return;
    }
    _resolvePan(controller, drag, velocity);
  }

  void _resolvePan(
    ReferenceShellController controller,
    Offset drag,
    Offset velocity,
  ) {
    final currentState = ref.read(referenceShellProvider);

    if (currentState.overviewVisible) {
      if (drag.dy > _closeDistance || velocity.dy > _flickVelocity) {
        controller.closeOverview();
      } else {
        controller.resetGestureDrag();
      }
      return;
    }

    final switchDirection = _horizontalSwitchDirection(
      currentState,
      drag,
      velocity,
    );
    if (switchDirection != 0) {
      _animateSwitch(
        controller: controller,
        direction: switchDirection,
        velocityX: velocity.dx,
      );
      return;
    }

    // A fast up-flick sends an app home or opens recents when already home.
    // A longer pull also opens recents; smaller gestures cancel.
    final hasForeground = currentState.foregroundWindow != null;
    final upTravel = -drag.dy;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (currentState.launchTransitionActive) {
      if (velocity.dy < -_homeFlickVelocity ||
          upTravel > screenHeight * _recentsTravelFraction) {
        controller.goHome(releaseVelocity: velocity.dy);
      } else {
        controller.resetGestureDrag();
      }
      return;
    }
    if (velocity.dy < -_homeFlickVelocity) {
      if (hasForeground) {
        controller.goHome(releaseVelocity: velocity.dy);
      } else {
        controller.openOverview(releaseVelocity: velocity.dy);
      }
    } else if (upTravel > screenHeight * _recentsTravelFraction) {
      controller.openOverview(releaseVelocity: velocity.dy);
    } else if (currentState.gesture.horizontal) {
      _animateSwitchBack();
    } else {
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
    }
  }

  void _beginPanTracking() {
    _panTravel = Offset.zero;
    _panVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    _panClock
      ..reset()
      ..start();
    _panVelocity.addPosition(Duration.zero, _panTravel);
  }

  void _trackPan(Offset delta) {
    _panTravel += delta;
    _panVelocity.addPosition(_panClock.elapsed, _panTravel);
  }

  /// Per-axis, keeps whichever source reports the larger magnitude, so a usable
  /// fling survives even if one estimator under-reports.
  Offset _strongerVelocity(Offset a, Offset b) {
    return Offset(
      a.dx.abs() >= b.dx.abs() ? a.dx : b.dx,
      a.dy.abs() >= b.dy.abs() ? a.dy : b.dy,
    );
  }

  bool _horizontalSwitchArmed(Offset drag, {required bool hasTarget}) {
    if (!hasTarget) {
      return false;
    }
    return drag.dx.abs() > _switchDistance &&
        drag.dx.abs() > drag.dy.abs() * _axisLockRatio;
  }

  int _horizontalSwitchDirection(
    ReferenceShellState state,
    Offset drag,
    Offset velocity,
  ) {
    if (state.openAppWindowCount < 2 || state.overviewVisible) {
      return 0;
    }

    final horizontalIntent =
        drag.dx.abs() > drag.dy.abs() * _axisLockRatio ||
        velocity.dx.abs() > velocity.dy.abs() * _axisLockRatio;
    if (!horizontalIntent) {
      return 0;
    }

    var direction = 0;
    if (velocity.dx.abs() > _switchFlickVelocity) {
      direction = velocity.dx > 0.0 ? -1 : 1;
    } else if (drag.dx.abs() > _switchDistance) {
      direction = drag.dx > 0.0 ? -1 : 1;
    }

    if (direction == 0 || state.adjacentOpenAppWindow(direction) == null) {
      return 0;
    }
    return direction;
  }

  /// Slides the current app off-screen toward [direction] until the incoming
  /// app lands centred. The switch is a directed commit, so it rides a curve
  /// whose duration is derived from the fling velocity (a faster flick lands
  /// sooner) rather than a spring, which would creep at the tail.
  void _animateSwitch({
    required ReferenceShellController controller,
    required int direction,
    required double velocityX,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0.0) {
      controller.completeAdjacentWindowSwitch(direction);
      return;
    }

    final startX = _drag.value.dx;
    final travel = width + ReferenceShellMetrics.appSwitchGap;
    final endX = direction < 0 ? travel : -travel;
    final distance = (endX - startX).abs();
    final speed = math.max(velocityX.abs(), 1450.0);
    final durationMs = ((distance / speed) * 1000.0).clamp(170.0, 340.0);

    _switchDirection = direction;
    _switchAnimation = Tween<double>(begin: startX, end: endX).animate(
      CurvedAnimation(parent: _switchController, curve: Motion.emphasized),
    );
    _switchController.duration = Duration(milliseconds: durationMs.round());
    _switchController.forward(from: 0.0);
  }

  /// Returns a switch the user did not commit, so the incoming app slides
  /// back out instead of vanishing.
  void _animateSwitchBack() {
    final startX = _drag.value.dx;
    final durationMs = ((startX.abs() / 1450.0) * 1000.0).clamp(170.0, 300.0);
    _switchDirection = 0;
    _switchAnimation = Tween<double>(begin: startX, end: 0.0).animate(
      CurvedAnimation(parent: _switchController, curve: Motion.emphasized),
    );
    _switchController.duration = Duration(milliseconds: durationMs.round());
    _switchController.forward(from: 0.0);
  }

  void _syncSwitchAnimation() {
    final value = _switchAnimation?.value;
    if (value == null) {
      return;
    }
    ref
        .read(referenceShellProvider.notifier)
        .setGestureDragForAnimation(Offset(value, 0.0));
  }

  void _handleSwitchStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _switchAnimation == null) {
      return;
    }
    final direction = _switchDirection;
    _switchAnimation = null;
    _switchDirection = 0;
    final controller = ref.read(referenceShellProvider.notifier);
    if (direction == 0) {
      controller.resetGestureDrag();
    } else {
      controller.completeAdjacentWindowSwitch(direction);
    }
    // Play queued swipes until one animates again.
    while (_queuedPans.isNotEmpty && _switchAnimation == null && mounted) {
      final pan = _queuedPans.removeAt(0);
      _resolvePan(controller, pan.drag, pan.velocity);
    }
  }
}
