import 'dart:convert';
import 'dart:typed_data';

final class ByteStreamLimitExceeded implements Exception {
  const ByteStreamLimitExceeded(this.maximumBytes);

  final int maximumBytes;

  @override
  String toString() => 'Byte stream exceeded $maximumBytes bytes';
}

/// Collects a bounded response without expanding bytes into a boxed int list.
/// Source chunks must remain unchanged until the returned future completes.
Future<Uint8List> collectBoundedBytes(
  Stream<List<int>> source, {
  required int maximumBytes,
}) async {
  RangeError.checkNotNegative(maximumBytes, 'maximumBytes');
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source) {
    if (chunk.length > maximumBytes - bytes.length) {
      throw ByteStreamLimitExceeded(maximumBytes);
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Decodes CR, LF, and CRLF lines like LineSplitter, enforcing the wire-byte
/// limit before decoding. UTF-8 sequences may span arbitrarily many chunks.
Stream<String> decodeBoundedUtf8Lines(
  Stream<List<int>> source, {
  required int maximumBytes,
}) async* {
  RangeError.checkNotNegative(maximumBytes, 'maximumBytes');
  final pending = BytesBuilder(copy: false);
  var skipLineFeed = false;
  var firstLine = true;
  await for (final data in source) {
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    var start = 0;
    for (var index = 0; index < chunk.length; index++) {
      final byte = chunk[index];
      if (skipLineFeed) {
        skipLineFeed = false;
        if (byte == 10) {
          start = index + 1;
          continue;
        }
      }
      if (byte != 10 && byte != 13) continue;
      final length = index - start;
      if (length > maximumBytes - pending.length) {
        throw ByteStreamLimitExceeded(maximumBytes);
      }
      if (pending.isEmpty) {
        // Complete lines in one socket chunk need no buffer or byte copy.
        yield _decodeLine(chunk, start, index, firstLine);
      } else {
        if (length > 0) pending.add(Uint8List.sublistView(chunk, start, index));
        final bytes = pending.takeBytes();
        yield _decodeLine(bytes, 0, bytes.length, firstLine);
      }
      firstLine = false;
      start = index + 1;
      skipLineFeed = byte == 13;
    }
    if (start < chunk.length) {
      if (chunk.length - start > maximumBytes - pending.length) {
        throw ByteStreamLimitExceeded(maximumBytes);
      }
      pending.add(Uint8List.sublistView(chunk, start));
    }
  }
  if (pending.isNotEmpty) {
    final bytes = pending.takeBytes();
    final line = _decodeLine(bytes, 0, bytes.length, firstLine);
    if (line.isNotEmpty) yield line;
  }
}

String _decodeLine(List<int> bytes, int start, int end, bool firstLine) {
  final line = const Utf8Decoder().convert(bytes, start, end);
  // Utf8Decoder strips a leading BOM on each invocation. A streaming decoder
  // strips it only at the beginning of the stream, so restore it on later lines.
  if (!firstLine &&
      end - start >= 3 &&
      bytes[start] == 0xef &&
      bytes[start + 1] == 0xbb &&
      bytes[start + 2] == 0xbf) {
    return '\ufeff$line';
  }
  return line;
}
