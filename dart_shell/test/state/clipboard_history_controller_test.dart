import 'dart:async';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a pushed snapshot wins over an older initial read', () async {
    final service = _Service();
    final container = ProviderContainer(
      overrides: [clipboardHistoryServiceProvider.overrideWithValue(service)],
    );
    try {
      container.read(clipboardHistoryProvider);
      await container.pump();
      final pushed = _snapshot(2);
      service.events.add(pushed);
      service.requests.single.complete(_snapshot(1));
      await container.pump();
      expect(container.read(clipboardHistoryProvider).snapshot, same(pushed));
      expect(container.read(clipboardHistoryProvider).loading, isFalse);
    } finally {
      container.dispose();
      await service.events.close();
    }
  });

  test(
    'a query edit immediately suppresses errors from the old query',
    () async {
      final service = _Service();
      final container = ProviderContainer(
        overrides: [clipboardHistoryServiceProvider.overrideWithValue(service)],
      );
      try {
        final controller = container.read(clipboardHistoryProvider.notifier);
        await container.pump();
        controller.setQuery('new query');
        service.requests.single.completeError(StateError('old query'));
        await container.pump();
        final state = container.read(clipboardHistoryProvider);
        expect(state.query, 'new query');
        expect(state.error, isNull);
        expect(state.loading, isTrue);
      } finally {
        container.dispose();
        await service.events.close();
      }
    },
  );

  test('old reads and actions cannot update a rebuilt controller', () async {
    final first = _Service();
    final second = _Service();
    var active = first;
    final container = ProviderContainer(
      overrides: [
        clipboardHistoryServiceProvider.overrideWith((ref) => active),
      ],
    );
    final subscription = container.listen(clipboardHistoryProvider, (_, _) {});
    try {
      final controller = container.read(clipboardHistoryProvider.notifier);
      await container.pump();
      final oldAction = controller.clear();
      active = second;
      container.invalidate(clipboardHistoryServiceProvider);
      container.read(clipboardHistoryProvider);
      await container.pump();
      final newAction = controller.clear();
      first.requests.single.complete(_snapshot(1));
      first.cleared.complete(1);
      await oldAction;
      await container.pump();
      expect(container.read(clipboardHistoryProvider).snapshot, isNull);
      expect(container.read(clipboardHistoryProvider).clearing, isTrue);
      expect(second.requests, hasLength(1));
      second.requests.single.complete(_snapshot(2));
      await container.pump();
      second.cleared.complete(3);
      await container.pump();
      second.requests.last.complete(_snapshot(3));
      expect(await newAction, isTrue);
      expect(container.read(clipboardHistoryProvider).snapshot?.revision, 3);
      expect(container.read(clipboardHistoryProvider).clearing, isFalse);
    } finally {
      subscription.close();
      container.dispose();
      await first.events.close();
      await second.events.close();
    }
  });

  test(
    'disposing before initial microtask does not issue a native read',
    () async {
      final service = _Service();
      final container = ProviderContainer(
        overrides: [clipboardHistoryServiceProvider.overrideWithValue(service)],
      );
      container.read(clipboardHistoryProvider);
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(service.requests, isEmpty);
      await service.events.close();
    },
  );
}

class _Service implements ClipboardHistoryService {
  final events = StreamController<ClipboardHistorySnapshot>.broadcast(
    sync: true,
  );
  final requests = <Completer<ClipboardHistorySnapshot>>[];
  final cleared = Completer<int>();

  @override
  ClipboardHistorySnapshot? get lastSnapshot => null;
  @override
  Stream<ClipboardHistorySnapshot> get snapshots => events.stream;
  @override
  Future<ClipboardHistorySnapshot> snapshot({String query = ''}) {
    final request = Completer<ClipboardHistorySnapshot>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<int> clear() => cleared.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ClipboardHistorySnapshot _snapshot(int revision) => ClipboardHistorySnapshot(
  revision: revision,
  totalBytes: 0,
  activeId: null,
  paused: false,
  locked: false,
  entries: const [],
);
