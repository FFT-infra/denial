import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../models/clipboard_history.dart';

const int _requestMagic = 0x504c4344; // DCLP, little endian
const int _responseMagic = 0x534c4344; // DCLS, little endian
const int _protocolVersion = 1;

const int _snapshotCommand = 0;
const int _readCommand = 1;
const int _activateCommand = 2;
const int _setPinnedCommand = 3;
const int _deleteCommand = 4;
const int _clearCommand = 5;
const int _setPausedCommand = 6;
const int _startDragCommand = 7;

const int _ackResponse = 0;
const int _snapshotResponse = 1;
const int _dataResponse = 2;
const int _errorResponse = 0xff;

const int _snapshotPaused = 1 << 0;
const int _snapshotLocked = 1 << 1;
const int _entryPinned = 1 << 0;
const int _entryActive = 1 << 1;

const int _maxRequestBytes = 4096;
const int _maxQueryBytes = 256;
const int _maxMimeBytes = 256;
const int _maxHistoryItems = 100;
const int _maxRepresentations = 4;
const int _maxPreviewBytes = 1024;
const int _maxSourceAppIdBytes = 512;
const int _maxSourceTitleBytes = 1024;
const int _maxDataBytes = 16 * 1024 * 1024;

/// Binary clipboard requests and responses, independent of platform transport.
abstract final class ClipboardHistoryProtocol {
  static ByteData snapshotRequest(String query) {
    final encoded = utf8.encode(query);
    if (encoded.length > _maxQueryBytes || encoded.contains(0)) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard search query is invalid or too long',
      );
    }
    return _stringRequest(_snapshotCommand, 8, encoded);
  }

  static ByteData readRequest(int itemId, String mimeType) {
    _validateItemId(itemId);
    final encoded = utf8.encode(mimeType);
    if (encoded.isEmpty ||
        encoded.length > _maxMimeBytes ||
        encoded.contains(0)) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard MIME type is invalid',
      );
    }
    return _stringRequest(_readCommand, 16, encoded)
      ..setUint64(8, itemId, Endian.little);
  }

  static ByteData activateRequest(int itemId) =>
      _itemRequest(_activateCommand, itemId);
  static ByteData deleteRequest(int itemId) =>
      _itemRequest(_deleteCommand, itemId);
  static ByteData startDragRequest(int itemId) =>
      _itemRequest(_startDragCommand, itemId);
  static ByteData clearRequest() => _request(_clearCommand, 8);

  static ByteData setPinnedRequest(int itemId, {required bool pinned}) =>
      _itemRequest(_setPinnedCommand, itemId, length: 17)
        ..setUint8(16, pinned ? 1 : 0);

  static ByteData setPausedRequest({required bool paused}) =>
      _request(_setPausedCommand, 9)..setUint8(8, paused ? 1 : 0);

  static ByteData _itemRequest(int command, int itemId, {int length = 16}) {
    _validateItemId(itemId);
    return _request(command, length)..setUint64(8, itemId, Endian.little);
  }

  static ByteData _stringRequest(int command, int offset, Uint8List encoded) {
    final packet = _request(command, offset + 2 + encoded.length)
      ..setUint16(offset, encoded.length, Endian.little);
    Uint8List.sublistView(packet)
        .setRange(offset + 2, packet.lengthInBytes, encoded);
    return packet;
  }

  static ByteData _request(int command, int length) {
    if (length > _maxRequestBytes) {
      throw const ClipboardHistoryException(
        4,
        'Clipboard request exceeds its native limit',
      );
    }
    return ByteData(length)
      ..setUint32(0, _requestMagic, Endian.little)
      ..setUint16(4, _protocolVersion, Endian.little)
      ..setUint8(6, command);
  }

  static int decodeAck(ByteData packet) {
    final reader = _response(packet, _ackResponse);
    final revision = reader.uint64();
    reader.expectEnd();
    return revision;
  }

  static ClipboardHistoryData decodeData(ByteData packet) {
    final reader = _response(packet, _dataResponse);
    final itemId = reader.nonzeroUint64();
    final mimeType = reader.string16(_maxMimeBytes);
    final length = reader.uint64();
    if (length > _maxDataBytes || length > reader.remaining) {
      throw const ClipboardHistoryException(
        4,
        'Native clipboard data exceeds its limit',
      );
    }
    final bytes = reader.bytes(length);
    reader.expectEnd();
    return ClipboardHistoryData(
      itemId: itemId,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  static ClipboardHistorySnapshot decodeSnapshot(ByteData packet) {
    final reader = _response(packet, _snapshotResponse);
    final revision = reader.uint64();
    final totalBytes = reader.uint64();
    final rawActiveId = reader.uint64();
    final flags = reader.uint8();
    if (flags & ~(_snapshotPaused | _snapshotLocked) != 0) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard snapshot has unknown flags',
      );
    }
    final count = reader.uint16();
    if (count > _maxHistoryItems) {
      throw const ClipboardHistoryException(
        4,
        'Native clipboard snapshot has too many entries',
      );
    }
    final entries = <ClipboardHistoryEntry>[];
    for (var index = 0; index < count; index += 1) {
      final id = reader.nonzeroUint64();
      final capturedUnixMs = reader.uint64();
      final byteLength = reader.uint64();
      final width = reader.uint32();
      final height = reader.uint32();
      final originIndex = reader.uint8();
      final kindIndex = reader.uint8();
      final entryFlags = reader.uint8();
      final mimeCount = reader.uint8();
      if (originIndex >= ClipboardHistoryOrigin.values.length ||
          kindIndex >= ClipboardHistoryContentKind.values.length ||
          entryFlags & ~(_entryPinned | _entryActive) != 0 ||
          mimeCount == 0 ||
          mimeCount > _maxRepresentations) {
        throw const ClipboardHistoryException(
          1,
          'Native clipboard entry metadata is invalid',
        );
      }
      final preview = reader.string16(_maxPreviewBytes);
      final sourceAppId = reader.string16(_maxSourceAppIdBytes);
      final sourceTitle = reader.string16(_maxSourceTitleBytes);
      final mimeTypes = List<String>.generate(
        mimeCount,
        (_) => reader.string16(_maxMimeBytes),
        growable: false,
      );
      entries.add(
        ClipboardHistoryEntry(
          id: id,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(
            capturedUnixMs,
            isUtc: true,
          ),
          byteLength: byteLength,
          width: width,
          height: height,
          origin: ClipboardHistoryOrigin.values[originIndex],
          kind: ClipboardHistoryContentKind.values[kindIndex],
          pinned: entryFlags & _entryPinned != 0,
          active: entryFlags & _entryActive != 0,
          preview: preview,
          sourceAppId: sourceAppId,
          sourceTitle: sourceTitle,
          mimeTypes: UnmodifiableListView(mimeTypes),
        ),
      );
    }
    reader.expectEnd();
    final locked = flags & _snapshotLocked != 0;
    if (locked && (entries.isNotEmpty || totalBytes != 0 || rawActiveId != 0)) {
      throw const ClipboardHistoryException(
        1,
        'Locked clipboard snapshot was not redacted',
      );
    }
    return ClipboardHistorySnapshot(
      revision: revision,
      totalBytes: totalBytes,
      activeId: rawActiveId == 0 ? null : rawActiveId,
      paused: flags & _snapshotPaused != 0,
      locked: locked,
      entries: UnmodifiableListView(entries),
    );
  }
}

