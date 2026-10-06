import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory repo;
  Future<String> git(List<String> arguments) =>
      runCommand('git', ['-C', repo.path, ...arguments]);
  void package(String path, String name, {bool plugin = true}) {
    final lib = Directory(p.join(repo.path, path, 'lib'))
      ..createSync(recursive: true);
    File(p.join(lib.parent.path, 'pubspec.yaml'))
        .writeAsStringSync(jsonEncode({'name': name, 'description': name}));
    File(p.join(lib.path, 'plugin.dart'))
        .writeAsStringSync(plugin ? '@Plugin() library;' : 'library;');
  }

  Future<String> commit(String message) async {
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Denial Test',
      '-c',
      'user.email=test@invalid',
      'commit',
      '-m',
      message,
    ]);
    return (await git(['rev-parse', 'HEAD'])).trim();
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('denial-source-test-');
    repo = Directory(p.join(root.path, 'repo'))..createSync();
    await git(['init', '-b', 'main']);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'one Git repository exposes independently selectable plugin packages',
    () async {
      package('.', 'root_plugin');
      package('panels/taskbar', 'a_different_name');
      package('shared', 'ordinary', plugin: false);
      package('test/fixture', 'fixture');
      final first = await commit('initial');
      final repository = SourceRepository(
        Directory(p.join(root.path, 'cache')),
      );
      final source = PluginSource(kind: SourceKind.git, location: repo.path);
      final candidates = await repository.inspect(source);
      expect(candidates.map((p) => p['name']), [
        'root_plugin',
        'a_different_name',
      ]);
      final selected = await repository.resolve(
        PluginSource(
          kind: SourceKind.git,
          location: repo.path,
          path: 'panels/taskbar',
        ),
      );
      expect(selected.name, 'a_different_name');
      expect(selected.revision, first);
      package('panels/taskbar', 'a_different_name');
      File(p.join(repo.path, 'panels/taskbar/lib/plugin.dart'))
          .writeAsStringSync('@Plugin() library; // new revision');
      final second = await commit('update');
      expect(second, isNot(first));
      expect(
        (await repository.resolve(source, pinnedRevision: first)).revision,
        first,
      );
      expect((await repository.resolve(source)).revision, second);
    },
  );

  test(
    'source paths cannot escape a repository including through symlinks',
    () async {
      expect(
        () => PluginSource(
          kind: SourceKind.git,
          location: repo.path,
          path: '../escape',
        ),
        throwsA(isA<CompositionException>()),
      );
      Link(p.join(repo.path, 'escape')).createSync(root.path);
      final source = PluginSource(
        kind: SourceKind.local,
        location: repo.path,
        path: 'escape',
      );
      await expectLater(
        SourceRepository(root).resolve(source),
        throwsA(isA<CompositionException>()),
      );
    },
  );

  test('failed checkouts are not published and can be retried', () async {
    package('.', 'retry_plugin');
    await commit('initial');
    final cache = Directory(p.join(root.path, 'cache'));
    final source = PluginSource(kind: SourceKind.git, location: repo.path);
    final broken = SourceRepository(
      cache,
      run: (command, args, {workingDirectory, onOutput}) async {
        if (args.contains('checkout')) {
          throw const CompositionException('simulated checkout interruption');
        }
        return runCommand(command, args, workingDirectory: workingDirectory);
      },
    );
    await expectLater(
      broken.resolve(source),
      throwsA(isA<CompositionException>()),
    );
    expect(
      cache.listSync().map((entry) => p.basename(entry.path)),
      everyElement(endsWith('.git')),
    );
    final recovered = await SourceRepository(cache).resolve(source);
    expect(recovered.name, 'retry_plugin');
    expect(
      File(p.join(recovered.directory, 'lib/plugin.dart')).existsSync(),
      isTrue,
    );
  });

  test(
    'selection preserves roots and rejects package source collisions',
    () async {
      final store = ManagerStore(Directory(p.join(root.path, 'state')));
      final source = PluginSource(kind: SourceKind.local, location: repo.path);
      final plugin = ResolvedSource(
        source: source,
        name: 'panel',
        directory: repo.path,
        revision: 'local',
        description: 'Panel',
      );
      await store.exclusive(() async => store.select(plugin));
      expect((store.selection['roots']! as Map).keys, ['panel']);
      expect(store.selection['revision'], 1);
      expect(
        () => store.select(
          ResolvedSource(
            source: PluginSource(
              kind: SourceKind.git,
              location: 'https://example.invalid/other',
            ),
            name: 'panel',
            directory: '',
            revision: '',
            description: '',
          ),
        ),
        throwsA(isA<CompositionException>()),
      );
      store.remove('panel');
      expect(store.selection['roots'], isEmpty);
      expect(store.selection['revision'], 2);
    },
  );

  test('catalog cannot introduce dependency resolution metadata', () {
    final file = File(p.join(root.path, 'catalog.yaml'));
    file.writeAsStringSync(
      'schema: 1\nplugins:\n  - git: https://example.invalid/plugins\n    path: bar\n',
    );
    final source = PluginCatalog.read(file).single;
    expect(source.path, 'bar');
    file.writeAsStringSync(
      'schema: 1\nplugins:\n  - git: https://example.invalid/plugins\n    dependencies: [another_plugin]\n',
    );
    expect(
      () => PluginCatalog.read(file),
      throwsA(isA<CompositionException>()),
    );
  });

  test('default collection discovery does not select its packages', () async {
    package('plugins/taskbar', 'collection_taskbar');
    package('packages/shared', 'collection_shared', plugin: false);
    File(p.join(repo.path, 'plugins.yaml')).writeAsStringSync(
      'schema: 1\nplugins:\n'
      '  - git: ${PluginCatalog.defaultRepository}\n'
      '    path: plugins/taskbar\n',
    );
    final revision = await commit('collection');
    final store = ManagerStore(Directory(p.join(root.path, 'state')));
    final repository = SourceRepository(
      Directory(p.join(root.path, 'cache')),
      run: (command, args, {workingDirectory, onOutput}) => runCommand(
        command,
        [
          for (final argument in args)
            argument == PluginCatalog.defaultRepository ? repo.path : argument,
        ],
        workingDirectory: workingDirectory,
        onOutput: onOutput,
      ),
    );
    final result = await AvailablePlugins(store, repository).list({});
    expect(result['configured'], isTrue);
    final catalog = result['catalog']! as Map;
    expect(catalog['errors'], isEmpty);
    final plugin = (catalog['entries']! as List).single as Map;
    expect(plugin['name'], 'collection_taskbar');
    expect(plugin['revision'], revision);
    expect((plugin['source']! as Map)['path'], 'plugins/taskbar');
    expect(store.selection['roots'], isEmpty);
    expect(store.selection['revision'], 0);
  });

  test(
    'unavailable default catalog retains usable offline discovery',
    () async {
      var attempts = 0;
      final store = ManagerStore(Directory(p.join(root.path, 'state')));
      final repository = SourceRepository(
        Directory(p.join(root.path, 'cache')),
        run: (command, args, {workingDirectory, onOutput}) async {
          attempts++;
          throw const CompositionException('offline');
        },
      );
      final available = AvailablePlugins(store, repository);
      final first = await available.list({});
      final second = await available.list({});
      expect(attempts, 1);
      expect(first['builtins'], isEmpty);
      expect((first['catalog']! as Map)['errors'], isNotEmpty);
      expect(second['catalog'], first['catalog']);
      expect(store.selection['roots'], isEmpty);
      await expectLater(
        available.refresh({}),
        throwsA(isA<CompositionException>()),
      );
      expect(attempts, 2);
    },
  );
}
