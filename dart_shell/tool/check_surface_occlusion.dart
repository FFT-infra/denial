// Run with the pinned Dart SDK; no Flutter development engine is needed.
import 'dart:io';

import 'package:denial_flutter_sdk/models.dart';

typedef Layer = ({int id, SurfaceBounds rect, bool opaque, bool paints});
const area = (left: 0.0, top: 0.0, right: 100.0, bottom: 80.0);
Layer layer(
  int id, {
  SurfaceBounds rect = area,
  bool opaque = true,
  bool paints = true,
}) => (id: id, rect: rect, opaque: opaque, paints: paints);

void check(List<Layer> layers, List<int> expected) {
  final result = unoccludedSurfaceLayers(
    layers,
    clip: area,
    paints: (layer) => layer.paints,
    opaque: (layer) => layer.opaque,
    bounds: (layer) => layer.rect,
  ).map((layer) => layer.id).toList();
  if (result.join(',') != expected.join(',')) {
    throw StateError('Expected $expected, got $result');
  }
}

void main() {
  check([layer(1), layer(2)], [2]); // Opaque child hides carrier root.
  check([layer(1), layer(2, opaque: false)], [1, 2]);
  check([layer(1), layer(2, paints: false)], [1]);
  check(
    [layer(1), layer(2, rect: (left: 0, top: 0, right: 50, bottom: 80))],
    [1, 2],
  );
  check(
    [layer(1), layer(2, rect: (left: -10, top: -10, right: 110, bottom: 90))],
    [2],
  );
  check(
    [layer(1), layer(2, rect: (left: 100, top: 0, right: 150, bottom: 80))],
    [1],
  );
  check(
    [layer(1), layer(2, rect: (left: 0.01, top: 0, right: 100, bottom: 80))],
    [1, 2],
  );
  check([layer(2), layer(1)], [1]); // Stacking order remains authoritative.
  check([layer(1), layer(2), layer(3, opaque: false)], [2, 3]);

  bool direct(List<Layer> layers, {bool backdrop = false}) =>
      canDrawInteriorSurfaceLayers(
        layers,
        content: area,
        edgeInset: 9,
        hasBackdrop: backdrop,
        opaque: (layer) => layer.opaque,
        bounds: (layer) => layer.rect,
      );
  final interior = layer(2, rect: (left: 12, top: 12, right: 52, bottom: 52));
  if (!direct([layer(1), interior]) ||
      direct([layer(1, opaque: false), interior]) ||
      direct([layer(1), interior], backdrop: true) ||
      direct([layer(1), layer(2)]) ||
      !direct([layer(1), layer(2, opaque: false, rect: interior.rect)])) {
    throw StateError('Interior direct composition eligibility is incorrect');
  }

  // Compare the retained plan with source-over compositing at every pixel.
  // Fractional alpha on upper layers must never hide a lower contribution.
  for (var seed = 0; seed < 100; seed++) {
    final layers = List.generate(
      12,
      (i) => layer(
        i,
        opaque: (seed + i) % 3 != 0,
        rect: (
          left: ((seed * i) % 40).toDouble(),
          top: 0,
          right: (50 + (seed + i) % 51).toDouble(),
          bottom: 80,
        ),
      ),
    );
    final kept = unoccludedSurfaceLayers(
      layers,
      clip: area,
      paints: (layer) => layer.paints,
      opaque: (layer) => layer.opaque,
      bounds: (layer) => layer.rect,
    );
    double composite(Iterable<Layer> input, double x) {
      var value = 0.0;
      for (final layer in input) {
        if (x >= layer.rect.left && x < layer.rect.right) {
          final alpha = layer.opaque ? 1.0 : 0.5;
          value = layer.id * alpha + value * (1 - alpha);
        }
      }
      return value;
    }

    for (var x = 0.5; x < 100; x++) {
      if (composite(layers, x) != composite(kept, x)) {
        throw StateError('Compositing changed at seed=$seed, x=$x');
      }
    }
  }
  stdout.writeln(
    'Surface occlusion: coverage, alpha, clipping, order and 10,000 samples passed.',
  );
}
