@Plugin()
library;

import 'dart:math' as math;

import 'package:denial_sdk/composition.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_clock_ui/clock_face.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@Provides(ShellSurface)
final class DesktopClockPlugin implements ShellSurface {
  const DesktopClockPlugin();
  @override
  String get id => 'denial_clock.desktop';
  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.desktop;
  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    if (!environment.isMainOutput) return null;
    final area = environment.workArea.deflate(32);
    if (area.isEmpty) return null;
    final height = math.min(260.0, area.height * .28);
    return ShellSurfacePlacement(
      bounds: Rect.fromLTWH(
        area.left,
        area.top,
        math.min(area.width, height * 2),
        height,
      ),
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
      occupiesDesktop: true,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      Consumer(
        builder: (context, ref, _) => RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: HomeClockWidget(clock: ref.watch(homeClockProvider)),
          ),
        ),
      );
}
