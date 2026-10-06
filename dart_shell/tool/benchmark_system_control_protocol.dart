import 'package:denial_flutter_sdk/wire.dart' show SystemControlProtocol;

// Compile and run with the pinned Dart SDK:
// dart compile exe tool/benchmark_system_control_protocol.dart -o /tmp/control-bench
// /tmp/control-bench
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/platform.dart';

int _checksum = 0;
void main() {
  for (final count in [1, 8, 64]) {
    final packet = _devices(count);
    const iterations = 100000;
    _measure(_PreviousProtocol.decodeAudioDevices, packet, 10000);
    _measure(SystemControlProtocol.decodeAudioDevices, packet, 10000);
    final before = <double>[];
    final after = <double>[];
    for (var i = 0; i < 7; i++) {
      if (i.isEven) {
        before.add(
          _measure(_PreviousProtocol.decodeAudioDevices, packet, iterations),
        );
        after.add(
          _measure(
            SystemControlProtocol.decodeAudioDevices,
            packet,
            iterations,
          ),
        );
      } else {
        after.add(
          _measure(
            SystemControlProtocol.decodeAudioDevices,
            packet,
            iterations,
          ),
        );
        before.add(
          _measure(_PreviousProtocol.decodeAudioDevices, packet, iterations),
        );
      }
    }
    before.sort();
    after.sort();
    stdout.writeln(
      '$count devices: ${before[3].toStringAsFixed(1)} -> ${after[3].toStringAsFixed(1)} ns/packet; ${(before[3] / after[3]).toStringAsFixed(2)}x',
    );
  }
  stdout.writeln('checksum=$_checksum');
}

double _measure(
  List<DenialAudioDevice>? Function(ByteData?) decode,
  ByteData packet,
  int n,
) {
  final clock = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final result = decode(packet)!;
    _checksum += result.length + result.last.description.length;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / n;
}

ByteData _devices(int count) {
  final out = BytesBuilder(copy: false)
    ..add(
      (ByteData(4)..setUint32(0, count, Endian.little)).buffer.asUint8List(),
    );
  for (var i = 0; i < count; i++) {
    final name = utf8.encode('alsa_output.pci-0000_00_1f.3.analog-stereo.$i');
    final description = utf8.encode(
      i.isEven ? 'Built-in Audio Analog Stereo' : 'Écouteurs 日本語',
    );
    final header = ByteData(6)
      ..setUint8(0, 1)
      ..setUint8(1, 1)
      ..setUint16(2, name.length, Endian.little)
      ..setUint16(4, description.length, Endian.little);
    out
      ..add(header.buffer.asUint8List())
      ..add(name)
      ..add(description);
  }
  return ByteData.sublistView(out.takeBytes());
}

// Previous decoder: a byte view per string and a copied immutable list.
abstract final class _PreviousProtocol {
  static List<DenialAudioDevice>? decodeAudioDevices(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final count = data.getUint32(0, Endian.little);
    final devices = <DenialAudioDevice>[];
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 6 > data.lengthInBytes) return null;
      final active = data.getUint8(offset) != 0;
      final available = data.getUint8(offset + 1) != 0;
      final nameLength = data.getUint16(offset + 2, Endian.little);
      final descriptionLength = data.getUint16(offset + 4, Endian.little);
      offset += 6;
      if (offset + nameLength + descriptionLength > data.lengthInBytes) {
        return null;
      }
      devices.add(
        DenialAudioDevice(
          name: _text(data, offset, nameLength),
          description: _text(data, offset + nameLength, descriptionLength),
          active: active,
          available: available,
        ),
      );
      offset += nameLength + descriptionLength;
    }
    return List<DenialAudioDevice>.unmodifiable(devices);
  }

  static String _text(ByteData data, int offset, int length) => utf8.decode(
    data.buffer.asUint8List(data.offsetInBytes + offset, length),
    allowMalformed: true,
  );
}
