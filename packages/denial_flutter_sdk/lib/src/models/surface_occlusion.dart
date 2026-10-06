/// A logical rectangle independent of Flutter, for deterministic geometry tests.
typedef SurfaceBounds = ({
  double left,
  double top,
  double right,
  double bottom,
});

/// Returns back-to-front layers which may contribute to a clipped composition.
/// Coverage is conservative: only one completely opaque rectangle may hide a
/// lower layer. Partial/translucent overlaps always retain their original order.
List<T> unoccludedSurfaceLayers<T>(
  Iterable<T> layers, {
  required SurfaceBounds clip,
  required bool Function(T) paints,
  required bool Function(T) opaque,
  required SurfaceBounds Function(T) bounds,
}) {
  final visible = <T>[];
  final covers = <SurfaceBounds>[];
  for (final layer in layers.toList(growable: false).reversed) {
    if (!paints(layer)) continue;
    final source = bounds(layer);
    final rect = (
      left: source.left > clip.left ? source.left : clip.left,
      top: source.top > clip.top ? source.top : clip.top,
      right: source.right < clip.right ? source.right : clip.right,
      bottom: source.bottom < clip.bottom ? source.bottom : clip.bottom,
    );
    if (rect.right <= rect.left || rect.bottom <= rect.top) continue;
    if (covers.any(
      (cover) =>
          cover.left <= rect.left &&
          cover.top <= rect.top &&
          cover.right >= rect.right &&
          cover.bottom >= rect.bottom,
    )) {
      continue;
    }
    visible.add(layer);
    // Bound work for client-controlled trees. Ignoring additional coverage
    // hints only draws more layers; it can never hide visible content.
    if (opaque(layer) && covers.length < 64) covers.add(rect);
  }
  return visible.reversed.toList(growable: false);
}

/// Proves that a fully opaque base plus interior overlays can be drawn without
/// a composed-input texture. The inset excludes every rounded/AA edge.
bool canDrawInteriorSurfaceLayers<T>(
  List<T> layers, {
  required SurfaceBounds content,
  required double edgeInset,
  required bool hasBackdrop,
  required bool Function(T) opaque,
  required SurfaceBounds Function(T) bounds,
}) {
  if (hasBackdrop || layers.length < 2 || !opaque(layers.first)) return false;
  final base = bounds(layers.first);
  if (base.left > content.left ||
      base.top > content.top ||
      base.right < content.right ||
      base.bottom < content.bottom) {
    return false;
  }
  final safe = (
    left: content.left + edgeInset,
    top: content.top + edgeInset,
    right: content.right - edgeInset,
    bottom: content.bottom - edgeInset,
  );
  if (safe.right <= safe.left || safe.bottom <= safe.top) return false;
  for (final layer in layers.skip(1)) {
    final rect = bounds(layer);
    if (rect.right <= rect.left ||
        rect.bottom <= rect.top ||
        rect.left < safe.left ||
        rect.top < safe.top ||
        rect.right > safe.right ||
        rect.bottom > safe.bottom) {
      return false;
    }
  }
  return true;
}
