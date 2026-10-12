import 'dart:async';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_taskbar/denial_taskbar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop surfaces have a default output without native reservation', () {
    final layout = _layout().copyWithSystemBar(
      side: SystemBarSide.hidden,
      monitorIds: const [],
      thickness: 0,
      windowPadding: 0,
    );
    final output = layout.outputs.single;
    expect(layout.hostsSystemBar(output), isFalse);
    expect(layout.hostsDefaultShellSurface(output), isTrue);
    final environment = ShellSurfaceEnvironment(
      output: output,
      workArea: layout.workAreaOf(output),
      isMainOutput: true,
      workspaceId: 1,
      fullscreen: false,
      overview: false,
      desktopVisible: true,
      wallpaperSelectorVisible: false,
      locked: false,
      settings: const ShellSettings(),
      defaultOutputSelected: layout.hostsDefaultShellSurface(output),
    );
    expect(const TaskbarPlugin().place(environment), isNotNull);
    // Selecting visual surfaces does not change native mobile window policy.
    expect(layout.systemBarSide, SystemBarSide.hidden);
    expect(layout.workAreaOf(output), output.logicalRect);
  });

  test('default shell surfaces preserve configured output selection', () {
    final layout = _layout();
    final selected = layout.outputs.single;
    const other = DisplayOutput(
      monitorId: 9,
      name: 'HDMI-A-1',
      logicalRect: Rect.fromLTWH(1920, 0, 1920, 1080),
      pixelSize: Size(1920, 1080),
      scale: 1,
      refreshRate: 60,
    );
    expect(layout.hostsDefaultShellSurface(selected), isTrue);
    expect(layout.hostsDefaultShellSurface(other), isFalse);
    final hidden = layout.copyWithSystemBar(
      side: SystemBarSide.hidden,
      monitorIds: const [],
    );
    expect(hidden.hostsDefaultShellSurface(other), isFalse);
  });

  test(
    'mobile startup restores the full desktop work area on repeated switches',
    () async {
      final mobile = _layout().copyWithSystemBar(
        side: SystemBarSide.hidden,
        monitorIds: const [],
        thickness: 0,
        windowPadding: 0,
      );
      for (final configureBeforeLoad in [false, true]) {
        final bridge = _FakeDenialBridge(mobile);
        final container = ProviderContainer.test(
          overrides: [denialBridgeProvider.overrideWithValue(bridge)],
        );
        try {
          final controller = container.read(displayLayoutProvider.notifier);
          final reservation = const TaskbarWorkArea().reserve(
            const ShellSettings().layout,
          )!;
          if (!configureBeforeLoad) await controller.ensureLoaded();
          void enterDesktop() => controller.applyShellConfiguration(
            side: reservation.edge,
            outputNames: reservation.outputNames,
            systemBarThickness: reservation.thickness,
            maximizePadding: const ShellSettings().layout.maximizePadding,
          );

          enterDesktop();
          await controller.ensureLoaded();
          expect(bridge.requests, hasLength(1));
          expect(bridge.requests.last.side, SystemBarSide.bottom);
          expect(bridge.requests.last.monitorIds, [7]);
          expect(bridge.requests.last.systemBarThickness, 60);
          expect(bridge.requests.last.maximizePadding, 8);
          var layout = container.read(displayLayoutProvider)!;
          expect(
            layout.workAreaOf(layout.outputs.single),
            const Rect.fromLTWH(8, 8, 1904, 1012),
          );

          controller.applyShellConfiguration(
            side: SystemBarSide.hidden,
            outputNames: const [],
            systemBarThickness: 0,
            maximizePadding: 0,
          );
          expect(bridge.requests, hasLength(2));
          expect(bridge.requests.last.side, SystemBarSide.hidden);
          expect(bridge.requests.last.monitorIds, isEmpty);
          expect(bridge.requests.last.systemBarThickness, 0);
          expect(bridge.requests.last.maximizePadding, 0);
          layout = container.read(displayLayoutProvider)!;
          expect(
            layout.workAreaOf(layout.outputs.single),
            layout.outputs.single.logicalRect,
          );

          enterDesktop();
          expect(bridge.requests, hasLength(3));
          expect(bridge.requests.last.monitorIds, [7]);
          expect(bridge.requests.last.maximizePadding, 8);
          // A late topology packet from the mobile scene must also be repaired.
          bridge.emit(mobile);
          expect(bridge.requests, hasLength(4));
          layout = container.read(displayLayoutProvider)!;
          expect(
            layout.workAreaOf(layout.outputs.single),
            const Rect.fromLTWH(8, 8, 1904, 1012),
          );
        } finally {
          container.dispose();
          bridge.dispose();
          await bridge.close();
        }
      }
    },
  );

  test('desktop without a panel still publishes its window padding', () async {
    final bridge = _FakeDenialBridge(_layout());
    final container = ProviderContainer.test(
      overrides: [denialBridgeProvider.overrideWithValue(bridge)],
    );
    try {
      final controller = container.read(displayLayoutProvider.notifier);
      await controller.ensureLoaded();
      controller.applyShellConfiguration(
        side: SystemBarSide.hidden,
        outputNames: const [],
        systemBarThickness: 0,
        maximizePadding: 12,
      );
      expect(bridge.requests, hasLength(1));
      expect(bridge.requests.single.side, SystemBarSide.hidden);
      expect(bridge.requests.single.monitorIds, isEmpty);
      expect(bridge.requests.single.maximizePadding, 12);
    } finally {
      container.dispose();
      bridge.dispose();
      await bridge.close();
    }
  });

  test(
    'shell work-area metrics publish even when placement follows native',
    () async {
      final bridge = _FakeDenialBridge(_layout());
      final container = ProviderContainer.test(
        overrides: [denialBridgeProvider.overrideWithValue(bridge)],
      );

      try {
        final controller = container.read(displayLayoutProvider.notifier);
        expect(await controller.ensureLoaded(), isNotNull);

        controller.applyShellConfiguration(
          side: null,
          outputNames: const <String>[],
          systemBarThickness: 54,
          maximizePadding: 17,
        );
        await Future<void>.delayed(Duration.zero);

        expect(bridge.requests, hasLength(1));
        expect(bridge.requests.single.side, SystemBarSide.top);
        expect(bridge.requests.single.monitorIds, <int>[7]);
        expect(bridge.requests.single.systemBarThickness, 54);
        expect(bridge.requests.single.maximizePadding, 17);
      } finally {
        container.dispose();
        bridge.dispose();
        await bridge.close();
      }
    },
  );
}

