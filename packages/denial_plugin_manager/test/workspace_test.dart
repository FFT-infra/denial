import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () => root = Directory.systemTemp.createTempSync('denial-snapshot-test-'),
  );
  tearDown(() => root.deleteSync(recursive: true));

  void package(String path, String name, Map<String, Object?> dependencies) {
    final directory = Directory(p.join(root.path, path))
      ..createSync(recursive: true);
    File(p.join(directory.path, 'pubspec.yaml')).writeAsStringSync(
      jsonEncode({
        'name': name,
        'version': '0.0.0',
        'dependencies': dependencies,
        'dev_dependencies': {'unused': 'any'},
      }),
    );
    final source = File(p.join(directory.path, 'lib/source.dart'));
    source.parent.createSync();
    source.writeAsStringSync('library;');
    final cache = File(p.join(directory.path, '.dart_tool/private'));
    cache.parent.createSync();
    cache.writeAsStringSync('not a build input');
  }

  test(
    'snapshot relocates shared path dependencies without modifying sources',
    () {
      package('sdk', 'api', {});
      package('plugin', 'plugin', {
        'api': {'path': '../sdk'},
      });
      package('runtime', 'runtime', {
        'api': {'path': '../sdk'},
      });
      final before = treeDigest(Directory(p.join(root.path, 'plugin')));
      final snapshots = PackageSnapshot(
        Directory(p.join(root.path, 'snapshot')),
      );
      final plugin = snapshots.copy(p.join(root.path, 'plugin'));
      snapshots.copy(p.join(root.path, 'runtime'));
      final manifest = readYamlMap(File(p.join(plugin, 'pubspec.yaml')));
      expect(manifest['dependencies'], {
        'api': {'path': '../api'},
      });
      expect(manifest, isNot(contains('dev_dependencies')));
      expect(Directory(p.join(plugin, '.dart_tool')).existsSync(), isFalse);
      expect(treeDigest(Directory(p.join(root.path, 'plugin'))), before);
      File(p.join(root.path, 'plugin/lib/source.dart'))
          .writeAsStringSync('changed after planning');
      expect(
        File(p.join(plugin, 'lib/source.dart')).readAsStringSync(),
        'library;',
      );
    },
  );

  test('installed SDK overrides escaped or duplicate developer SDK paths', () {
    package('installed-sdk', 'denial_sdk', {});
    package('checkout-sdk', 'denial_sdk', {});
    package('plugin', 'plugin', {
      'denial_sdk': {'path': '../missing-checkout/packages/denial_sdk'},
    });
    final snapshot = PackageSnapshot(
      Directory(p.join(root.path, 'snapshot')),
      packageOverrides: {'denial_sdk': p.join(root.path, 'installed-sdk')},
    );
    final plugin = snapshot.copy(p.join(root.path, 'plugin'));
    expect(
      snapshot.copy(p.join(root.path, 'checkout-sdk')),
      p.join(root.path, 'snapshot/denial_sdk'),
    );
    expect(
      snapshot.originals['denial_sdk'],
      p.join(root.path, 'installed-sdk'),
    );
    expect(readYamlMap(File(p.join(plugin, 'pubspec.yaml')))['dependencies'], {
      'denial_sdk': {'path': '../denial_sdk'},
    });
  });

  test(
    'duplicate local package identities and source symlinks are rejected',
    () {
      package('first', 'api', {});
      package('second', 'api', {});
      final snapshots = PackageSnapshot(
        Directory(p.join(root.path, 'snapshot')),
      );
      snapshots.copy(p.join(root.path, 'first'));
      expect(
        () => snapshots.copy(p.join(root.path, 'second')),
        throwsA(isA<CompositionException>()),
      );
      package('plugin', 'plugin', {});
      Link(p.join(root.path, 'plugin/external')).createSync(root.path);
      expect(
        () => snapshots.copy(p.join(root.path, 'plugin')),
        throwsA(isA<CompositionException>()),
      );
    },
  );

  test('installed read-only package files can be snapshotted and rebased', () {
    package('sdk', 'api', {});
    package('plugin', 'plugin', {
      'api': {'path': '../sdk'},
    });
    final source = File(p.join(root.path, 'plugin/pubspec.yaml'));
    final bytes = source.readAsBytesSync();
    expect(Process.runSync('chmod', ['a-w', source.path]).exitCode, 0);
    final readOnlyMode = Process.runSync('stat', [
      '-c',
      '%a',
      source.path,
    ]).stdout.toString().trim();
    final target = PackageSnapshot(Directory(p.join(root.path, 'snapshot')))
        .copy(p.join(root.path, 'plugin'));
    expect(readYamlMap(File(p.join(target, 'pubspec.yaml')))['dependencies'], {
      'api': {'path': '../api'},
    });
    expect(source.readAsBytesSync(), bytes);
    expect(
      Process.runSync('stat', [
        '-c',
        '%a',
        source.path,
      ]).stdout.toString().trim(),
      readOnlyMode,
    );
  });

  test(
    'build rejects stale selection and changed app inputs before running tools',
    () async {
      final store = ManagerStore(Directory(p.join(root.path, 'state')));
      final packages = Directory(
        p.join(store.root.path, 'candidates/test/packages'),
      )..createSync(recursive: true);
      final app = File(
        p.join(store.root.path, 'candidates/test/app/lib/main.dart'),
      );
      app.parent.createSync(recursive: true);
      app.writeAsStringSync('void main() {}');
      final plan = {
        'status': 'planned',
        'selectionRevision': 0,
        'inputDigest': treeDigest(packages),
        'applicationInputs': {'lib/main.dart': fileDigest(app.path)},
      };
      final builder = CompositionBuilder(
        store,
        run: (executable, arguments, {workingDirectory, onOutput}) async =>
            throw StateError('Must not invoke tools for an invalid plan'),
      );
      store.write('candidates/test/plan.json', {
        ...plan,
        'selectionRevision': 1,
      });
      Future<Object?> build() => builder.build(
        'test',
        engineRoot: '/unused',
        engineTarget: 'denial_host_release',
        platform: 'linux-x64',
      );
      await expectLater(
        build(),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('Selection changed'),
          ),
        ),
      );
      store.write('candidates/test/plan.json', plan);
      app.writeAsStringSync('void main() { throw 0; }');
      await expectLater(
        build(),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('application input'),
          ),
        ),
      );
      expect(store.read('active.json'), isEmpty);
      // A source cache or asset can change without changing generated Dart or
      // pubspec.lock. Neither may silently enter a previously reviewed build.
      app.writeAsStringSync('void main() {}');
      final cache = Directory(p.join(root.path, 'pub-cache'))..createSync();
      final dependency = File(p.join(cache.path, 'library.dart'))
        ..writeAsStringSync('const value = 1;');
      final appRoot = Directory(p.dirname(app.parent.path));
      store.write('candidates/test/plan.json', {
        ...plan,
        'applicationDigest': treeDigest(appRoot),
        'resolvedInputs': {
          'dependency': {'root': cache.path, 'digest': treeDigest(cache)},
        },
      });
      dependency.writeAsStringSync('const value = 2;');
      await expectLater(
        build(),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('Resolved package dependency changed'),
          ),
        ),
      );
      File(p.join(appRoot.path, 'added-asset')).writeAsStringSync('new asset');
      await expectLater(
        build(),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('application inputs or assets changed'),
          ),
        ),
      );
    },
  );
}
