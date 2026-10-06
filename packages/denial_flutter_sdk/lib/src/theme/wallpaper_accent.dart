import 'package:flutter/widgets.dart';

import 'shell_theme.dart';
import 'tokens.dart';

/// Shell theme colors derived from the current wallpaper.
///
/// [color] is a seed carrying the wallpaper's dominant hue and chroma. The
/// active [ShellThemeData] resolves that seed into brightness-safe roles.
@immutable
class WallpaperAccent {
  const WallpaperAccent(this.color, {this.isResolved = true});

  /// The brand accent used until extraction produces a wallpaper color.
  static const WallpaperAccent fallback = WallpaperAccent(
    ShellBrandColors.defaultAccent,
    isResolved: false,
  );

  /// The same brand color after extraction established that the wallpaper has
  /// no useful chroma. This may be published; the temporary fallback may not.
  static const WallpaperAccent resolvedFallback = WallpaperAccent(
    ShellBrandColors.defaultAccent,
  );

  final Color color;
  final bool isResolved;

  /// Card fill for system bar cards. The shell theme supplies the shared
  /// frosted-surface opacity at the point of use.
  Color cardFill(ShellThemeData theme) =>
      Color.lerp(theme.colors.surfaceContainer, theme.accent, 0.15)!;

  /// Top stop of the card gradient: [cardFill] nudged further toward the
  /// accent so pills read as softly lit from above.
  Color cardFillTop(ShellThemeData theme) =>
      Color.lerp(theme.colors.surfaceContainer, theme.accent, 0.24)!;

  /// Secondary text inside system bar cards, tinted toward the accent so
  /// captions re-theme with the wallpaper without losing legibility.
  Color captionColor(ShellThemeData theme) =>
      Color.lerp(theme.colors.textSecondary, theme.accent, 0.35)!;

  @override
  bool operator ==(Object other) =>
      other is WallpaperAccent &&
      other.color == color &&
      other.isResolved == isResolved;

  @override
  int get hashCode => Object.hash(color, isResolved);
}
