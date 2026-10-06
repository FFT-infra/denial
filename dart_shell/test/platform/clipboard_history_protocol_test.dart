import 'package:denial_flutter_sdk/wire.dart' show ClipboardHistoryProtocol;

import 'dart:convert';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/models.dart';
import 'package:test/test.dart';

void main() {
  test('all requests match the native version-one wire format', () {
    const id = 0x1122334455667788;
    const idBytes = [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11];
    final cases = <(ByteData, int, List<int>)>[
      (ClipboardHistoryProtocol.snapshotRequest('é'), 0, [2, 0, 0xc3, 0xa9]),
      (ClipboardHistoryProtocol.snapshotRequest(''), 0, [0, 0]),
      (
        ClipboardHistoryProtocol.readRequest(id, 'text/plain'),
        1,
        [...idBytes, 10, 0, ...ascii.encode('text/plain')],
      ),
      (ClipboardHistoryProtocol.activateRequest(id), 2, idBytes),
      (
        ClipboardHistoryProtocol.setPinnedRequest(id, pinned: true),
        3,
        [...idBytes, 1],
      ),
      (
        ClipboardHistoryProtocol.setPinnedRequest(id, pinned: false),
        3,
        [...idBytes, 0],
      ),
      (ClipboardHistoryProtocol.deleteRequest(id), 4, idBytes),
      (ClipboardHistoryProtocol.clearRequest(), 5, []),
      (ClipboardHistoryProtocol.setPausedRequest(paused: true), 6, [1]),
      (ClipboardHistoryProtocol.setPausedRequest(paused: false), 6, [0]),
      (ClipboardHistoryProtocol.startDragRequest(id), 7, idBytes),
    ];
    for (final (packet, command, body) in cases) {
      expect(Uint8List.sublistView(packet), [
        68,
        67,
        76,
        80,
        1,
        0,
        command,
        0,
        ...body,
      ]);
    }
  });

  test('request limits count UTF-8 bytes and reject NUL and invalid IDs', () {
    expect(
      ClipboardHistoryProtocol.snapshotRequest('é' * 128).lengthInBytes,
      266,
    );
    expect(
      ClipboardHistoryProtocol.readRequest(1, 'a' * 256).lengthInBytes,
      274,
    );
    for (final query in ['é' * 129, '\u0000']) {
      expect(
        () => ClipboardHistoryProtocol.snapshotRequest(query),
        _clipboardError,
      );
    }
    for (final mime in ['', 'a' * 257, 'text/\u0000plain']) {
      expect(
        () => ClipboardHistoryProtocol.readRequest(1, mime),
        _clipboardError,
      );
    }
    for (final id in [0, -1]) {
      for (final operation in [
        ClipboardHistoryProtocol.activateRequest,
        ClipboardHistoryProtocol.deleteRequest,
        ClipboardHistoryProtocol.startDragRequest,
        (int id) => ClipboardHistoryProtocol.readRequest(id, 'text/plain'),
        (int id) => ClipboardHistoryProtocol.setPinnedRequest(id, pinned: true),
      ]) {
        expect(() => operation(id), _clipboardError);
      }
    }
  });

  test('snapshot reads offset views and owns immutable decoded values', () {
    final source = _snapshot();
    final buffer = Uint8List(source.lengthInBytes + 10)
      ..setRange(3, 3 + source.lengthInBytes, Uint8List.sublistView(source));
    final snapshot = ClipboardHistoryProtocol.decodeSnapshot(
      ByteData.sublistView(buffer, 3, 3 + source.lengthInBytes),
    );
    buffer.fillRange(0, buffer.length, 0);
    expect(
      (
        snapshot.revision,
        snapshot.totalBytes,
        snapshot.activeId,
        snapshot.paused,
        snapshot.locked,
      ),
      (99, 200, 1, true, false),
    );
    expect(snapshot.entries, hasLength(2));
    final entry = snapshot.entries.first;
    expect(
      (entry.id, entry.byteLength, entry.width, entry.height),
      (1, 100, 1920, 1080),
    );
    expect(
      entry.capturedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    expect(
      (entry.origin, entry.kind, entry.pinned, entry.active),
      (
        ClipboardHistoryOrigin.flutter,
        ClipboardHistoryContentKind.image,
        true,
        true,
      ),
    );
    expect(
      (entry.preview, entry.sourceAppId, entry.sourceTitle),
      ('café 日本語', 'app.id', 'Window title'),
    );
    expect(entry.mimeTypes, ['text/plain', 'image/png']);
    expect(() => snapshot.entries.clear(), throwsUnsupportedError);
    expect(() => entry.mimeTypes[0] = 'changed', throwsUnsupportedError);
    expect(snapshot.entries.last.id, 2);
  });

  test('data responses copy payloads and respect offset views', () {
    final source = _data();
    final buffer = Uint8List(source.lengthInBytes + 11)
      ..setRange(5, 5 + source.lengthInBytes, Uint8List.sublistView(source));
    final data = ClipboardHistoryProtocol.decodeData(
      ByteData.sublistView(buffer, 5, 5 + source.lengthInBytes),
    );
    buffer.fillRange(0, buffer.length, 0);
    expect((data.itemId, data.mimeType), (7, 'image/png'));
    expect(data.bytes, [0, 255, 128, 1]);
  });

  test('ack revision preserves all supported integer bits', () {
    final packet = _Writer(0)..u64(0x7122334455667788);
    expect(
      ClipboardHistoryProtocol.decodeAck(packet.finish()),
      0x7122334455667788,
    );
  });

  test('all truncations and trailing bytes are rejected', () {
    final ack = (_Writer(0)..u64(99)).finish();
    final cases = <(ByteData, Object Function(ByteData))>[
      (ack, ClipboardHistoryProtocol.decodeAck),
      (_snapshot(), ClipboardHistoryProtocol.decodeSnapshot),
      (_data(), ClipboardHistoryProtocol.decodeData),
    ];
    for (final (packet, decode) in cases) {
      for (var length = 0; length < packet.lengthInBytes; length++) {
        expect(
          () => decode(ByteData.sublistView(packet, 0, length)),
          throwsA(isA<ClipboardHistoryException>()),
          reason: 'length $length of ${packet.lengthInBytes}',
        );
      }
      final trailing = Uint8List(packet.lengthInBytes + 1)
        ..setRange(0, packet.lengthInBytes, Uint8List.sublistView(packet));
      expect(() => decode(ByteData.sublistView(trailing)), _clipboardError);
    }
  });

  test('wrong envelope, response kind and status are rejected', () {
    for (final (offset, value) in [(0, 0), (4, 2), (6, 2), (7, 1)]) {
      final packet = (_Writer(0)..u64(99)).finish()..setUint8(offset, value);
      expect(() => ClipboardHistoryProtocol.decodeAck(packet), _clipboardError);
    }
  });

  test('native errors preserve their status and UTF-8 message', () {
    final packet = (_Writer(255, status: 4)..text('Trop long 日本語')).finish();
    for (final decode in <Object Function(ByteData)>[
      ClipboardHistoryProtocol.decodeAck,
      ClipboardHistoryProtocol.decodeData,
      ClipboardHistoryProtocol.decodeSnapshot,
    ]) {
      expect(
        () => decode(packet),
        throwsA(
          isA<ClipboardHistoryException>()
              .having((e) => e.code, 'code', 4)
              .having((e) => e.message, 'message', 'Trop long 日本語'),
        ),
      );
    }
  });

  test('snapshot bounds, flags, enums, IDs and MIME counts are validated', () {
    expect(
      ClipboardHistoryProtocol.decodeSnapshot(_snapshot(count: 100)).entries,
      hasLength(100),
    );
    expect(
      () => ClipboardHistoryProtocol.decodeSnapshot(_snapshot(count: 101)),
      _clipboardError,
    );
    for (final (offset, value) in [
      (32, 4),
      (35, 0),
      (67, 3),
      (68, 2),
      (69, 4),
      (70, 0),
      (70, 5),
    ]) {
      final packet = _snapshot()..setUint8(offset, value);
      expect(
        () => ClipboardHistoryProtocol.decodeSnapshot(packet),
        _clipboardError,
        reason: 'offset $offset value $value',
      );
    }
    final longPreview = _snapshot()..setUint16(71, 1025, Endian.little);
    expect(
      () => ClipboardHistoryProtocol.decodeSnapshot(longPreview),
      _clipboardError,
    );
  });

  test('locked snapshots must redact entries, byte totals and active IDs', () {
    final empty =
        (_Writer(1)
              ..u64(9)
              ..u64(0)
              ..u64(0)
              ..u8(2)
              ..u16(0))
            .finish();
    expect(ClipboardHistoryProtocol.decodeSnapshot(empty).locked, isTrue);
    for (final offset in [16, 24]) {
      final packet = ByteData.sublistView(
        Uint8List.fromList(Uint8List.sublistView(empty)),
      )..setUint64(offset, 1, Endian.little);
      expect(
        () => ClipboardHistoryProtocol.decodeSnapshot(packet),
        _clipboardError,
      );
    }
    expect(
      () =>
          ClipboardHistoryProtocol.decodeSnapshot(_snapshot()..setUint8(32, 2)),
      _clipboardError,
    );
  });

  test('malformed UTF-8 and embedded NUL in decoded strings are rejected', () {
    final invalidUtf8 =
        (_Writer(255)
              ..u16(1)
              ..raw([255]))
            .finish();
    expect(
      () => ClipboardHistoryProtocol.decodeAck(invalidUtf8),
      throwsFormatException,
    );
    final nul = (_Writer(255)..text('bad\u0000message')).finish();
    expect(() => ClipboardHistoryProtocol.decodeAck(nul), _clipboardError);
  });

  test('data byte counts enforce native limits before copying', () {
    for (final length in [5, 16 * 1024 * 1024 + 1]) {
      final packet = _data()..setUint64(27, length, Endian.little);
      expect(
        () => ClipboardHistoryProtocol.decodeData(packet),
        _clipboardError,
      );
    }
  });
}

final _clipboardError = throwsA(isA<ClipboardHistoryException>());

ByteData _snapshot({int count = 2}) {
  final writer = _Writer(1)
    ..u64(99)
    ..u64(count * 100)
    ..u64(1)
    ..u8(1)
    ..u16(count);
  for (var index = 0; index < count; index++) {
    writer
      ..u64(index + 1)
      ..u64(1700000000000 + index)
      ..u64(100)
      ..u32(1920)
      ..u32(1080)
      ..u8(2)
      ..u8(1)
      ..u8(3)
      ..u8(2)
      ..text('café 日本語')
      ..text('app.id')
      ..text('Window title')
      ..text('text/plain')
      ..text('image/png');
  }
  return writer.finish();
}

ByteData _data() =>
    (_Writer(2)
          ..u64(7)
          ..text('image/png')
          ..u64(4)
          ..raw([0, 255, 128, 1]))
        .finish();

// Fixture encoder mirrors the documented native wire fields, independent of
// the production request builder and response reader.
class _Writer {
  _Writer(int kind, {int status = 0}) {
    raw([68, 67, 76, 83, 1, 0, kind, status]);
  }
  final _bytes = BytesBuilder(copy: false);
  void raw(List<int> bytes) => _bytes.add(bytes);
  void u8(int value) => raw([value]);
  void u16(int value) => raw(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(int value) => raw(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => raw(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void text(String value) {
    final bytes = utf8.encode(value);
    u16(bytes.length);
    raw(bytes);
  }

  ByteData finish() => ByteData.sublistView(_bytes.takeBytes());
}
