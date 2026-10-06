import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerStore store;
  const desktop =
      'package:denial_flutter_sdk/application.dart#ShellApplication';
  const feature = 'package:custom_api/features.dart#Feature';
  setUp(() {
    root = Directory.systemTemp.createTempSync('denial-preflight-');
    store = ManagerStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));
  void package(
    String name, {
    List<String> provides = const [],
    List<Map<String, Object?>> requires = const [],
    Map<String, Object?> dependencies = const {},
    bool select = true,
    bool declared = true,
  }) {
    final directory = Directory(p.join(root.path, name))..createSync();
    File(p.join(directory.path, 'pubspec.yaml')).writeAsStringSync(
      jsonEncode({
        'name': name,
        'dependencies': dependencies,
        if (declared)
          'denial_plugin': {
            'schema': 1,
            'name': name,
            'provides': [
              for (final id in provides) {'contract': id},
            ],
            'requires': requires,
          },
      }),
    );
    if (select) {
      store.select(
        ResolvedSource(
          source: PluginSource(
            kind: SourceKind.local,
            location: directory.path,
          ),
          name: name,
          directory: directory.path,
          revision: 'local',
          description: '',
        ),
      );
    }
  }

  Map<String, Object?> check() => SelectionPreflight(store).check();
  test('known conflict blocks immediately, including with unresolved Pub dependencies', () {
    package(
      'desktop',
      provides: [desktop],
      requires: [
        {'contract': feature, 'label': 'Feature', 'min': 0, 'max': 1},
      ],
    );
    package(
      'first',
      provides: [feature],
      dependencies: {'hosted_library': '^1.0.0'},
    );
    package('second', provides: [feature]);
    final result = check();
    expect(result['canApply'], false);
    expect(result['complete'], false);
    final issue = (result['issues'] as List).single as Map;
    expect(issue['plugins'], ['first', 'second']);
    expect(issue['message'], contains('Disable one of these plugins'));
    store.remove('second');
    expect(check()['canApply'], true);
  });
  test('missing requirement blocks when known; local dependency providers count once', () {
    package(
      'desktop',
      provides: [desktop],
      requires: [
        {'contract': feature, 'label': 'Feature'},
      ],
    );
    expect(check()['canApply'], false);
    package('dependency', provides: [feature], select: false);
    package(
      'consumer',
      dependencies: {
        'dependency': {'path': '../dependency'},
      },
    );
    package(
      'other_consumer',
      dependencies: {
        'dependency': {'path': '../dependency'},
      },
    );
    expect(check()['canApply'], true);
    expect(check()['complete'], true);
  });
  test('unknown dependency or legacy metadata defers missing-provider decisions to Pub', () {
    package(
      'desktop',
      provides: [desktop],
      requires: [
        {'contract': feature, 'label': 'Feature'},
      ],
    );
    package('legacy', declared: false);
    expect(check()['canApply'], true);
    expect(check()['complete'], false);
  });
  test('empty selection blocks and bad metadata is actionable', () {
    expect(check()['canApply'], false);
    package('bad', provides: ['Feature']);
    expect(
      (check()['issues'] as List).first,
      containsPair('code', 'invalid_declaration'),
    );
  });
  test(
    'optional collection requirements and explicit choices are respected',
    () {
      package(
        'desktop',
        provides: [desktop],
        requires: [
          {'contract': feature, 'label': 'Feature', 'min': 0, 'max': null},
        ],
      );
      package('a', provides: [feature]);
      package('b', provides: [feature]);
      expect(check()['canApply'], true);
      final revision = store.selection['revision'];
      expect(check()['selectionRevision'], revision);
    },
  );
  test(
    'identical short type names in different libraries remain independent',
    () {
      package(
        'desktop',
        provides: [desktop],
        requires: [
          {'contract': feature, 'label': 'Feature', 'min': 0, 'max': 1},
        ],
      );
      package('a', provides: [feature]);
      package('b', provides: ['package:other_api/features.dart#Feature']);
      expect(check()['canApply'], true);
    },
  );
  test('operation failure excludes progress and preserves multiline compiler output', () {
    expect(
      operationFailure([
        'Snapshotting',
        'Resolving packages',
        'denial-plugins: compilation failed',
        'file.dart:12: bad type',
      ], 1),
      'compilation failed\nfile.dart:12: bad type',
    );
    expect(operationFailure(['Preparing'], 7), contains('code 7'));
  });
}
