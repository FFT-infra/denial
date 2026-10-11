import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../shell_theme.dart';

/// Connection and signal-strength glyph shared by mobile and desktop surfaces.
class WifiStatusIcon extends StatelessWidget {
  const WifiStatusIcon({
    super.key,
    required this.active,
    this.strength = 0,
    this.size = 17,
    this.color,
  });

  final bool active;
  final int strength;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    return Icon(
      !active
          ? Icons.wifi_off_rounded
          : strength == 0
          ? Icons.signal_wifi_0_bar
          : strength < 34
          ? Icons.network_wifi_1_bar
          : strength < 67
          ? Icons.network_wifi_2_bar
          : Icons.wifi_rounded,
      color: active ? foreground : foreground.withValues(alpha: 0.35),
      size: size,
    );
  }
}
