import 'dart:ui' show SemanticsAction;

import 'package:flutter/widgets.dart';

/// Lets a fling coast freely across tasks, then centers the nearest preview.
/// Past either end the strip stretches elastically and springs back.
class OverviewScrollPhysics extends BouncingScrollPhysics {
  const OverviewScrollPhysics({super.parent});

  @override
  OverviewScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      OverviewScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (position is! PageMetrics) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (velocity.abs() >= tolerance.velocity) {
      final fling = _ElasticFlingSimulation.from(
        position,
        velocity,
        spring: spring,
        tolerance: tolerance,
      );
      if (fling != null) return fling;
    }
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final stride = position.viewportDimension * position.viewportFraction;
    if (stride <= 0) return null;
    final page = position.page;
    if (page == null) return null;
    final target = (position.pixels + (page.roundToDouble() - page) * stride)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    // Flutter re-enters ballistics with zero velocity when the free fling
    // ends. Settle only then, rather than choosing the next page on release.
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// The clamping fling recents always had, except that it springs back from
/// whichever end it crosses instead of stopping dead there.
class _ElasticFlingSimulation extends Simulation {
  _ElasticFlingSimulation._(this._fling, {required super.tolerance});

  /// A fling from where the strip is, also while it is stretched past an
  /// end: a flick back toward the tasks coasts into them. Null when the
  /// fling would come to rest past the end the strip is already stretched
  /// past, so a flick outward, or one too weak to clear the edge, springs
  /// back instead.
  static _ElasticFlingSimulation? from(
    ScrollMetrics position,
    double velocity, {
    required SpringDescription spring,
    required Tolerance tolerance,
  }) {
    final simulation = _ElasticFlingSimulation._(
      ClampingScrollSimulation(
        position: position.pixels,
        velocity: velocity,
        tolerance: tolerance,
      ),
      tolerance: tolerance,
    );
    double? endPast(double x) => x < position.minScrollExtent
        ? position.minScrollExtent
        : x > position.maxScrollExtent
        ? position.maxScrollExtent
        : null;
    final fling = simulation._fling;
    final edge = endPast(fling.x(double.infinity));
    if (edge == null) return simulation;
    if (edge == endPast(position.pixels)) return null;
    // The fling is monotonic: bisect for the moment it reaches the edge.
    var before = 0.0;
    var after = 10.0;
    for (var i = 0; i < 40; i++) {
      final middle = (before + after) / 2;
      if ((fling.x(middle) - edge) * velocity.sign < 0) {
        before = middle;
      } else {
        after = middle;
      }
    }
    simulation._edgeTime = after;
    simulation._bounce = ScrollSpringSimulation(
      spring,
      edge,
      edge,
      fling.dx(after),
      tolerance: tolerance,
    );
    return simulation;
  }

  final ClampingScrollSimulation _fling;
  double _edgeTime = double.infinity;
  Simulation? _bounce;

  @override
  double x(double time) =>
      time < _edgeTime ? _fling.x(time) : _bounce!.x(time - _edgeTime);

  @override
  double dx(double time) =>
      time < _edgeTime ? _fling.dx(time) : _bounce!.dx(time - _edgeTime);

  @override
  bool isDone(double time) => time < _edgeTime
      ? _bounce == null && _fling.isDone(time)
      : _bounce!.isDone(time - _edgeTime);
}

/// Keeps moving recents interactive so a tap can stop paging and select a task.
class OverviewPageController extends PageController {
  OverviewPageController({
    super.initialPage,
    super.keepPage,
    super.viewportFraction,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => super.createScrollPosition(
    physics,
    _InteractiveScrollContext(context),
    oldPosition,
  );
}

class _InteractiveScrollContext implements ScrollContext {
  _InteractiveScrollContext(this.delegate);

  final ScrollContext delegate;

  // Scrollable normally excludes its children from hit testing while coasting.
  // Recents must hit the preview under the initial contact, before Scrollable
  // holds the animation. The gesture arena still cancels taps on actual drags.
  @override
  void setIgnorePointer(bool value) => delegate.setIgnorePointer(false);

  @override
  BuildContext? get notificationContext => delegate.notificationContext;

  @override
  BuildContext get storageContext => delegate.storageContext;

  @override
  TickerProvider get vsync => delegate.vsync;

  @override
  AxisDirection get axisDirection => delegate.axisDirection;

  @override
  double get devicePixelRatio => delegate.devicePixelRatio;

  @override
  void setCanDrag(bool value) => delegate.setCanDrag(value);

  @override
  void setSemanticsActions(Set<SemanticsAction> actions) =>
      delegate.setSemanticsActions(actions);

  @override
  void saveOffset(double offset) => delegate.saveOffset(offset);
}
