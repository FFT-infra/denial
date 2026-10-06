import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Directory source;
  late ManagerStore store;
  late Map<String, Object?> manifest;
  late String dartExecutable;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('denial-kit-test-');
    source = Directory(p.join(directory.path, 'installed'))..createSync();
    store = ManagerStore(Directory(p.join(directory.path, 'state')));
    final files = <String, String>{};
    for (final path in [
      'runtime/.denial-ui-source.json',
      'runtime/plugins/builtins.yaml',
      'flutter/bin/flutter',
      'engine/out/denial_host_release/gen_snapshot',
    ]) {
      final file = File(p.join(source.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        path == 'runtime/plugins/builtins.yaml'
            ? 'schema: 1\nplugins: []\n'
            : 'contents of $path',
      );
      files[path] = sha256.convert(file.readAsBytesSync()).toString();
    }
    manifest = {
      'schema': 1,
      'platform': 'linux-x64',
      'engineTarget': 'denial_host_release',
      'dartVersion': '3.13.4',
      'dartConstraint': '>=3.13.0 <4.0.0',
      'files': files,
      'links': <String, String>{},
    };
    File(p.join(source.path, 'kit.json'))
        .writeAsStringSync(jsonEncode(manifest));
    final dartSdk = Directory(p.join(directory.path, 'dart-sdk'));
    dartExecutable = p.join(dartSdk.path, 'bin/dart');
    for (final path in [
      'bin/dart',
      'bin/snapshots/frontend_server_aot.dart.snapshot',
      'lib/core/core.dart',
    ]) {
      final file = File(p.join(dartSdk.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture');
    }
    Process.runSync('chmod', ['0755', dartExecutable]);
    File(p.join(dartSdk.path, 'version')).writeAsStringSync('3.13.2\n');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'automatic setup runs once and preserves deliberately disabled defaults',
    () async {
      void input(String path, String contents) {
        final file = File(p.join(source.path, path));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(contents);
        (manifest['files'] as Map)[path] = sha256
            .convert(file.readAsBytesSync())
            .toString();
      }

      input(
        'runtime/plugins/builtins.yaml',
        'schema: 1\nplugins:\n  - path: bar\n    default: true\n',
      );
      input('runtime/plugins/bar/pubspec.yaml', 'name: bar\nversion: 0.0.0\n');
      File(p.join(source.path, 'kit.json'))
          .writeAsStringSync(jsonEncode(manifest));
      final kit = BuildKit(
        store,
        source: source,
        dartExecutable: dartExecutable,
      );
      expect(kit.ready, isFalse);
      final first = await kit.initialize();
      expect(kit.ready, isTrue);
      expect((store.selection['roots'] as Map).keys, ['bar']);
      store.remove('bar');
      final revision = store.selection['revision'];
      expect(await kit.initialize(), first);
      expect(store.selection['roots'], isEmpty);
      expect(store.selection['revision'], revision);
      // Old user-supplied paths cannot override the installed compiler.
      store.write('configuration.json', {
        ...first,
        'flutter': '/wrong/flutter',
      });
      expect(kit.ready, isFalse);
      expect((await kit.initialize())['flutter'], first['flutter']);
      expect(store.selection['roots'], isEmpty);
    },
  );

  test('provisioning is isolated, verified and reusable', () async {
    final kit = BuildKit(store, source: source, dartExecutable: dartExecutable);
    final configuration = await kit.prepare();
    final flutter = configuration['flutter']! as String;
    expect(p.isWithin(store.root.path, flutter), isTrue);
    expect(await kit.prepare(), configuration);
    final prepared = Directory(p.dirname(p.dirname(p.dirname(flutter))));
    expect(
      Link(p.join(prepared.path, 'flutter/bin/cache/dart-sdk'))
          .resolveSymbolicLinksSync(),
      p.dirname(p.dirname(dartExecutable)),
    );
    expect(
      configuration['dart'],
      File(dartExecutable).resolveSymbolicLinksSync(),
    );
    File(flutter).writeAsStringSync('modified compiler');
    await expectLater(kit.prepare(), throwsA(isA<CompositionException>()));
    expect(
      File(p.join(source.path, 'flutter/bin/flutter')).readAsStringSync(),
      'contents of flutter/bin/flutter',
    );
  });

  test('catalog defaults migrate without replacing user overrides', () async {
    final kit = BuildKit(store, source: source, dartExecutable: dartExecutable);
    final first = await kit.initialize();
    expect(first['catalog-git'], PluginCatalog.defaultRepository);
    store.write('configuration.json', {
      ...first,
      'catalog-git': 'https://example.invalid/my-collection.git',
      'catalog-ref': 'custom',
      'catalog-file': 'index.yaml',
    });
    final custom = await kit.initialize();
    expect(custom['catalog-git'], 'https://example.invalid/my-collection.git');
    expect(custom['catalog-ref'], 'custom');
    expect(custom['catalog-file'], 'index.yaml');
    store.write('configuration.json', {...custom, 'catalog-git': null});
    expect((await kit.initialize())['catalog-git'], isNull);
    store.write('configuration.json', {
      for (final entry in first.entries)
        if (!entry.key.startsWith('catalog-')) entry.key: entry.value,
    });
    expect(
      (await kit.initialize())['catalog-git'],
      PluginCatalog.defaultRepository,
    );
    expect(store.selection['roots'], isEmpty);
  });

  test(
    'corrupt installed tools do not replace an existing configuration',
    () async {
      store.write('configuration.json', {'runtime': '/existing'});
      File(p.join(source.path, 'flutter/bin/flutter'))
          .writeAsStringSync('corrupt');
      await expectLater(
        BuildKit(
          store,
          source: source,
          dartExecutable: dartExecutable,
        ).prepare(),
        throwsA(isA<CompositionException>()),
      );
      expect(store.read('configuration.json')['runtime'], '/existing');
      expect(
        Directory(p.join(store.root.path, 'build-kits')).existsSync(),
        isFalse,
      );
    },
  );

  test('kit links cannot escape to mutable external tools', () async {
    final outside = File(p.join(directory.path, 'outside'))
      ..writeAsStringSync('external');
    Link(p.join(source.path, 'compiler')).createSync(outside.path);
    manifest['links'] = {'compiler': outside.path};
    File(p.join(source.path, 'kit.json'))
        .writeAsStringSync(jsonEncode(manifest));
    await expectLater(
      BuildKit(store, source: source, dartExecutable: dartExecutable).prepare(),
      throwsA(isA<CompositionException>()),
    );
    expect(store.read('configuration.json'), isEmpty);
  });

  test(
    'kit upgrades retain built-in intent against the new source snapshot',
    () async {
      void input(String path, String content) {
        final file = File(p.join(source.path, path));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(content);
        (manifest['files']! as Map<String, String>)[path] = sha256
            .convert(file.readAsBytesSync())
            .toString();
        File(p.join(source.path, 'kit.json'))
            .writeAsStringSync(jsonEncode(manifest));
      }

      input(
        'runtime/plugins/builtins.yaml',
        'schema: 1\nplugins:\n  - path: bar\n',
      );
      input('runtime/plugins/bar/pubspec.yaml', 'name: bar\nversion: 0.0.0\n');
      final kit = BuildKit(
        store,
        source: source,
        dartExecutable: dartExecutable,
      );
      final first = await kit.prepare();
      final repository = SourceRepository(
        Directory(p.join(directory.path, 'repositories')),
      );
      store.select(
        await repository.resolve(
          PluginSource(
            kind: SourceKind.builtin,
            location: p.join(first['runtime']! as String, 'plugins'),
            path: 'bar',
          ),
        ),
      );
      input('flutter/bin/flutter', 'updated compiler launcher');
      input(
        'runtime/plugins/builtins.yaml',
        'schema: 1\nplugins:\n  - path: bar\n  - path: launcher\n    default: true\n',
      );
      input(
        'runtime/plugins/launcher/pubspec.yaml',
        'name: launcher\nversion: 0.0.0\n',
      );
      final second = await kit.prepare();
      expect(first['runtime'], isNot(second['runtime']));
      expect(
        Directory(p.dirname(first['runtime']! as String)).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.dirname(second['runtime']! as String)).existsSync(),
        isTrue,
      );
      final selected = (store.selection['roots']! as Map)['bar'] as Map;
      expect(
        (selected['source'] as Map)['location'],
        p.join(second['runtime']! as String, 'plugins'),
      );
      expect(store.selection['revision'], 2);
      expect((store.read('installed.json')['plugins'] as Map)['bar'], selected);
      expect(
        (store.read('installed.json')['plugins'] as Map).keys,
        contains('launcher'),
      );
      expect((store.selection['roots'] as Map).keys, ['bar']);
    },
  );

  test('setup explains missing and incompatible Dart installations', () async {
    final missing = BuildKit(
      store,
      source: source,
      dartExecutable: p.join(directory.path, 'missing-dart'),
    );
    expect(missing.dartStatus['available'], isFalse);
    expect(missing.dartStatus['error'], contains('Install the dart package'));
    await expectLater(
      missing.prepare(),
      throwsA(
        isA<DartSdkException>().having(
          (error) => error.message,
          'message',
          contains('Dart 3.13.4'),
        ),
      ),
    );

    Process.runSync('chmod', ['0644', dartExecutable]);
    final notExecutable = BuildKit(
      store,
      source: source,
      dartExecutable: dartExecutable,
    );
    expect(notExecutable.dartStatus['available'], isFalse);
    expect(notExecutable.dartStatus['error'], contains('not executable'));
    Process.runSync('chmod', ['0755', dartExecutable]);

    File(p.join(p.dirname(p.dirname(dartExecutable)), 'version'))
        .writeAsStringSync('4.0.0\n');
    final incompatible = BuildKit(
      store,
      source: source,
      dartExecutable: dartExecutable,
    );
    expect(incompatible.dartStatus['version'], '4.0.0');
    await expectLater(
      incompatible.prepare(),
      throwsA(
        isA<DartSdkException>().having(
          (error) => error.message,
          'message',
          allOf(contains('4.0.0'), contains('>=3.13.0 <4.0.0')),
        ),
      ),
    );
  });
}
