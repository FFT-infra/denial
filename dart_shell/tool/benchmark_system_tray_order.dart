import 'package:denial_flutter_sdk/src/services/system_tray_order.dart'
    show combineSystemTrayItems, compareSystemTrayItems, orderSystemTrayItems;

// Compile with the pinned SDK, then run the resulting AOT executable:
// dart compile exe tool/benchmark_system_tray_order.dart -o /tmp/tray-order-bench
// /tmp/tray-order-bench
import 'dart:io';

import 'package:denial_flutter_sdk/models.dart';

int _checksum = 0;
void main() {
  for (final count in [16, 64]) {
    for (final legacyCount in [0, 1, 4]) {
      final native = orderSystemTrayItems(
        List.generate(count, (id) => _item(id, 'App $id')),
      );
      final updated = orderSystemTrayItems([
        _item(0, 'Updated'),
        ...native.skip(1),
      ]);
      final legacy = List.generate(
        legacyCount,
        (id) => _item(count + id, 'Legacy $id'),
      );
      List<SystemTrayItem> before(int i) {
        final items = [...(i.isEven ? native : updated), ...legacy]
          ..sort(compareSystemTrayItems);
        return List<SystemTrayItem>.unmodifiable(items);
      }

      List<SystemTrayItem> after(int i) =>
          combineSystemTrayItems(i.isEven ? native : updated, legacy);
      const iterations = 10000;
      _measure(before, 1000);
      _measure(after, 1000);
      final oldSamples = <double>[];
      final newSamples = <double>[];
      for (var sample = 0; sample < 7; sample++) {
        if (sample.isEven) {
          oldSamples.add(_measure(before, iterations));
          newSamples.add(_measure(after, iterations));
        } else {
          newSamples.add(_measure(after, iterations));
          oldSamples.add(_measure(before, iterations));
        }
      }
      oldSamples.sort();
      newSamples.sort();
      stdout.writeln(
        '$count native + $legacyCount legacy: ${oldSamples[3].toStringAsFixed(1)} -> ${newSamples[3].toStringAsFixed(1)} ns/update',
      );
    }
  }
  stdout.writeln('checksum=$_checksum');
}

double _measure(List<SystemTrayItem> Function(int) operation, int count) {
  final clock = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    final result = operation(i);
    _checksum += result.length + result.last.title.length;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}

SystemTrayItem _item(int id, String title) => SystemTrayItem(
  id: '$id',
  source: SystemTrayItemSource.statusNotifier,
  title: title,
  status: SystemTrayStatus.active,
  iconName: '',
  iconThemePath: '',
  iconPixmap: null,
  menuAvailable: false,
  primaryOpensMenu: false,
);
