import 'package:denial_flutter_sdk/src/state/system_bar_outputs.dart';
import 'package:test/test.dart';

void main() {
  const outputs = [
    (monitorId: 7, name: 'eDP-1'),
    (monitorId: 9, name: 'HDMI-A-1'),
  ];

  test(
    'desktop entry from a scene without a panel selects the main output',
    () {
      expect(
        resolveSystemBarMonitorIds(
          outputs: outputs,
          outputNames: const [],
          currentMonitorIds: const [],
          mainMonitorId: 9,
        ),
        [9],
      );
    },
  );

  test('normal desktop startup preserves live native panel outputs', () {
    expect(
      resolveSystemBarMonitorIds(
        outputs: outputs,
        outputNames: const [],
        currentMonitorIds: const [7, 9],
        mainMonitorId: 9,
      ),
      [7, 9],
    );
  });

  test('persisted output selection overrides the previous scene', () {
    expect(
      resolveSystemBarMonitorIds(
        outputs: outputs,
        outputNames: const ['HDMI-A-1'],
        currentMonitorIds: const [7],
        mainMonitorId: 7,
      ),
      [9],
    );
  });

  test('native host order is independent of physical output order', () {
    expect(
      resolveSystemBarMonitorIds(
        outputs: outputs,
        outputNames: const [],
        currentMonitorIds: const [9, 7],
        mainMonitorId: 9,
      ),
      [9, 7],
    );
  });

  test('unplugged selected outputs fall back to a live main output', () {
    expect(
      resolveSystemBarMonitorIds(
        outputs: outputs,
        outputNames: const ['DP-2'],
        currentMonitorIds: const [13],
        mainMonitorId: 9,
      ),
      [9],
    );
  });

  test('a stale main output falls back to the first live output', () {
    expect(
      resolveSystemBarMonitorIds(
        outputs: outputs,
        outputNames: const [],
        currentMonitorIds: const [13],
        mainMonitorId: 13,
      ),
      [7],
    );
    expect(
      resolveSystemBarMonitorIds(
        outputs: const [],
        outputNames: const [],
        currentMonitorIds: const [13],
        mainMonitorId: 13,
      ),
      isEmpty,
    );
  });
}
