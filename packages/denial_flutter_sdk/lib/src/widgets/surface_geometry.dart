import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';

/// The resolved corner radius of the containing surface, in logical pixels.
/// At the application boundary, Denial's window radius supplies the default.
/// A material publishes its resolved radius here for deeper nesting.
class DenialSurfaceGeometry extends InheritedWidget {
  const DenialSurfaceGeometry({
    required this.radius,
    required super.child,
    super.key,
  }) : assert(radius >= 0);

  /// Application surfaces retain a small corner even when their parent is
  /// square or the inset exceeds its radius. This is a resolved logical size.
  static const double defaultMinimumRadius = 4;

  final double radius;

  static double radiusOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DenialSurfaceGeometry>()
          ?.radius ??
      ShellTheme.of(context).windowRadius;

  /// Both values are already in logical pixels. Do not scale the result again.
  static double nestedRadius(
    BuildContext context, {
    required double inset,
    double minimumRadius = defaultMinimumRadius,
  }) {
    assert(inset >= 0);
    assert(minimumRadius >= 0);
    return math.max(minimumRadius, radiusOf(context) - inset);
  }

  static BorderRadius borderRadiusOf(
    BuildContext context, {
    double inset = 0,
    double minimumRadius = defaultMinimumRadius,
  }) => BorderRadius.circular(
    nestedRadius(context, inset: inset, minimumRadius: minimumRadius),
  );

  @override
  bool updateShouldNotify(DenialSurfaceGeometry oldWidget) =>
      radius != oldWidget.radius;
}
