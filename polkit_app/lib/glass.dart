import 'dart:math' as math;

import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

/// Colors and material budgets of the prompt, resolved from the shell theme.
///
/// The compositor frosts the overlay per pixel, only where its alpha exceeds
/// the user's opacity threshold. The card therefore stays above it, while
/// its shadow and halo stay below it and never turn into glass.
@immutable
class PromptPalette {
  const PromptPalette._({
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.foreground,
    required this.secondary,
    required this.tertiary,
    required this.danger,
    required this.warning,
    required this.cardTop,
    required this.cardBottom,
    required this.rimTop,
    required this.rimBottom,
    required this.shadow,
  });

  static final _cache = Expando<PromptPalette>();

  factory PromptPalette.of(ShellThemeData theme) =>
      _cache[theme] ??= PromptPalette._resolve(theme);

  factory PromptPalette._resolve(ShellThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final colors = theme.colors;
    final accent = theme.accentPalette;
    final glass = theme.transparencyMode == ShellTransparencyMode.glass;
    final threshold = theme.backdropBlurOpacityThreshold
        .clamp(0.0, 1.0)
        .toDouble();
    final frosted =
        theme.backdropBlurEnabled &&
        (glass || theme.backdropBlurSigma > 0) &&
        threshold < 1;
    final requested = theme.effectivePanelOpacity;
    final cardAlpha = !theme.backdropBlurEnabled
        ? 1.0
        : frosted
        // Above the threshold, with a floor that keeps text legible.
        ? math.max(math.max(requested, .34), math.min(threshold + .05, 1.0))
        : math.max(requested, .92);
    final backing = dark ? Colors.black : Colors.white;
    Color card(Color color) => (glass ? backing : color.withValues(alpha: 1))
        .withValues(alpha: cardAlpha);
    // Unfrosted, any shadow is fine. Frosted, the darkest shadow pixel must
    // remain at or below the threshold, or it would gain a glass halo.
    final budget = frosted ? threshold - .015 : 1.0;
    final shadowAlpha = budget < .03
        ? 0.0
        : math.min(dark ? .42 : .2, budget * .7);
    return PromptPalette._(
      accent: accent.primary,
      onAccent: accent.onPrimary,
      accentContainer: accent.container,
      foreground: colors.textPrimary,
      secondary: colors.textSecondary,
      tertiary: colors.textTertiary,
      danger: colors.performanceBad,
      warning: colors.performanceWarning,
      cardTop: card(colors.panelBackground),
      cardBottom: card(colors.panelBackgroundBottom),
      rimTop: dark
          ? Colors.white.withValues(alpha: .26)
          : Colors.white.withValues(alpha: .95),
      rimBottom: dark
          ? Colors.white.withValues(alpha: .05)
          : Colors.black.withValues(alpha: .07),
      shadow: Colors.black.withValues(alpha: shadowAlpha),
    );
  }

  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color foreground;
  final Color secondary;
  final Color tertiary;
  final Color danger;
  final Color warning;
  final Color cardTop;
  final Color cardBottom;
  final Color rimTop;
  final Color rimBottom;
  final Color shadow;
}

/// A uniform outline, optionally outside the shape, for focus and errors.
class OutlinePainter extends CustomPainter {
  const OutlinePainter({
    required this.borderRadius,
    required this.color,
    this.outset = 0,
  });

  final BorderRadius borderRadius;
  final Color color;
  final double outset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      borderRadius.toRRect(Offset.zero & size).inflate(outset - .75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(OutlinePainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.color != color ||
      oldDelegate.outset != outset;
}

/// A hairline lit from above, fading toward the lower edge.
class RimPainter extends CustomPainter {
  const RimPainter({
    required this.borderRadius,
    required this.top,
    required this.bottom,
    this.specular = false,
  });

  final BorderRadius borderRadius;
  final Color top;
  final Color bottom;

  /// Adds a brighter glint along the upper straight edge.
  final bool specular;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    canvas.drawRRect(
      borderRadius.toRRect(bounds).deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(bounds),
    );
    if (!specular) return;
    final inset = math.max(borderRadius.topLeft.x, 12.0);
    final glint = Rect.fromLTWH(inset, 0, size.width - inset * 2, 1.5);
    if (glint.width <= 0) return;
    canvas.drawRect(
      glint,
      Paint()
        ..shader = LinearGradient(
          colors: [
            top.withValues(alpha: 0),
            top.withValues(alpha: math.min(1, top.a * 2.2)),
            top.withValues(alpha: 0),
          ],
        ).createShader(glint),
    );
  }

  @override
  bool shouldRepaint(RimPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.top != top ||
      oldDelegate.bottom != bottom ||
      oldDelegate.specular != specular;
}

/// The card body: one flat translucent fill.
class CardPainter extends CustomPainter {
  const CardPainter({required this.palette, required this.borderRadius});

  final PromptPalette palette;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRRect(
      borderRadius.toRRect(Offset.zero & size),
      Paint()..color = palette.cardTop,
    );
  }

  @override
  bool shouldRepaint(CardPainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.borderRadius != borderRadius;
}

/// A shadow outside the card only. Painting them under the
/// translucent card would darken it, so the card's own area is cut out.
class CardShadowPainter extends CustomPainter {
  const CardShadowPainter({required this.palette, required this.borderRadius});

  final PromptPalette palette;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || palette.shadow.a == 0) return;
    final shape = borderRadius.toRRect(Offset.zero & size);
    final extent = (Offset.zero & size).inflate(64);
    canvas.saveLayer(extent, Paint());
    {
      canvas.drawRRect(
        shape.shift(const Offset(0, 16)),
        Paint()
          ..color = palette.shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
      );
      canvas.drawRRect(
        shape.shift(const Offset(0, 2)),
        Paint()
          ..color = palette.shadow.withValues(alpha: palette.shadow.a * .5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    canvas.drawRRect(shape, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(CardShadowPainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.borderRadius != borderRadius;
}
