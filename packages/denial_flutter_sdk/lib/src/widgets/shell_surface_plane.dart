import 'package:flutter/widgets.dart';

import '../../surfaces.dart';
import '../../input.dart';
import 'shell_surface_transition.dart';
import '../surfaces/surface_events.dart';

/// A resolved plugin declaration. Resolution is shared by painting and layout.
@immutable
final class ShellSurfaceEntry {
  const ShellSurfaceEntry({
    required this.surface,
    required this.environment,
    required this.placement,
  });
  final ShellSurface surface;
  final ShellSurfaceEnvironment environment;
  final ShellSurfacePlacement placement;
}

List<ShellSurfaceEntry> resolveShellSurfaces(
  List<ShellSurface> surfaces,
  Iterable<ShellSurfaceEnvironment> environments,
) {
  final outputEnvironments = List<ShellSurfaceEnvironment>.of(environments);
  final ids = <String>{};
  final result = <ShellSurfaceEntry>[];
  for (final surface in surfaces) {
    if (surface.id.isEmpty || !ids.add(surface.id)) {
      throw StateError(
        'Surface IDs must be nonempty and unique: ${surface.id}',
      );
    }
    for (final environment in outputEnvironments) {
      final placement = surface.place(environment);
      if (placement == null) continue;
      if (!placement.bounds.isFinite || placement.bounds.isEmpty) {
        throw StateError('Invalid surface bounds: ${surface.id}');
      }
      result.add(
        ShellSurfaceEntry(
          surface: surface,
          environment: environment,
          placement: placement,
        ),
      );
    }
  }
  return List.unmodifiable(result);
}

/// Mounts arbitrary plugin bounds; contains no bar/clock/fullscreen policy.
class ShellSurfacePlane extends StatelessWidget {
  const ShellSurfacePlane({
    required this.entries,
    required this.layer,
    required this.services,
    super.key,
  });
  final List<ShellSurfaceEntry> entries;
  final ShellSurfaceLayer layer;
  final ShellServices services;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (final entry in entries)
        if (entry.surface.layer == layer)
          Positioned.fromRect(
            key: ValueKey((
              entry.surface.id,
              entry.environment.output.monitorId,
            )),
            rect: entry.environment.output.logicalRect,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fromRect(
                    rect: entry.placement.bounds.shift(
                      -entry.environment.output.logicalRect.topLeft,
                    ),
                    child: ShellInputClip(
                      bounds:
                          ShellInputClip.boundsOf(
                            context,
                          )?.intersect(entry.environment.output.logicalRect) ??
                          entry.environment.output.logicalRect,
                      child: _SurfaceInstance(entry: entry, services: services),
                    ),
                  ),
                ],
              ),
            ),
          ),
    ],
  );
}

class _SurfaceInstance extends StatefulWidget {
  const _SurfaceInstance({required this.entry, required this.services});
  final ShellSurfaceEntry entry;
  final ShellServices services;
  @override
  State<_SurfaceInstance> createState() => _SurfaceInstanceState();
}

class _SurfaceInstanceState extends State<_SurfaceInstance> {
  late final SurfaceEvents<ShellSurfaceEnvironment> _events;

  @override
  void initState() {
    super.initState();
    _events = SurfaceEvents(widget.entry.environment);
  }

  @override
  void didUpdateWidget(_SurfaceInstance oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Async delivery lets listeners update their own widget state safely.
    _events.update(widget.entry.environment);
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return ShellSurfaceTransition(
      visible: entry.placement.visible,
      durationScale: entry.environment.settings.animations.durationScale,
      child: Builder(
        builder: (context) {
          final child = entry.surface.build(
            context,
            surface: ShellSurfaceContext(
              environment: entry.environment,
              events: _events.stream,
              services: widget.services,
            ),
          );
          return entry.placement.fade == ShellSurfaceFade.custom
              ? child
              : FadeTransition(
                  opacity: ShellSurfacePresentation.opacityOf(context),
                  child: child,
                );
        },
      ),
    );
  }
}
