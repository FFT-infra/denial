import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../launcher/home_grid_geometry.dart';
import '../launcher/home_icon_locator.dart';
import '../launcher/widgets/launcher_icon.dart';
import '../launcher/widgets/rect_follower.dart';

typedef LaunchTransitionCompleted = void Function(int requestId, int objectId);

/// Opens an app out of its home icon.
///
/// The card grows from the icon to the screen. A running app shows its live
/// window in it at once. A new one shows frosted glass with its icon riding
/// the card's center until the first window arrives and fades in. The home
/// icon stays hidden while this draws it.
///
/// A launch withdrawn before its window settles (home, or a failed start)
/// shrinks back into the icon. Completion is reported only after the zoom
/// and any reveal have finished.
class LaunchTransitionLayer extends StatefulWidget {
  const LaunchTransitionLayer({
    super.key,
    required this.request,
    required this.window,
    required this.icon,
    required this.locator,
    required this.onCompleted,
  });

  final AppLaunchRequest? request;
  final DenialWindow? window;

  /// A local application's glyph; desktop apps use the request's icon path.
  final IconData? icon;
  final HomeIconLocator locator;
  final LaunchTransitionCompleted onCompleted;

  @override
  State<LaunchTransitionLayer> createState() => _LaunchTransitionLayerState();
}

