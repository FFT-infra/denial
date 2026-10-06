import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late List<Map<String, Object?>> packages;
  final sdkRoot = p.normalize(p.absolute('../denial_sdk'));
  final ownConfig = File('.dart_tool/package_config.json').absolute;
  final own = jsonDecode(ownConfig.readAsStringSync()) as Map<String, dynamic>;
  final meta = (own['packages'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((p) => p['name'] == 'meta');

  void package(
    String name,
    Map<String, Object?> dependencies,
    String source, {
    Map<String, Object?> dev = const {},
  }) {
    final root = Directory(p.join(fixture.path, name))
      ..createSync(recursive: true);
    Directory(p.join(root.path, 'lib')).createSync();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
      jsonEncode({
        'name': name,
        'environment': {'sdk': '^3.13.0'},
        'dependencies': dependencies,
        'dev_dependencies': dev,
      }),
    );
    File(p.join(root.path, 'lib', '$name.dart')).writeAsStringSync(source);
    packages.add({
      'name': name,
      'rootUri': root.uri.toString().replaceFirst(RegExp(r'/$'), ''),
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
  }

  PackageGraph graph() {
    for (final record in packages.where(
      (p) => (p['rootUri']! as String).startsWith(fixture.uri.toString()),
    )) {
      final root = Directory.fromUri(Uri.parse(record['rootUri']! as String));
      final config = File(p.join(root.path, '.dart_tool/package_config.json'));
      config.parent.createSync();
      config.writeAsStringSync(
        jsonEncode({'configVersion': 2, 'packages': packages}),
      );
    }
    return PackageGraph.read(p.join(fixture.path, 'app'));
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('denial-composition-test-');
    packages = [
      {
        'name': 'denial_sdk',
        'rootUri': Directory(sdkRoot).uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      },
      {
        ...meta,
        'rootUri': ownConfig.uri.resolve(meta['rootUri'] as String).toString(),
      },
    ];
    package(
      'contracts',
      {'denial_sdk': 'any'},
      '''
import 'package:denial_sdk/composition.dart';
@ExtensionPoint(cardinality: ContributionCardinality.exactlyOne)
abstract interface class Label { String get value; }
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrMore)
abstract interface class Item { String get value; }
''',
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('Pub runtime closure discovers transitive plugins and excludes dev dependencies', () async {
    package(
      'dependency',
      {'contracts': 'any', 'denial_sdk': 'any'},
      '''
@Plugin()
library;
import 'package:denial_sdk/composition.dart';
import 'package:contracts/contracts.dart';
@Provides(Label)
class Dependency implements Label { String get value => 'dependency'; }
''',
    );
    package(
      'selected',
      {'dependency': 'any', 'contracts': 'any', 'denial_sdk': 'any'},
      '''
@Plugin()
library;
import 'package:denial_sdk/composition.dart';
import 'package:contracts/contracts.dart';
@Provides(Item)
class Selected implements Item {
  Selected(this.label, {this.suffix = '!'});
  final Label label;
  final String suffix;
  String get value => label.value + suffix;
}
''',
    );
    package('dev_only', {
      'denial_sdk': 'any',
    }, '@Plugin() library; import "package:denial_sdk/composition.dart";');
    package('app', {'selected': 'any'}, '', dev: {'dev_only': 'any'});
    final g = graph();
    expect(g.packages, isNot(contains('dev_only')));
    final discovery = await PluginDiscovery().discover(g);
    expect(discovery.plugins, ['dependency', 'selected']);
    expect(discovery.dependencyChains['dependency'], [
      'app',
      'selected',
      'dependency',
    ]);
    final restored = Discovery.fromJson(
      jsonDecode(jsonEncode(discovery.toJson())) as Map<String, Object?>,
    );
    expect(restored.toJson(), discovery.toJson());
    final plan = CompositionPlan.resolve(restored);
    expect(plan.constructionOrder.map((c) => c.type.name), [
      'Dependency',
      'Selected',
    ]);
    final generated = plan.generate();
    final lib = Directory(p.join(fixture.path, 'app/lib'));
    File(p.join(lib.path, 'composition.dart'))
        .writeAsStringSync(generated.source);
    final item = generated
        .contracts[const TypeId('package:contracts/contracts.dart', 'Item')];
    File(p.join(lib.path, 'main.dart')).writeAsStringSync('''
import 'composition.dart';
void main() { if ($item.single.value != 'dependency!') throw StateError('incorrect wiring'); }
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      // This fixture supplies a synthetic resolved graph, not Pub sources.
      // Run the generated code directly without resolving fictional packages.
      '--packages=${p.join(lib.parent.path, '.dart_tool/package_config.json')}',
      'lib/main.dart',
    ], workingDirectory: lib.parent.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(plan.generate().source, generated.source);
  });

  test('persistent type cache preserves re-exported annotations and invalidates edits', () async {
    package('markers', {
      'denial_sdk': 'any',
    }, "export 'package:denial_sdk/composition.dart';");
    package(
      'selected',
      {'markers': 'any', 'contracts': 'any'},
      """
@marks.Plugin()
library;
import 'package:markers/markers.dart' as marks;
import 'package:contracts/contracts.dart';
@marks.Provides(Label)
class Selected implements Label { String get value => 'selected'; }
""",
    );
    package('app', {'selected': 'any'}, '');
    final g = graph();
    final discovery = PluginDiscovery(
      cacheDirectory: p.join(fixture.path, 'analyzer-cache'),
    );
    final cold = await discovery.discover(g);
    final warm = await discovery.discover(g);
    expect(warm.toJson(), cold.toJson());
    expect(warm.plugins, ['selected']);
    expect(warm.contributions.single.type.name, 'Selected');
    // Change the provider without changing its package or dependencies: cached
    // summaries must not hide a now-invalid implementation.
    final file = File(p.join(fixture.path, 'selected/lib/selected.dart'));
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('implements Label', ''),
    );
    await expectLater(
      discovery.discover(g),
      throwsA(isA<CompositionException>()),
    );
  });

  test('an unrelated same-name annotation cannot activate a package', () async {
    package('impostor', {}, '''
@Plugin() library;
class Plugin { const Plugin(); }
''');
    package('app', {'impostor': 'any', 'denial_sdk': 'any'}, '');
    expect((await PluginDiscovery().discover(graph())).plugins, isEmpty);
  });

  test('rejects an annotation whose implementation does not conform', () async {
    package(
      'broken',
      {'contracts': 'any', 'denial_sdk': 'any'},
      '''
@Plugin() library;
import 'package:denial_sdk/composition.dart';
import 'package:contracts/contracts.dart';
@Provides(Label) class Invalid {}
''',
    );
    package('app', {'broken': 'any'}, '');
    await expectLater(
      PluginDiscovery().discover(graph()),
      throwsA(
        isA<CompositionException>().having(
          (e) => e.message,
          'message',
          contains('does not implement'),
        ),
      ),
    );
  });

  const label = TypeId('package:api/first.dart', 'Label');
  const otherLabel = TypeId('package:api/second.dart', 'Label');
  Contribution provider(
    String name,
    List<TypeId> contracts, [
    List<Injection> arguments = const [],
  ]) => Contribution(
    package: 'test',
    type: TypeId('package:test/test.dart', name),
    contracts: contracts,
    arguments: arguments,
  );
  Discovery declarations(
    List<Contract> contracts,
    List<Contribution> contributions,
  ) => Discovery(
    plugins: ['test'],
    contracts: contracts,
    contributions: contributions,
    dependencyChains: {},
  );

  test(
    'same-name types remain distinct and exclusive choices are explicit',
    () {
      final d = declarations(
        [
          const Contract(label, Cardinality.exactlyOne),
          const Contract(otherLabel, Cardinality.exactlyOne),
        ],
        [
          provider('A', [label]),
          provider('B', [label]),
          provider('Other', [otherLabel]),
        ],
      );
      expect(
        () => CompositionPlan.resolve(d),
        throwsA(isA<CompositionException>()),
      );
      final plan = CompositionPlan.resolve(
        d,
        selections: {label.key: 'package:test/test.dart#B'},
      );
      expect(plan.providers[label]!.single.type.name, 'B');
      expect(plan.providers[otherLabel]!.single.type.name, 'Other');
      expect(
        plan.constructionOrder.map((p) => p.type.name),
        isNot(contains('A')),
      );
    },
  );

  test(
    'missing dependencies and constructor cycles fail before generation',
    () {
      expect(
        () => CompositionPlan.resolve(
          declarations(
            [
              const Contract(label, Cardinality.zeroOrOne),
              const Contract(otherLabel, Cardinality.exactlyOne),
            ],
            [
              provider(
                'A',
                [otherLabel],
                [const Injection('dependency', label)],
              ),
            ],
          ),
        ),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('found 0'),
          ),
        ),
      );
      expect(
        () => CompositionPlan.resolve(
          declarations(
            [
              const Contract(label, Cardinality.exactlyOne),
              const Contract(otherLabel, Cardinality.exactlyOne),
            ],
            [
              provider('A', [label], [const Injection('b', otherLabel)]),
              provider('B', [otherLabel], [const Injection('a', label)]),
            ],
          ),
        ),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('cycle'),
          ),
        ),
      );
    },
  );

  test('collections have deterministic, explicitly overridable order', () {
    final d = declarations(
      [const Contract(label, Cardinality.zeroOrMore)],
      [
        provider('A', [label]),
        provider('B', [label]),
      ],
    );
    final plan = CompositionPlan.resolve(
      d,
      ordering: {
        label.key: ['package:test/test.dart#B', 'package:test/test.dart#A'],
      },
    );
    expect(plan.providers[label]!.map((p) => p.type.name), ['B', 'A']);
    expect(
      () => CompositionPlan.resolve(
        d,
        ordering: {
          label.key: ['package:test/test.dart#B'],
        },
      ),
      throwsA(isA<CompositionException>()),
    );
  });
}
