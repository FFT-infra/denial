import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show Drag;

import 'package:denial_flutter_sdk/applications.dart' show HomeGridItem;
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../../launcher/home_grid_geometry.dart';
import '../../launcher/home_icon_locator.dart';
import '../../launcher/widgets/home_item_icon.dart';
import 'overview_carousel.dart';
import 'overview_geometry.dart';
import 'overview_page_controller.dart';
import 'overview_grid.dart';
import 'overview_chrome.dart';
import 'overview_focus_overlay.dart';

/// The recents / overview layer.
///
/// While the user swipes up, the foreground app follows the finger: its bottom
/// edge tracks the touch point and it shrinks toward its overview card. The
/// release outcome (home / recents / cancel) is decided by the gesture handle;
/// this layer just plays the resulting transition:
///  * recents  -> the app settles into its card as the other previews arrive;
///  * home     -> the app shrinks into its home icon (or, with none on
///                screen, toward the middle of home), then [onHomeSettled]
///                hands control back to home;
///  * cancel   -> the controller returns to 0 and the app fills the screen.
class OverviewLayer extends StatefulWidget {
  const OverviewLayer({
    super.key,
    required this.windows,
    required this.foregroundWindow,
    required this.foregroundObjectId,
    required this.visible,
    required this.swipe,
    required this.homeTransitionActive,
    required this.onDismissOverview,
    required this.onDismissWindow,
    required this.onFocusWindow,
    required this.onHomeSettled,
    this.backdrop,
    this.homeIcons,
    this.releaseVelocity,
    this.onPresentationChanged,
    this.onProgressChanged,
  });

  final List<DenialWindow> windows;
  final DenialWindow? foregroundWindow;
  final int? foregroundObjectId;
  final bool visible;

  /// The live bottom-gesture drag. Its vertical travel (<= 0 while pulling
  /// up) drives recents; horizontal travel is ignored.
  final ValueListenable<Offset> swipe;
  final bool homeTransitionActive;
  final VoidCallback onDismissOverview;
  final ValueChanged<DenialWindow> onDismissWindow;
  final ValueChanged<DenialWindow> onFocusWindow;
  final VoidCallback onHomeSettled;

  /// The scene behind recents, frosted once. Portrait cards draw slices of it
  /// as their glass instead of filtering the scene on every frame.
  final ValueListenable<FrostedBackdrop?>? backdrop;

  /// Finds the icon an app returns to when going home.
  final HomeIconLocator? homeIcons;

  /// The bottom gesture's last release velocity, in logical pixels per
  /// second. Settling continues from it.
  final ValueGetter<double>? releaseVelocity;
  final ValueChanged<bool>? onPresentationChanged;

  /// Visual progress shared with the launcher during dragging and settling.
  final ValueChanged<double>? onProgressChanged;

  @override
  State<OverviewLayer> createState() => _OverviewLayerState();
}

