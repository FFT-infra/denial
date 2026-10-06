import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('source and compiled clients leave a working detached job', () async {
    final root = Directory.systemTemp.createTempSync('denial-worker-');
    try {
      final fixture = File(p.join(root.path, 'worker.dart'));
      fixture.writeAsStringSync('''
import 'dart:io';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
Future<void> main(List<String> args) async {
  final worker = JobWorker(ManagerStore(Directory(args[1])));
  if (args[2] == 'worker') {
    await worker.run(args[3], (operation) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return {'operation': operation.single, 'workerPid': pid};
    });
  } else {
    print(await worker.submit(['plan']));
  }
}
''');
      final config = (await Isolate.packageConfig)!.toFilePath();
      final executable = p.join(root.path, 'worker');
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '--packages=$config',
        fixture.path,
        '--output=$executable',
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
      for (final compiled in [false, true]) {
        final state = Directory(p.join(root.path, compiled ? 'aot' : 'source'));
        final client = await Process.run(
          compiled ? executable : Platform.resolvedExecutable,
          [
            if (!compiled) ...['--packages=$config', fixture.path],
            '--state',
            state.path,
            'submit',
          ],
        );
        expect(client.exitCode, 0, reason: '${client.stderr}');
        final id = (client.stdout as String).trim();
        ManagerStore.validateId(id);
        final store = ManagerStore(state);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        Map<String, Object?> job;
        do {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          job = store.jobs().single;
        } while ({'queued', 'running'}.contains(job['phase']) &&
            DateTime.now().isBefore(deadline));
        expect(job['phase'], 'succeeded', reason: jsonEncode(job));
        expect((job['result'] as Map)['operation'], 'plan');
        expect((job['result'] as Map)['workerPid'], isNot(pid));
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
