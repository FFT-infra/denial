import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:denial_sdk/plugin_selection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerStore store;
  late SourceRepository repository;
  late Map<String, Object?> selected;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('denial-draft-');
    store = ManagerStore(Directory(p.join(root.path, 'state')));
    repository = SourceRepository(Directory(p.join(root.path, 'repositories')));
    for (final name in ['desktop', 'top', 'bottom']) {
      final directory = Directory(p.join(root.path, name))..createSync();
      final desktop = name == 'desktop';
      File(p.join(directory.path, 'pubspec.yaml')).writeAsStringSync(
        jsonEncode({
          'name': name,
          'version': '0.0.0',
          'environment': {'sdk': '^3.13.0'},
          'denial_plugin': {
            'schema': 1,
            'name': name,
            'provides': [
              {
                'contract': desktop
                    ? 'package:denial_flutter_sdk/application.dart#ShellApplication'
                    : 'package:denial_flutter_sdk/surfaces.dart#ShellWorkArea',
              },
            ],
            'requires': [
              if (desktop)
                {
                  'contract':
                      'package:denial_flutter_sdk/surfaces.dart#ShellWorkArea',
                  'label': 'Native work area',
                  'min': 0,
                  'max': 1,
                },
            ],
          },
        }),
      );
      store.select(
        await repository.resolve(
          PluginSource(kind: SourceKind.local, location: directory.path),
        ),
      );
    }
    store.remove('bottom');
    selected = store.selection;
  });
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, Object?> draft(List<String> names) => {
    'revision': selected['revision'],
    'roots': {
      for (final name in names)
        name: (store.read('installed.json')['plugins']! as Map)[name],
    },
  };

  test('Apply commits a bar swap as exactly one revision', () async {
    await store.exclusive(
      () =>
          commitSelectionDraft(store, repository, draft(['desktop', 'bottom'])),
    );
    expect(store.selection['revision'], (selected['revision']! as int) + 1);
    expect((store.selection['roots']! as Map).keys, ['desktop', 'bottom']);
  });
  test('unchanged draft preserves revision', () async {
    await store.exclusive(
      () => commitSelectionDraft(store, repository, draft(['top', 'desktop'])),
    );
    expect(store.selection, selected);
  });
  test('conflicts do not write any selection', () async {
    final installed = store.read('installed.json');
    await expectLater(
      store.exclusive(
        () => commitSelectionDraft(
          store,
          repository,
          draft(['desktop', 'top', 'bottom']),
        ),
      ),
      throwsA(isA<CompositionException>()),
    );
    expect(store.selection, selected);
    expect(store.read('installed.json'), installed);
  });
  test('stale draft does not overwrite newer selection', () async {
    final old = draft(['desktop', 'bottom']);
    store.remove('top');
    final newer = store.selection;
    await expectLater(
      store.exclusive(() => commitSelectionDraft(store, repository, old)),
      throwsA(isA<CompositionException>()),
    );
    expect(store.selection, newer);
  });
  test('UI evaluates transported declarations with no files remaining', () {
    final known = store.read('installed.json')['plugins']! as Map;
    final transported = jsonDecode(
      jsonEncode(SelectionPreflight(store).describe(known)),
    ) as Map<String, Object?>;
    for (final name in ['desktop', 'top', 'bottom']) {
      Directory(p.join(root.path, name)).deleteSync(recursive: true);
    }
    expect(
      checkPluginSelection(
        draft(['desktop', 'top', 'bottom']),
        transported,
      )['canApply'],
      false,
    );
    expect(
      checkPluginSelection(
        draft(['desktop', 'bottom']),
        transported,
      )['canApply'],
      true,
    );
  });
}