class _OverviewLayerState extends State<OverviewLayer>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _focusController;
  late final AnimationController _homeController;
  late PageController _pageController;
  late Listenable _backdropMotion;
  late final Animation<double> _scrimOpacity = _ChromeOpacity(
    this,
    reveal: const Interval(0, 1),
  );
  late final Animation<double> _labelOpacity = _ChromeOpacity(
    this,
    reveal: const Interval(0.7, 1),
  );
  double _releaseVelocity = 0;
  double? _pageViewportFraction;
  DenialWindow? _focusWindow;
  Rect? _focusStartRect;
  Rect? _lastHeroRect;

  bool _homeLanded = false;
  static const double _homeLandedAt = 0.985;

  /// The strip sliding to the previous app with the open spring.
  ({double from, double to, double start})? _pageFollow;

  /// Where the app lands going home, in this layer's coordinates, and the
  /// home item that lands there. No icon: the app shrinks and fades.
  ({Rect rect, HomeGridItem item})? _homeTarget;
  double _lastSwipeDy = 0;
  bool _shown = false;
  bool _heroVisible = false;
  DenialWindow? _lastHeroWindow;
  late List<DenialWindow> _windows;
  double _dragOrigin = 0;
  bool _heroPressed = false;
  final _heroKey = GlobalKey();
  final _heroPageOffset = ValueNotifier(Offset.zero);
  Drag? _pageDrag;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1.0 : 0.0,
    )..addListener(_updatePhase);
    widget.onProgressChanged?.call(_controller.value);
    _shown = widget.visible;
    if (_shown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _shown) widget.onPresentationChanged?.call(true);
      });
    }
    _syncWindows(resetOrder: true);
    widget.swipe.addListener(_handleDrag);
    _focusController = AnimationController(
      vsync: this,
      duration: Motion.focusZoom,
    )..addStatusListener(_handleFocusStatus);
    _homeController = AnimationController(vsync: this)
      ..addListener(_watchHomeLanding);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fraction = overviewPageViewportFractionFor(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    if (_pageViewportFraction == fraction) return;
    final previous = _pageViewportFraction == null ? null : _pageController;
    final page = previous?.hasClients == true
        ? (previous!.page ?? previous.initialPage.toDouble()).round()
        : previous?.initialPage ?? 0;
    _cancelPageDrag();
    previous?.removeListener(_syncHeroPageOffset);
    _pageViewportFraction = fraction;
    _pageController = OverviewPageController(
      initialPage: page,
      viewportFraction: fraction,
      keepPage: false,
    )..addListener(_syncHeroPageOffset);
    // Everything that moves a window on screen, for the cached glass slices.
    _backdropMotion = Listenable.merge([
      _controller,
      _focusController,
      _homeController,
      // The hero's page offset follows the page controller.
      _pageController,
    ]);
    // PageView detaches the previous position during this frame's build.
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  @override
  void didUpdateWidget(covariant OverviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onProgressChanged != oldWidget.onProgressChanged) {
      widget.onProgressChanged?.call(_controller.value);
    }
    if (widget.swipe != oldWidget.swipe) {
      oldWidget.swipe.removeListener(_handleDrag);
      widget.swipe.addListener(_handleDrag);
    }
    _syncWindows(resetOrder: !_shown && !widget.homeTransitionActive);
    if (_focusWindow != null &&
        (!widget.visible ||
            !_windows.any(
              (window) => window.objectId == _focusWindow!.objectId,
            ))) {
      _cancelFocus();
    }

    if (widget.homeTransitionActive && !oldWidget.homeTransitionActive) {
      final viewSize = MediaQuery.sizeOf(context);
      _lastHeroRect = Rect.lerp(
        Offset.zero & viewSize,
        _cardRectFor(viewSize),
        _controller.value,
      );
      _lastHeroWindow = oldWidget.foregroundWindow ?? _lastHeroWindow;
      _cancelFocus();
      _flyHome(viewSize);
      _settleTo(0);
      return;
    }
    if (!widget.homeTransitionActive && oldWidget.homeTransitionActive) {
      _homeController.stop();
      _homeController.value = 0.0;
      _landHome();
      if (!widget.visible) {
        // A launch from home cut the flight short. The strip must not
        // return as a hero of the app that is opening.
        _controller.stop();
        _controller.value = 0.0;
      }
    }

    if (widget.visible != oldWidget.visible) {
      if (!widget.visible) _cancelPageDrag();
      if (widget.visible) _centerPreviousOnOpen();
      _settleTo(widget.visible ? 1 : 0, velocity: _releaseVelocity);
      _releaseVelocity = 0;
      return;
    }

    _handleDrag();
  }

  void _handleDrag() {
    final dy = widget.swipe.value.dy;
    final wasDragging = _lastSwipeDy < 0;
    _lastSwipeDy = dy;
    if (widget.visible || widget.homeTransitionActive || _focusWindow != null) {
      return;
    }
    if (dy < 0 && !wasDragging) {
      _dragOrigin = _controller.value;
      _lastHeroWindow = widget.foregroundWindow;
      if (!_shown) _syncWindows(resetOrder: true);
    }
    final t = _dragProgressFor(dy);
    if (t > 0) {
      _controller.stop();
      _controller.value = (_dragOrigin + t).clamp(0.0, 1.0);
    } else if (wasDragging && _controller.value > 0) {
      // The release either cancels here or opens recents in the rebuild
      // that follows. Both continue the finger's velocity.
      final size = MediaQuery.sizeOf(context);
      _releaseVelocity =
          (-(widget.releaseVelocity?.call() ?? 0) / _referenceTravel(size))
              .clamp(-6.0, 6.0);
      _settleTo(0, velocity: _releaseVelocity);
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseVelocity = 0);
    }
  }

  /// [velocity] is in progress per second. A spring keeps the release
  /// velocity, where a fixed curve would restart the motion from rest.
  void _settleTo(double target, {double velocity = 0}) {
    final open = target == 1;
    springTo(
      _controller,
      target,
      // Velocity away from the target would first carry the cards backward.
      velocity: open ? math.max(0.0, velocity) : math.min(0.0, velocity),
      spring: open ? Motion.gentle : Motion.snappy,
      telemetryLabel: open ? 'overview_open' : 'overview_close',
    );
  }

  /// Releasing an app into recents brings the previous app, when there is
  /// one, to the center on the spring that settles the cards. The hero rides
  /// the page offset, so the whole strip moves as one.
  ///
  /// The strip follows the open spring's progress frame by frame. A driven
  /// scroll animation would make the cards ignore touches until it ends, so
  /// a quick swipe up to close the centered app would only page instead.
  void _centerPreviousOnOpen() {
    _pageFollow = null;
    final foreground = widget.foregroundWindow;
    if (foreground == null ||
        !foreground.isUserApp ||
        _windows.length < 2 ||
        _windows.first.objectId != foreground.objectId ||
        _pageDrag != null ||
        !_pageController.hasClients) {
      return;
    }
    final page = _pageController.page;
    if (page == null || page.round() != 0) return;
    final position = _pageController.position;
    final stride =
        position.viewportDimension * _pageController.viewportFraction;
    _pageFollow = (
      from: position.pixels,
      to: position.pixels + (1 - page) * stride,
      start: _controller.value,
    );
    _followPage();
  }

  /// Moves the strip to where the open spring has carried it, until the
  /// spring settles or a finger takes the strip.
  void _followPage() {
    final follow = _pageFollow;
    if (follow == null) return;
    if (!_pageController.hasClients ||
        _pageDrag != null ||
        _pageController.position.isScrollingNotifier.value ||
        !widget.visible) {
      _pageFollow = null;
      return;
    }
    final remaining = 1 - follow.start;
    final t = remaining <= 0.01
        ? 1.0
        : ((_controller.value - follow.start) / remaining).clamp(0.0, 1.0);
    _pageController.position.jumpTo(
      follow.from + (follow.to - follow.from) * t,
    );
    if (t >= 1) _pageFollow = null;
  }

  void _updatePhase() {
    widget.onProgressChanged?.call(_controller.value);
    _followPage();
    // Keep the final frame mounted until the entire carousel is off-screen.
    final shown = _controller.value > 0;
    final hero = shown && (_controller.value < 1 || _heroPressed);
    if (shown == _shown && hero == _heroVisible) return;
    if (shown != _shown) widget.onPresentationChanged?.call(shown);
    if (!shown) _heroPageOffset.value = Offset.zero;
    setState(() {
      _shown = shown;
      _heroVisible = hero;
    });
  }

  @override
  void dispose() {
    widget.swipe.removeListener(_handleDrag);
    _pageDrag?.cancel();
    _pageController.dispose();
    _heroPageOffset.dispose();
    _landHome();
    _homeController.dispose();
    _focusController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final homeActive = widget.homeTransitionActive;
    if (!_shown && !widget.visible && !homeActive) {
      return const SizedBox.shrink();
    }
    final heroWindow = homeActive || _focusWindow != null
        ? null
        : _foregroundHeroWindow(_controller.value);
    final overviewContent = _windows.isEmpty
        ? EmptyOverviewState(progress: _controller)
        : viewSize.width > viewSize.height
        ? OverviewGrid(
            windows: _windows,
            progress: _controller,
            foregroundObjectId: widget.foregroundObjectId,
            foregroundInHero: heroWindow != null,
            focusingObjectId: _focusWindow?.objectId,
            onDismissWindow: widget.onDismissWindow,
            onFocusWindow: _startFocusTransition,
          )
        : OverviewCarousel(
            windows: _windows,
            progress: _controller,
            focusProgress: _focusController,
            pageController: _pageController,
            foregroundObjectId: widget.foregroundObjectId,
            foregroundInHero: heroWindow != null,
            focusingObjectId: _focusWindow?.objectId,
            focusStartRect: _focusStartRect,
            labelOpacity: _labelOpacity,
            onDismissWindow: widget.onDismissWindow,
            onFocusWindow: _startFocusTransition,
          );

    final fullRect = Offset.zero & viewSize;
    final cardRect = _cardRectFor(viewSize);
    if (heroWindow != null) _lastHeroWindow = heroWindow;
    return Positioned.fill(
      child: GestureDetector(
        // PageView handles ordinary paging. This ancestor also accepts a swipe
        // that begins on the moving foreground app during overview entry.
        onHorizontalDragStart:
            widget.visible &&
                _heroVisible &&
                _focusWindow == null &&
                viewSize.width <= viewSize.height
            ? _startPageDrag
            : null,
        onHorizontalDragUpdate: (details) => _pageDrag?.update(details),
        onHorizontalDragEnd: _endPageDrag,
        onHorizontalDragCancel: _cancelPageDrag,
        child: ValueListenableBuilder<FrostedBackdrop?>(
          valueListenable:
              widget.backdrop ??
              const AlwaysStoppedAnimation<FrostedBackdrop?>(null),
          builder: (context, backdrop, stack) => WindowBackdropCache(
            // Landscape slots move by layout, which the slices do not follow.
            backdrop: viewSize.width > viewSize.height ? null : backdrop,
            motion: _backdropMotion,
            overlayColor: OverviewScrim.colorOf(context),
            overlayOpacity: _scrimOpacity,
            child: stack!,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: !widget.visible || _focusWindow != null,
                child: OverviewScrim(
                  opacity: _scrimOpacity,
                  onTap: widget.onDismissOverview,
                ),
              ),
              if (!homeActive)
                IgnorePointer(
                  ignoring: !widget.visible || _focusWindow != null,
                  child: overviewContent,
                ),
              if (heroWindow != null)
                CompositedTranslation(
                  translation: _heroPageOffset,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  child: IgnorePointer(
                    ignoring: !widget.visible,
                    child: RetainedWindowMotion(
                      progress: _controller,
                      begin: fullRect,
                      end: cardRect,
                      endRadius: context.shellTheme.windowRadius,
                      child: Listener(
                        onPointerDown: (_) => _heroPressed = true,
                        onPointerCancel: (_) => _releaseHero(),
                        child: GestureDetector(
                          key: _heroKey,
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _selectHero(heroWindow),
                          onTapCancel: _releaseHero,
                          child: WindowSurface(
                            window: heroWindow,
                            contentPadding: const EdgeInsets.only(
                              top: ReferenceShellMetrics.appStatusBarHeight,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (homeActive && _lastHeroWindow != null)
                ..._homeFlight(context, _lastHeroWindow!, viewSize),
              if (_focusWindow != null && _focusStartRect != null)
                OverviewFocusOverlay(
                  controller: _focusController,
                  window: _focusWindow!,
                  startRect: _focusStartRect!,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Rect _cardRectFor(Size viewSize) {
    if (viewSize.width > viewSize.height && _windows.isNotEmpty) {
      final layout = landscapeOverviewLayoutFor(
        viewSize: viewSize,
        padding: MediaQuery.paddingOf(context),
        itemCount: _windows.length,
        aspect: viewAspectFor(viewSize),
      );
      final foregroundIndex = _windows.indexWhere(
        (window) => window.objectId == widget.foregroundObjectId,
      );
      if (foregroundIndex >= 0) {
        return layout.previewRectAt(0);
      }
    }

    final cardSize = cardSizeFor(
      constraints: BoxConstraints.tight(viewSize),
      padding: MediaQuery.paddingOf(context),
      aspect: viewAspectFor(viewSize),
    );
    return centerPreviewRectFor(viewSize, cardSize);
  }

  /// Maps the live swipe travel to overview progress so that the app's bottom
  /// edge stays under the finger (reaching the card exactly at progress 1).
  double _dragProgressFor(double swipeDy) {
    if (swipeDy >= 0.0) {
      return 0.0;
    }
    final size = MediaQuery.sizeOf(context);
    if (size.height <= 0) {
      return 0.0;
    }
    return (-swipeDy / _referenceTravel(size)).clamp(0.0, 1.0).toDouble();
  }

  double _referenceTravel(Size size) {
    final window = widget.foregroundWindow;
    if (window == null || !window.isUserApp) {
      return size.height * 0.45;
    }
    return math.max(1.0, size.height - _cardRectFor(size).bottom);
  }

  DenialWindow? _foregroundHeroWindow(double progress) {
    final window = widget.foregroundWindow;
    if (window == null ||
        !window.isUserApp ||
        progress <= 0 ||
        (progress >= 1 && !_heroPressed)) {
      return null;
    }

    for (final candidate in _windows) {
      if (candidate.objectId == window.objectId) {
        return candidate;
      }
    }
    return null;
  }

  void _handleFocusStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    final window = _focusWindow;
    if (window == null) {
      return;
    }

    _controller.value = 0.0;
    widget.onFocusWindow(window);
    if (mounted) {
      setState(() {
        _focusWindow = null;
        _focusStartRect = null;
      });
    }
  }

  /// Home takes over once the app has visibly become its icon; the
  /// spring's remaining tail would only hold home back.
  void _watchHomeLanding() {
    if (_homeLanded ||
        !widget.homeTransitionActive ||
        _homeController.value < _homeLandedAt) {
      return;
    }
    _homeLanded = true;
    _landHome();
    widget.onHomeSettled();
  }

  /// Sends the app toward its home icon, carrying the finger's velocity.
  void _flyHome(Size viewSize) {
    final from = _lastHeroRect ?? Offset.zero & viewSize;
    final window = _lastHeroWindow;
    final icon = window == null ? null : widget.homeIcons?.iconFor(window);
    final box = context.findRenderObject();
    _homeTarget = icon == null || box is! RenderBox || !box.hasSize
        ? null
        : (rect: _globalToLocal(box, icon.rect), item: icon.item);
    if (_homeTarget?.item.id case final id?) widget.homeIcons?.hide(id);
    final to = _homeTarget?.rect ?? _homeFallbackRect(from, viewSize);
    final travel = to.center.dy - from.center.dy;
    final fingerVelocity = widget.releaseVelocity?.call() ?? 0;
    // Only velocity toward the icon carries over; a flick away from it
    // would first swing the app further off.
    final velocity = travel.abs() < 1
        ? 0.0
        : (fingerVelocity / travel).clamp(0.0, 8.0).toDouble();
    _homeLanded = false;
    _homeController.value = 0;
    springTo(
      _homeController,
      1,
      velocity: velocity,
      spring: Motion.iconReturn,
      telemetryLabel: 'overview_home',
    );
  }

  /// Shows the home icon again once the app has become it.
  void _landHome() {
    if (_homeTarget?.item.id case final id?) widget.homeIcons?.reveal(id);
    _homeTarget = null;
  }

  Rect _globalToLocal(RenderBox box, Rect global) => Rect.fromPoints(
    box.globalToLocal(global.topLeft),
    box.globalToLocal(global.bottomRight),
  );

  /// With no icon on screen the app shrinks toward the middle of home.
  Rect _homeFallbackRect(Rect from, Size viewSize) {
    const width = 120.0;
    return Rect.fromCenter(
      center: Offset(viewSize.width / 2, viewSize.height * 0.42),
      width: width,
      height: from.width <= 0 ? width : width * from.height / from.width,
    );
  }

  List<Widget> _homeFlight(
    BuildContext context,
    DenialWindow window,
    Size viewSize,
  ) {
    final from = _lastHeroRect ?? Offset.zero & viewSize;
    final target = _homeTarget;
    final to = target?.rect ?? _homeFallbackRect(from, viewSize);
    return [
      IgnorePointer(
        child: RetainedWindowMotion(
          progress: _homeController,
          begin: from,
          end: to,
          beginRadius: context.shellTheme.windowRadius,
          endRadius: target == null
              ? context.shellTheme.windowRadius
              : to.width * HomeTileMetrics.iconRadiusFraction,
          // Into an icon the app fills the square as an icon does.
          cover: target != null,
          child: FadeTransition(
            opacity: _homeController.drive(
              target == null ? _fallbackFade : _windowIntoIconFade,
            ),
            child: WindowSurface(
              window: window,
              contentPadding: const EdgeInsets.only(
                top: ReferenceShellMetrics.appStatusBarHeight,
              ),
            ),
          ),
        ),
      ),
      if (target != null)
        Positioned.fromRect(
          rect: target.rect,
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _homeController.drive(_iconArrivesFade),
              child: HomeItemIcon(item: target.item, rasterize: true),
            ),
          ),
        ),
    ];
  }

  void _startFocusTransition(DenialWindow window, Rect startRect) {
    if (_focusWindow != null || !widget.visible) return;
    _cancelPageDrag();
    if (_pageController.hasClients) {
      _pageController.jumpTo(_pageController.offset);
    }
    _controller.stop();
    _heroPressed = false;
    setState(() {
      _focusWindow = window;
      _focusStartRect = startRect;
    });
    MotionTelemetry.observe(
      _focusController,
      _focusController.forward(from: 0.0),
      'overview_focus',
      target: 1.0,
    );
  }

  void _releaseHero() {
    _heroPressed = false;
    _updatePhase();
  }

  void _selectHero(DenialWindow window) {
    final render = _heroKey.currentContext?.findRenderObject();
    if (render is RenderBox) {
      final rect = MatrixUtils.transformRect(
        render.getTransformTo(null),
        Offset.zero & render.size,
      );
      _startFocusTransition(window, rect);
    }
    _releaseHero();
  }

  void _cancelFocus() {
    _cancelPageDrag();
    _focusController.stop();
    _focusWindow = null;
    _focusStartRect = null;
    _heroPressed = false;
  }

  void _syncHeroPageOffset() {
    _heroPageOffset.value = _pageController.hasClients
        ? Offset(_pageController.offset, 0)
        : Offset.zero;
  }

  void _startPageDrag(DragStartDetails details) {
    if (!_pageController.hasClients) return;
    _cancelPageDrag();
    _pageDrag = _pageController.position.drag(details, () => _pageDrag = null);
  }

  void _endPageDrag(DragEndDetails details) {
    final drag = _pageDrag;
    _pageDrag = null;
    drag?.end(details);
  }

  void _cancelPageDrag() {
    final drag = _pageDrag;
    _pageDrag = null;
    drag?.cancel();
  }

  void _syncWindows({required bool resetOrder}) {
    final byId = {for (final window in widget.windows) window.objectId: window};
    if (resetOrder) {
      final foreground = byId.remove(widget.foregroundObjectId);
      _windows = [?foreground, ...byId.values.toList().reversed];
    } else {
      _windows = [
        for (final previous in _windows) ?byId.remove(previous.objectId),
        ...byId.values.toList().reversed,
      ];
    }
  }
}

/// Recents chrome follows the overview in, then fades out under a focus zoom
/// with the same curve the zooming card uses.
class _ChromeOpacity extends CompoundAnimation<double> {
  _ChromeOpacity(this._state, {required this.reveal})
    : super(first: _state._controller, next: _state._focusController);

  final _OverviewLayerState _state;
  final Curve reveal;

  @override
  double get value {
    final shown = reveal.transform(first.value.clamp(0.0, 1.0));
    if (_state._focusWindow == null) return shown;
    return shown * (1 - Motion.standard.transform(next.value));
  }
}

/// The window gives way to its icon over the last stretch of the flight.
final _windowIntoIconFade = Tween<double>(
  begin: 1,
  end: 0,
).chain(CurveTween(curve: const Interval(0.78, 1, curve: Curves.easeIn)));
final _iconArrivesFade = CurveTween(
  curve: const Interval(0.55, 0.92, curve: Curves.easeOut),
);
final _fallbackFade = Tween<double>(
  begin: 1,
  end: 0,
).chain(CurveTween(curve: const Interval(0.4, 1, curve: Curves.easeIn)));
