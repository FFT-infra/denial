import 'package:denial_flutter_sdk/wire.dart' show SystemControlProtocol;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  test('audio state preserves optional legacy fields and percent clamping', () {
    expect(SystemControlProtocol.decodeAudioState(null), isNull);
    expect(SystemControlProtocol.decodeAudioState(ByteData(0)), isNull);
    final packet = ByteData(7)
      ..setUint8(0, 255)
      ..setUint32(1, 0x12345678, Endian.little)
      ..setUint8(5, 1)
      ..setUint8(6, 1);
    for (var length = 1; length <= 7; length++) {
      final state = SystemControlProtocol.decodeAudioState(
        ByteData.sublistView(packet, 0, length),
      )!;
      expect(state.level, 1);
      expect(state.requestSerial, length >= 5 ? 0x12345678 : 0);
      expect(state.muted, length >= 6);
      expect(state.limitReached, length >= 7);
    }
  });

  test('stream packets decode UTF-8 and retain immutable owned results', () {
    final bytes = _streams();
    final backing = Uint8List(bytes.length + 11)
      ..setRange(3, 3 + bytes.length, bytes);
    final streams = SystemControlProtocol.decodeAudioStreams(
      ByteData.sublistView(backing, 3, 3 + bytes.length),
    )!;
    backing.fillRange(0, backing.length, 0);
    expect(streams.map((s) => (s.id, s.name, s.level, s.muted)), [
      (7, 'café 日本語', 0.8, true),
      (9, '', 1.0, false),
    ]);
    expect(() => streams.clear(), throwsUnsupportedError);
  });

  test('device packets decode both strings from offset views', () {
    final bytes = _devices();
    final backing = Uint8List(bytes.length + 9)
      ..setRange(5, 5 + bytes.length, bytes);
    final devices = SystemControlProtocol.decodeAudioDevices(
      ByteData.sublistView(backing, 5, 5 + bytes.length),
    )!;
    backing.fillRange(0, backing.length, 0);
    expect(devices.map((d) => (d.name, d.description, d.active, d.available)), [
      ('speaker', 'Écouteurs 日本語', true, true),
      ('headset', '', false, true),
    ]);
    expect(() => devices.clear(), throwsUnsupportedError);
  });

  test('all truncations of multi-entry packets reject the entire snapshot', () {
    final streams = _streams();
    for (var length = 0; length < streams.length; length++) {
      expect(
        SystemControlProtocol.decodeAudioStreams(
          ByteData.sublistView(streams, 0, length),
        ),
        isNull,
        reason: 'stream length $length',
      );
    }
    final devices = _devices();
    for (var length = 0; length < devices.length; length++) {
      expect(
        SystemControlProtocol.decodeAudioDevices(
          ByteData.sublistView(devices, 0, length),
        ),
        isNull,
        reason: 'device length $length',
      );
    }
  });

  test('empty snapshots and trailing extensions remain compatible', () {
    expect(SystemControlProtocol.decodeAudioStreams(ByteData(4)), isEmpty);
    expect(SystemControlProtocol.decodeAudioDevices(ByteData(4)), isEmpty);
    expect(
      SystemControlProtocol.decodeAudioStreams(
        ByteData.sublistView(Uint8List.fromList([..._streams(), 99, 88])),
      ),
      hasLength(2),
    );
    expect(
      SystemControlProtocol.decodeAudioDevices(
        ByteData.sublistView(Uint8List.fromList([..._devices(), 99, 88])),
      ),
      hasLength(2),
    );
  });

  test('impossible entry counts and string lengths are rejected', () {
    final impossible = ByteData(100)..setUint32(0, 0xffffffff, Endian.little);
    expect(SystemControlProtocol.decodeAudioStreams(impossible), isNull);
    expect(SystemControlProtocol.decodeAudioDevices(impossible), isNull);
    final streams = ByteData.sublistView(_streams())
      ..setUint16(10, 65535, Endian.little);
    expect(SystemControlProtocol.decodeAudioStreams(streams), isNull);
    final devices = ByteData.sublistView(_devices())
      ..setUint16(8, 65535, Endian.little);
    expect(SystemControlProtocol.decodeAudioDevices(devices), isNull);
  });

  test('malformed UTF-8 keeps replacement semantics', () {
    final bytes = _streams()..[12] = 0xff;
    final streams = SystemControlProtocol.decodeAudioStreams(
      ByteData.sublistView(bytes),
    )!;
    expect(streams.first.name, startsWith('\uFFFD'));
  });

  test('brightness and dimming retain their monitor-ID boundaries', () {
    final data = ByteData(10)
      ..setUint8(8, 255)
      ..setUint8(9, 1);
    expect(SystemControlProtocol.decodeBrightness(data), (
      monitorId: 0,
      level: 1.0,
    ));
    expect(SystemControlProtocol.decodeSoftwareDimming(data), isNull);
    data.setInt64(0, 0x100000007, Endian.little);
    expect(SystemControlProtocol.decodeBrightness(data), (
      monitorId: 0x100000007,
      level: 1.0,
    ));
    expect(SystemControlProtocol.decodeSoftwareDimming(data), (
      monitorId: 0x100000007,
      level: 1.0,
      supported: true,
    ));
    data.setInt64(0, -1, Endian.little);
    expect(SystemControlProtocol.decodeBrightness(data), isNull);
    expect(SystemControlProtocol.decodeSoftwareDimming(data), isNull);
    expect(SystemControlProtocol.decodeBrightness(ByteData(8)), isNull);
    expect(SystemControlProtocol.decodeSoftwareDimming(ByteData(9)), isNull);
  });

  test('arbitrary bounded byte sequences do not escape parser bounds', () {
    final random = Random(51);
    for (var iteration = 0; iteration < 3000; iteration++) {
      final bytes = Uint8List.fromList(
        List.generate(random.nextInt(128), (_) => random.nextInt(256)),
      );
      final data = ByteData.sublistView(bytes);
      SystemControlProtocol.decodeAudioState(data);
      SystemControlProtocol.decodeAudioStreams(data);
      SystemControlProtocol.decodeAudioDevices(data);
      SystemControlProtocol.decodeBrightness(data);
      SystemControlProtocol.decodeSoftwareDimming(data);
    }
  });
}

Uint8List _streams() {
  final result = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, 2, Endian.little)).buffer.asUint8List());
  for (final (id, name, level, muted) in [
    (7, 'café 日本語', 80, 1),
    (9, '', 255, 0),
  ]) {
    final text = utf8.encode(name);
    final header = ByteData(8)
      ..setUint32(0, id, Endian.little)
      ..setUint8(4, level)
      ..setUint8(5, muted)
      ..setUint16(6, text.length, Endian.little);
    result
      ..add(header.buffer.asUint8List())
      ..add(text);
  }
  return result.takeBytes();
}

Uint8List _devices() {
  final result = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, 2, Endian.little)).buffer.asUint8List());
  for (final (name, description, active) in [
    ('speaker', 'Écouteurs 日本語', 1),
    ('headset', '', 0),
  ]) {
    final a = utf8.encode(name), b = utf8.encode(description);
    final header = ByteData(6)
      ..setUint8(0, active)
      ..setUint8(1, 1)
      ..setUint16(2, a.length, Endian.little)
      ..setUint16(4, b.length, Endian.little);
    result
      ..add(header.buffer.asUint8List())
      ..add(a)
      ..add(b);
  }
  return result.takeBytes();
}
