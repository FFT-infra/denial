import 'dart:convert';
import 'dart:typed_data';

ByteData uiDevelopmentPacket({
  int diagnostics = 0,
  String workspace = '/home/developer/界',
  String uri = 'http://127.0.0.1:1234/token/',
  String status = 'Ready 😀',
  String error = '',
}) {
  final strings = [workspace, uri, status, error].map(utf8.encode).toList();
  final path = utf8.encode('lib/界/main.dart');
  final message = utf8.encode('A diagnostic message with Unicode 😀');
  final packet = ByteData(
    40 +
        strings.fold<int>(0, (sum, value) => sum + value.length) +
        diagnostics * (14 + path.length + message.length),
  );
  packet
    ..setUint8(0, 1)
    ..setUint8(1, 2)
    ..setUint8(2, 1)
    ..setUint8(3, 5)
    ..setUint16(4, uri.isEmpty ? 0x17f : 0x1ff, Endian.little)
    ..setUint16(6, 8765, Endian.little)
    ..setUint64(8, 123, Endian.little)
    ..setUint64(16, 456, Endian.little)
    ..setUint32(24, 789, Endian.little)
    ..setUint16(36, diagnostics, Endian.little);
  final bytes = packet.buffer.asUint8List();
  var offset = 40;
  for (var index = 0; index < strings.length; index++) {
    final value = strings[index];
    packet.setUint16(28 + index * 2, value.length, Endian.little);
    bytes.setRange(offset, offset + value.length, value);
    offset += value.length;
  }
  for (var i = 0; i < diagnostics; i++) {
    packet
      ..setUint8(offset, i % 3)
      ..setUint32(offset + 2, i + 1, Endian.little)
      ..setUint32(offset + 6, 42, Endian.little)
      ..setUint16(offset + 10, path.length, Endian.little)
      ..setUint16(offset + 12, message.length, Endian.little);
    offset += 14;
    bytes.setRange(offset, offset + path.length, path);
    offset += path.length;
    bytes.setRange(offset, offset + message.length, message);
    offset += message.length;
  }
  return packet;
}
