import 'package:denial_flutter_sdk/src/surfaces/surface_events.dart';
import 'package:test/test.dart';

void main() {
  test(
    'stable broadcast events omit initial and unchanged snapshots',
    () async {
      final events = SurfaceEvents((workspace: 1, fullscreen: false));
      final seen = <({int workspace, bool fullscreen})>[];
      final other = <({int workspace, bool fullscreen})>[];
      expect(identical(events.stream, events.stream), isTrue);
      final first = events.stream.listen(seen.add);
      final second = events.stream.listen(other.add);
      events.update((workspace: 1, fullscreen: false));
      events.update((workspace: 2, fullscreen: false));
      events.update((workspace: 2, fullscreen: false));
      events.update((workspace: 2, fullscreen: true));
      // A plugin listener must never be called during the host's build/update.
      expect(seen, isEmpty);
      await events.close();
      expect(seen, [
        (workspace: 2, fullscreen: false),
        (workspace: 2, fullscreen: true),
      ]);
      expect(other, seen);
      await first.cancel();
      await second.cancel();
    },
  );

  test('changes before subscription are not replayed', () async {
    final events = SurfaceEvents(0);
    events.update(1);
    final seen = <int>[];
    final subscription = events.stream.listen(seen.add);
    events.update(1);
    events.update(2);
    await events.close();
    expect(seen, [2]);
    await subscription.cancel();
  });

  test(
    'closing an instance completes listeners and rejects further events',
    () async {
      final events = SurfaceEvents(0);
      final completed = events.stream.toList();
      events.update(1);
      await events.close();
      expect(await completed, [1]);
      expect(() => events.update(1), throwsStateError);
      expect(() => events.update(2), throwsStateError);
      await events.close();
    },
  );
}
