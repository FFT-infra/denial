import 'package:denial_flutter_sdk/workers.dart'
    show
        BackgroundWorker,
        BackgroundWorkerEntrypoint,
        BackgroundWorkerException,
        serveBackgroundWorker;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  BackgroundWorker worker(BackgroundWorkerEntrypoint entrypoint) {
    final result = BackgroundWorker(entrypoint: entrypoint, debugName: 'test');
    addTearDown(result.close);
    return result;
  }

  Future<Object?> invoke(
    BackgroundWorker worker,
    int operation, [
    Object? payload,
  ]) => worker
      .invoke(operation: operation, payload: payload, decode: (value) => value)
      .timeout(const Duration(seconds: 2));

  test(
    'requests share startup, execute in order, and survive operation errors',
    () async {
      final instance = worker(_echoWorker);
      expect(
        await Future.wait([
          invoke(instance, 1),
          invoke(instance, 1),
          invoke(instance, 1),
        ]),
        [1, 2, 3],
      );
      await expectLater(
        invoke(instance, 2),
        throwsA(isA<BackgroundWorkerException>()),
      );
      expect(await invoke(instance, 1), 4);
    },
  );

  test('close cancels concurrent startup and permits a fresh worker', () async {
    final instance = worker(_echoWorker);
    final pending = [for (var i = 0; i < 8; i++) invoke(instance, 1)];
    final failures = [
      for (final request in pending) expectLater(request, throwsStateError),
    ];
    await instance.close();
    await Future.wait(failures);
    expect(await invoke(instance, 1), 1);
    expect(await invoke(instance, 1), 2);
  });

  test('close aborts a missing startup handshake promptly', () async {
    final instance = worker(_silentWorker);
    final failure = expectLater(invoke(instance, 1), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await instance.close();
    await failure;
  });

  test(
    'a crash before the handshake fails without waiting for its timeout',
    () async {
      await expectLater(invoke(worker(_crashingWorker), 1), throwsStateError);
    },
  );

  test('an invalid handshake fails and can be closed repeatedly', () async {
    final instance = worker(_invalidWorker);
    await expectLater(invoke(instance, 1), throwsStateError);
    await instance.close();
    await instance.close();
  });

  test(
    'worker exit fails an in-flight request and the next call restarts',
    () async {
      final instance = worker(_echoWorker);
      expect(await invoke(instance, 1), 1);
      await expectLater(invoke(instance, 3), throwsStateError);
      expect(await invoke(instance, 1), 1);
    },
  );

  test('an unsendable payload does not prevent subsequent requests', () async {
    final instance = worker(_echoWorker);
    final port = ReceivePort();
    addTearDown(port.close);
    await expectLater(invoke(instance, 1, port), throwsArgumentError);
    expect(await invoke(instance, 1), 1);
  });

  test('close interrupts an operation that never completes', () async {
    final instance = worker(_echoWorker);
    final running = ReceivePort();
    addTearDown(running.close);
    final failure = expectLater(
      invoke(instance, 4, running.sendPort),
      throwsStateError,
    );
    await running.first.timeout(const Duration(seconds: 2));
    await instance.close();
    await failure;
    expect(await invoke(instance, 1), 1);
  });

  test('late startup completions cannot replace a newer generation', () async {
    final instance = worker(_echoWorker);
    for (var generation = 0; generation < 20; generation++) {
      final cancelled = expectLater(invoke(instance, 1), throwsStateError);
      await instance.close();
      final next = invoke(instance, 1);
      await cancelled;
      expect(await next, 1);
      expect(await invoke(instance, 1), 2);
      await instance.close();
    }
  });
}

void _echoWorker(List<SendPort> bootstrap) {
  var sequence = 0;
  serveBackgroundWorker(bootstrap, (operation, payload) async {
    switch (operation) {
      case 1:
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return ++sequence;
      case 2:
        throw StateError('operation failed');
      case 3:
        Isolate.exit();
      case 4:
        (payload! as SendPort).send('running');
        return Completer<Object?>().future;
      default:
        return payload;
    }
  });
}

void _silentWorker(List<SendPort> bootstrap) {
  ReceivePort().listen((_) {});
}

void _crashingWorker(List<SendPort> bootstrap) =>
    throw StateError('startup failed');

void _invalidWorker(List<SendPort> bootstrap) {
  bootstrap.first.send('not a command port');
  ReceivePort().listen((_) {});
}
