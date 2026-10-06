import 'package:denial_flutter_sdk/src/services/status_notifier_protocol.dart'
    show
        StatusNotifierProtocol,
        StatusNotifierUpdateDecoder,
        StatusNotifierUpdateEncoder;

// Compile with the pinned Dart SDK and run the resulting AOT executable:
// dart compile exe tool/benchmark_status_notifier.dart -o /tmp/tray-bench
// /tmp/tray-bench
import 'dart:io';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/models.dart';

int _checksum = 0;
void main() {
  for (final withIcons in [false, true]) {
    final a = List.generate(
      16,
      (id) => _item(
        '$id',
        'Title $id',
        withIcons
            ? SystemTrayIconPixmap(
                width: 64,
                height: 64,
                rgba: Uint8List(64 * 64 * 4)..fillRange(0, 64 * 64 * 4, 255),
              )
            : null,
      ),
    );
    final b = a.toList()..[0] = _item('0', 'Updated title', a.first.iconPixmap);
    final encoder = StatusNotifierUpdateEncoder();
    final decoder = StatusNotifierUpdateDecoder();
    decoder.decode(encoder.encode(a));
    List<SystemTrayItem> full(int i) => StatusNotifierProtocol.decodeItems(
      StatusNotifierProtocol.encodeItems(i.isEven ? a : b),
    );
    List<SystemTrayItem> incremental(int i) =>
        decoder.decode(encoder.encode(i.isEven ? a : b));
    final iterations = withIcons ? 1000 : 10000;
    _measure(full, 1000);
    _measure(incremental, 1000);
    final before = <double>[];
    final after = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      if (sample.isEven) {
        before.add(_measure(full, iterations));
        after.add(_measure(incremental, iterations));
      } else {
        after.add(_measure(incremental, iterations));
        before.add(_measure(full, iterations));
      }
    }
    before.sort();
    after.sort();
    stdout.writeln(
      '16 items, ${withIcons ? '64x64 icons' : 'no pixel buffers'}, one title change: ${before[3].toStringAsFixed(1)} -> ${after[3].toStringAsFixed(1)} ns/update (${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum=$_checksum');
}

double _measure(List<SystemTrayItem> Function(int) operation, int count) {
  final clock = Stopwatch()..start();
  for (var index = 0; index < count; index++) {
    final items = operation(index);
    _checksum += items.length + items.first.title.length;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}

SystemTrayItem _item(String id, String title, SystemTrayIconPixmap? icon) =>
    SystemTrayItem(
      id: id,
      source: SystemTrayItemSource.statusNotifier,
      title: title,
      status: SystemTrayStatus.active,
      iconName: 'icon-$id',
      iconThemePath: '',
      iconPixmap: icon,
      menuAvailable: true,
      primaryOpensMenu: false,
    );