_PacketReader _response(ByteData packet, int expectedKind) {
  final reader = _PacketReader(packet);
  if (!reader.consumeMagic(_responseMagic) ||
      reader.uint16() != _protocolVersion) {
    throw const ClipboardHistoryException(
      1,
      'Native clipboard response has an invalid envelope',
    );
  }
  final kind = reader.uint8();
  final status = reader.uint8();
  if (kind == _errorResponse) {
    final message = reader.string16(1024);
    reader.expectEnd();
    throw ClipboardHistoryException(status, message);
  }
  if (status != 0 || kind != expectedKind) {
    throw const ClipboardHistoryException(
      1,
      'Native clipboard response has an unexpected type',
    );
  }
  return reader;
}

void _validateItemId(int itemId) {
  if (itemId <= 0) {
    throw const ClipboardHistoryException(
      1,
      'Clipboard item ID must be positive',
    );
  }
}

class _PacketReader {
  _PacketReader(this._data) : _bytes = Uint8List.sublistView(_data);

  final ByteData _data;

  final Uint8List _bytes;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  bool consumeMagic(int expected) {
    if (remaining < 4 || _data.getUint32(_offset, Endian.little) != expected) {
      return false;
    }
    _offset += 4;
    return true;
  }

  int uint8() {
    _require(1);
    return _bytes[_offset++];
  }

  int uint16() {
    _require(2);
    final value = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  int uint32() {
    _require(4);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int uint64() {
    _require(8);
    final value = _data.getUint64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  int nonzeroUint64() {
    final value = uint64();
    if (value == 0) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard returned a zero item ID',
      );
    }
    return value;
  }

  String string16(int maximumBytes) {
    final length = uint16();
    if (length > maximumBytes) {
      throw const ClipboardHistoryException(
        4,
        'Native clipboard string exceeds its limit',
      );
    }
    _require(length);
    final end = _offset + length;
    final value = const Utf8Decoder().convert(_bytes, _offset, end);
    _offset = end;
    if (value.contains('\u0000')) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard string contains NUL',
      );
    }
    return value;
  }

  Uint8List bytes(int length) {
    _require(length);
    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  void expectEnd() {
    if (remaining != 0) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard packet has trailing data',
      );
    }
  }

  void _require(int length) {
    if (length < 0 || length > remaining) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard packet is truncated',
      );
    }
  }
}
