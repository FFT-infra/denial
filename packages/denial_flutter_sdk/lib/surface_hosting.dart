/// Hosting primitives for shell compositions, not widget authoring.
///
/// Resolve plugin declarations once per scene update, then mount each layer with
/// ShellSurfacePlane. Plugin authors import surfaces.dart instead. Native work
/// areas are applied separately through the SDK display-layout controller.
library;

export 'src/widgets/shell_surface_plane.dart'
    show ShellSurfaceEntry, ShellSurfacePlane, resolveShellSurfaces;
