import 'package:denial_flutter_sdk/src/platform/bounded_byte_stream.dart'
    show ByteStreamLimitExceeded, collectBoundedBytes, decodeBoundedUtf8Lines;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  test(
    'bounded collection preserves fragmented bytes and exact limits',
    () async {
      final bytes = Uint8List.fromList(List.generate(256, (i) => i));
      final result = await collectBoundedBytes(
        Stream.fromIterable([
          Uint8List.sublistView(bytes, 0, 2),
          Uint8List(0),
          Uint8List.sublistView(bytes, 2, 200),
          bytes.sublist(200),
        ]),
        maximumBytes: 256,
      );
      expect(result, bytes);
      expect(
        await collectBoundedBytes(const Stream.empty(), maximumBytes: 0),
        isEmpty,
      );
    },
  );

  test(
    'oversized responses cancel their source before reading more chunks',
    () async {
      var cancelled = false;
      var readPastLimit = false;
      Stream<List<int>> source() async* {
        try {
          yield [1, 2];
          yield [3, 4];
          readPastLimit = true;
          yield [5];
        } finally {
          cancelled = true;
        }
      }

      await expectLater(
        collectBoundedBytes(source(), maximumBytes: 3),
        throwsA(isA<ByteStreamLimitExceeded>()),
      );
      expect(cancelled, isTrue);
      expect(readPastLimit, isFalse);
    },
  );

  test(
    'CR, LF, CRLF, BOMs and multibyte text match streaming UTF-8 decoding',
    () async {
      for (final text in [
        '',
        '\ufeff',
        '\n',
        '\r',
        '\r\n',
        '\ufeff\r\n',
        'a\rb\nc\r\nd',
        '\ufeff日本語😀\r\n\ufeffsecond\r\nlast',
        '\r\ufeff\n',
        'a\n\n\n',
        '😀\n終わり',
      ]) {
        final bytes = utf8.encode(text);
        for (var split = 0; split <= bytes.length; split++) {
          final chunks = [
            Uint8List.sublistView(bytes, 0, split),
            Uint8List(0),
            Uint8List.sublistView(bytes, split),
          ];
          final expected = await utf8.decoder
              .bind(Stream.fromIterable(chunks))
              .transform(const LineSplitter())
              .toList();
          expect(
            await decodeBoundedUtf8Lines(
              Stream.fromIterable(chunks),
              maximumBytes: 1000,
            ).toList(),
            expected,
            reason: '$text split $split',
          );
        }
      }
    },
  );

  test('line limits count UTF-8 bytes independently of newline and chunk boundaries', () async {
    expect(
      await decodeBoundedUtf8Lines(
        Stream.value(utf8.encode('éé\r\n1234\n')),
        maximumBytes: 4,
      ).toList(),
      ['éé', '1234'],
    );
    await expectLater(
      decodeBoundedUtf8Lines(
        Stream.value(utf8.encode('ééé\n')),
        maximumBytes: 4,
      ).toList(),
      throwsA(isA<ByteStreamLimitExceeded>()),
    );
    await expectLater(
      decodeBoundedUtf8Lines(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        maximumBytes: 3,
      ).toList(),
      throwsA(isA<ByteStreamLimitExceeded>()),
    );
  });

  test(
    'oversized unterminated lines are rejected before stream completion',
    () async {
      final source = StreamController<List<int>>();
      final result = decodeBoundedUtf8Lines(
        source.stream,
        maximumBytes: 3,
      ).toList();
      final check = expectLater(
        result,
        throwsA(isA<ByteStreamLimitExceeded>()),
      );
      source.add([65, 65, 65, 65]);
      await check;
      expect(source.hasListener, isFalse);
      await source.close();
    },
  );

  test(
    'malformed UTF-8 is rejected, including incomplete final sequences',
    () async {
      for (final bytes in [
        [0xff, 10],
        [0xe2, 10],
        [0xf0, 0x9f],
      ]) {
        await expectLater(
          decodeBoundedUtf8Lines(
            Stream.value(bytes),
            maximumBytes: 100,
          ).toList(),
          throwsFormatException,
        );
      }
    },
  );

  test('taking one line cancels the upstream stream', () async {
    var cancelled = false;
    var readNext = false;
    Stream<List<int>> source() async* {
      try {
        yield utf8.encode('one\ntwo\n');
        readNext = true;
        yield utf8.encode('three\n');
      } finally {
        cancelled = true;
      }
    }

    expect(
      await decodeBoundedUtf8Lines(source(), maximumBytes: 100).first,
      'one',
    );
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(readNext, isFalse);
  });

  test('random byte chunking preserves all valid lines', () async {
    final random = Random(842);
    const fragments = [
      'hello',
      '😀',
      'é',
      '中',
      '\n',
      '\r',
      '\r\n',
      '\ufeff',
      ' ',
    ];
    for (var trial = 0; trial < 500; trial++) {
      final text = List.generate(
        random.nextInt(100),
        (_) => fragments[random.nextInt(fragments.length)],
      ).join();
      final bytes = utf8.encode(text);
      final chunks = <List<int>>[];
      for (var start = 0; start < bytes.length;) {
        final end = min(start + 1 + random.nextInt(15), bytes.length);
        chunks.add(Uint8List.sublistView(bytes, start, end));
        start = end;
      }
      final expected = await utf8.decoder
          .bind(Stream.fromIterable(chunks))
          .transform(const LineSplitter())
          .toList();
      expect(
        await decodeBoundedUtf8Lines(
          Stream.fromIterable(chunks),
          maximumBytes: 1000,
        ).toList(),
        expected,
        reason: 'trial $trial',
      );
    }
  });
}