DisplayLayout _layout() {
  return const DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: Size(1920, 1080),
    pixelSize: Size(1920, 1080),
    engineScale: 1,
    tickerMonitorId: 7,
    systemBarMonitorId: 7,
    systemBarMonitorIds: <int>[7],
    systemBarSide: SystemBarSide.top,
    systemBarThickness: 32,
    maximizePadding: 10,
    outputs: <DisplayOutput>[
      DisplayOutput(
        monitorId: 7,
        name: 'eDP-1',
        logicalRect: Rect.fromLTWH(0, 0, 1920, 1080),
        pixelSize: Size(1920, 1080),
        scale: 1,
        refreshRate: 60,
      ),
    ],
  );
}

class _FakeDenialBridge extends DenialBridge {
  _FakeDenialBridge(this.layout);

  DisplayLayout layout;
  final StreamController<DisplayLayout> _layouts =
      StreamController<DisplayLayout>.broadcast(sync: true);
  final List<
    ({
      SystemBarSide side,
      List<int> monitorIds,
      double systemBarThickness,
      double maximizePadding,
    })
  >
  requests = [];

  @override
  Stream<DisplayLayout> get displayLayouts => _layouts.stream;

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;

  @override
  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
    required double systemBarThickness,
    required double maximizePadding,
  }) async {
    requests.add((
      side: side,
      monitorIds: List<int>.of(monitorIds),
      systemBarThickness: systemBarThickness,
      maximizePadding: maximizePadding,
    ));
    layout = layout.copyWithSystemBar(
      side: side,
      monitorIds: monitorIds,
      thickness: systemBarThickness,
      windowPadding: maximizePadding,
    );
    return layout;
  }

  void emit(DisplayLayout value) {
    layout = value;
    _layouts.add(value);
  }

  Future<void> close() => _layouts.close();
}