class _LaunchTransitionLayerState extends State<LaunchTransitionLayer>
    with TickerProviderStateMixin {
  /// The icon riding a new app's card, once the card fills the screen.
  static const double _placeholderIcon = 112;

  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: Motion.launch,
  )..addStatusListener(_statusChanged);
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: Motion.launchReveal,
  )..addStatusListener(_statusChanged);

  /// The card's first stretch: the icon gives way to the window or glass.
  late final Animation<double> _early = _zoom.drive(
    CurveTween(curve: const Interval(0, 0.3, curve: Curves.easeOut)),
  );
  late final Animation<double> _windowOpacity = _reveal.drive(
    CurveTween(curve: Curves.easeOut),
  );
  late final Animation<double> _iconOpacity = _IconOpacity(_reveal, _early);
  final _iconRect = ValueNotifier(Rect.zero);

  /// The request on screen: the widget's, or a withdrawn one shrinking back.
  AppLaunchRequest? _request;
  DenialWindow? _window;
  IconData? _icon;
  int? _completedRequestId;
  bool _withdrawing = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_placeIcon);
    _show(widget.request, widget.window);
  }

  @override
  void didUpdateWidget(covariant LaunchTransitionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final request = widget.request;
    if (request?.requestId != oldWidget.request?.requestId) {
      final withdrawn = oldWidget.request;
      if (request == null &&
          withdrawn != null &&
          _completedRequestId != withdrawn.requestId) {
        _withdraw();
      } else {
        _show(request, widget.window);
      }
      return;
    }
    if (widget.window?.objectId != _window?.objectId && !_withdrawing) {
      _window = widget.window;
      _syncReveal();
    }
  }

  @override
  void dispose() {
    _revealHome();
    _zoom.dispose();
    _reveal.dispose();
    _iconRect.dispose();
    super.dispose();
  }

  void _show(AppLaunchRequest? request, DenialWindow? window) {
    _revealHome();
    _withdrawing = false;
    _completedRequestId = null;
    _zoom.stop();
    _reveal.stop();
    _zoom.value = 0;
    _reveal.value = 0;
    _request = request;
    _window = window;
    _icon = widget.icon;
    if (request == null) return;
    if (request.sourceItemId case final id?) widget.locator.hide(id);
    MotionTelemetry.observe(
      _zoom,
      _zoom.forward(),
      'app_launch_zoom',
      target: 1.0,
    );
    _syncReveal();
  }

  /// Shrinks the withdrawn launch back into its icon.
  void _withdraw() {
    _withdrawing = true;
    _reveal.stop();
    MotionTelemetry.observe(
      _zoom,
      _zoom.animateBack(
        0,
        duration: Motion.launch * 0.75,
        curve: Curves.easeInOutCubic,
      ),
      'app_launch_withdraw',
      target: 0.0,
    );
  }

  void _syncReveal() {
    final request = _request;
    final window = _window;
    if (request == null || window == null) {
      _reveal.value = 0;
    } else if (_isRunningApp(request, window)) {
      _reveal.value = 1;
    } else if (_zoom.isCompleted && !_reveal.isAnimating && _reveal.value < 1) {
      // A new window fades in once the card is still: fading it while the
      // card grows would composite it through a resizing layer each frame.
      MotionTelemetry.observe(
        _reveal,
        _reveal.forward(),
        'app_launch_reveal',
        target: 1.0,
      );
    }
  }

  bool _isRunningApp(AppLaunchRequest request, DenialWindow? window) =>
      window != null && request.targetObjectId == window.objectId;

  void _revealHome() {
    if (_request?.sourceItemId case final id?) widget.locator.reveal(id);
  }

  void _statusChanged(AnimationStatus status) {
    if (_withdrawing) {
      if (status == AnimationStatus.dismissed && _zoom.value == 0) {
        _revealHome();
        setState(() {
          _withdrawing = false;
          _request = null;
          _window = null;
        });
      }
      return;
    }
    if (status == AnimationStatus.completed && _reveal.value == 0) {
      _syncReveal();
    }
    final request = widget.request;
    final window = widget.window;
    if (_zoom.status != AnimationStatus.completed ||
        _reveal.status != AnimationStatus.completed ||
        request == null ||
        window == null ||
        request.requestId != _request?.requestId ||
        _completedRequestId == request.requestId) {
      return;
    }
    _completedRequestId = request.requestId;
    _revealHome();
    widget.onCompleted(request.requestId, window.objectId);
  }

  Size _size = Size.zero;

  void _placeIcon() {
    final request = _request;
    if (request == null || _size.isEmpty) return;
    final size = _size;
    final box = context.findRenderObject();
    // This layer fills the screen; before its first layout it sits where
    // it will.
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero)
        : Offset.zero;
    final source = request.sourceRect;
    final start = source == null
        ? _fallbackStartRect(size).center
        : source.center - origin;
    final startSize = source?.width ?? HomeTileMetrics.icon;
    final t = Motion.md3EmphasizedDecelerate.transform(_zoom.value);
    final extent = startSize + (_placeholderIcon - startSize) * t;
    _iconRect.value = Rect.fromCenter(
      center: Offset.lerp(start, size.center(Offset.zero), t)!,
      width: extent,
      height: extent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request == null) return const SizedBox.expand();
    final window = _window;
    return Positioned.fill(
      child: IgnorePointer(
        child: Semantics(
          container: true,
          liveRegion: true,
          label: context.l10n.launchOpeningApplication(request.appName),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              if (size.isEmpty) return const SizedBox.expand();
              _size = size;
              _placeIcon();
              final source = request.sourceRect;
              final running = _isRunningApp(request, window);
              // A running app grows whole out of its icon. A new one opens
              // as glass that the icon morphs into.
              final start = source == null
                  ? _fallbackStartRect(size)
                  : running
                  ? Rect.fromCenter(
                      center: source.center,
                      width: source.width,
                      height: source.width * size.height / size.width,
                    )
                  : source;
              final surface = window == null
                  ? null
                  : WindowSurface(
                      window: window,
                      contentPadding: const EdgeInsets.only(
                        top: ReferenceShellMetrics.appStatusBarHeight,
                      ),
                    );
              final card = RetainedWindowMotion(
                progress: _zoom,
                begin: start,
                beginIsGlobal: source != null,
                end: Offset.zero & size,
                beginRadius: source == null
                    ? context.shellTheme.panelRadius
                    : start.width * HomeTileMetrics.iconRadiusFraction,
                curve: Motion.md3EmphasizedDecelerate,
                // A new app's card reveals its glass and window in place
                // under the growing clip: nothing in it repaints or scales.
                transformChild: running,
                child: running
                    ? surface!
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          _LaunchGlass(opacity: _early),
                          if (surface != null)
                            FadeTransition(
                              opacity: _windowOpacity,
                              child: surface,
                            ),
                        ],
                      ),
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  // A running app scales whole, at full opacity, under its
                  // fading icon. Its own glass repaints as it moves.
                  if (running)
                    WindowBackdropMotion(motion: _zoom, child: card)
                  else
                    card,
                  RectFollower(
                    rect: _iconRect,
                    size: const Size.square(_placeholderIcon),
                    child: FadeTransition(
                      opacity: _iconOpacity,
                      child: LauncherIcon(
                        iconPath: request.iconPath,
                        icon: _icon,
                        rasterize: true,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// A launch from outside home grows from a centered card.
  Rect _fallbackStartRect(Size viewSize) {
    final padding = MediaQuery.paddingOf(context);
    final width = math.min(
      (viewSize.width - padding.horizontal - 48) * 0.68,
      390.0,
    );
    final aspect = viewSize.height <= 0
        ? 1.0
        : (viewSize.width / viewSize.height).clamp(0.56, 2.40);
    final height = math.min(width / aspect, viewSize.height * 0.58);
    return Rect.fromCenter(
      center: viewSize.center(Offset.zero),
      width: height * aspect,
      height: height,
    );
  }
}

/// The new app's card before its window arrives: the same wallpaper glass a
/// translucent app draws behind itself, so its first frame lands on what is
/// already there. Without a frost the theme's launch surface shows.
class _LaunchGlass extends StatelessWidget {
  const _LaunchGlass({required this.opacity});

  final Animation<double> opacity;

  @override
  Widget build(BuildContext context) {
    final cache = WindowBackdropCache.maybeOf(context);
    if (cache == null) {
      return FadeTransition(
        opacity: opacity,
        child: ColoredBox(color: context.shellColors.launchSurface),
      );
    }
    return WindowBackdropSlice(
      cache: cache,
      glass: ShellTheme.of(context).windowGlassShading,
      opacity: opacity,
      fadeOverlay: true,
    );
  }
}

/// The icon shows until the window has both arrived and taken over the
/// card, and returns as the card shrinks back into it.
class _IconOpacity extends CompoundAnimation<double> {
  _IconOpacity(Animation<double> reveal, Animation<double> early)
    : super(first: reveal, next: early);

  @override
  double get value => math.max(1 - first.value, 1 - next.value);
}
