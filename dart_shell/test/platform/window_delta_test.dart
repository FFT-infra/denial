import 'package:denial_flutter_sdk/wire.dart';
import 'package:flutter_test/flutter_test.dart';

WindowObjectBuilder window(int id, {String title = ''}) => WindowObjectBuilder(
  objectId: id,
  surfaceId: id,
  windowId: id,
  textureId: id,
  width: 100,
  height: 80,
  contentWidth: 100,
  contentHeight: 80,
  textureSourceWidth: 100,
  textureSourceHeight: 80,
  title: title,
);

WindowSnapshot snapshot(
  List<WindowObjectBuilder> windows, {
  bool delta = false,
  List<int>? order,
}) => WindowSnapshot(
  WindowSnapshotObjectBuilder(
    windows: windows,
    delta: delta,
    windowOrder: order,
  ).toBytes(),
);

void main() {
  test(
    'deltas retain unchanged windows across edits, reorders and removals',
    () {
      final codec = DenialWireCodec();
      final first = codec.decodeWindows(snapshot([window(1), window(2)]))!;
      final updated = codec.decodeWindows(
        snapshot([window(2, title: 'new')], delta: true, order: [1, 2]),
      )!;
      expect(identical(first[0], updated[0]), isTrue);
      expect(identical(first[1], updated[1]), isFalse);
      expect(updated[1].title, 'new');
      final reordered = codec.decodeWindows(
        snapshot([], delta: true, order: [2, 1]),
      )!;
      expect(identical(reordered[0], updated[1]), isTrue);
      expect(identical(reordered[1], first[0]), isTrue);
      final removed = codec.decodeWindows(
        snapshot([], delta: true, order: [1]),
      )!;
      expect(identical(removed.single, first[0]), isTrue);
      expect(
        codec.decodeWindows(snapshot([], delta: true, order: [])),
        isEmpty,
      );
    },
  );

  test('late full responses cannot roll back the delta base', () {
    final codec = DenialWireCodec();
    codec.decodeWindows(snapshot([window(1)]), sequence: 10);
    final current = codec.decodeWindows(
      snapshot([window(1, title: 'new')], delta: true, order: [1]),
      sequence: 12,
    )!;
    final late = codec.decodeWindows(snapshot([window(1)]), sequence: 11)!;
    expect(identical(late.single, current.single), isTrue);
    final next = codec.decodeWindows(
      snapshot([], delta: true, order: [1]),
      sequence: 13,
    )!;
    expect(next.single.title, 'new');
  });

  test('invalid deltas cannot damage the accepted snapshot', () {
    final codec = DenialWireCodec();
    expect(codec.decodeWindows(snapshot([], delta: true, order: [])), isNull);
    final first = codec.decodeWindows(snapshot([window(1)]))!;
    for (final invalid in [
      snapshot([], delta: true, order: [2]),
      snapshot([], delta: true, order: [1, 1]),
      snapshot([window(2)], delta: true, order: [1]),
    ]) {
      expect(codec.decodeWindows(invalid), isNull);
      final preserved = codec.decodeWindows(
        snapshot([], delta: true, order: [1]),
      )!;
      expect(identical(preserved.single, first.single), isTrue);
    }
    expect(codec.decodeWindows(snapshot([window(2)]))!.single.windowId, 2);
  });
}
