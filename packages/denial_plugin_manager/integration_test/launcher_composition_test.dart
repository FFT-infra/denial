import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:denial_plugin_manager/src/sdk_boundary.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Uses the real Flutter contracts and first-party sources without loading
/// dart:ui or building a development engine. Resolve dart_shell's Pub inputs
/// before running this integration test from packages/denial_plugin_manager.
void main() {
  test(
    'reference desktop accepts, omits and rejects conflicting launchers',
    () async {
      final repo = p.normalize(p.absolute('../..'));
      final config = File(
        p.join(repo, 'dart_shell/.dart_tool/package_config.json'),
      );
      final resolved =
          jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
      final fixture = Directory.systemTemp.createTempSync(
        'denial-launcher-composition-',
      );
      addTearDown(() => fixture.deleteSync(recursive: true));
      final packages = [
        for (final record in resolved['packages'] as List)
          if (record['name'] != 'denial_desktop')
            <String, Object?>{
              ...record as Map<String, dynamic>,
              'rootUri': config.uri
                  .resolve(record['rootUri'] as String)
                  .toString(),
            },
        {
          'name': 'denial_desktop',
          'rootUri': Directory(p.join(repo, 'plugins/denial_desktop')).uri
              .toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.13',
        },
        {
          'name': 'alternative_launcher',
          'rootUri': Directory(p.join(fixture.path, 'alternative')).uri
              .toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.13',
        },
      ];
      final alternative = Directory(p.join(fixture.path, 'alternative/lib'))
        ..createSync(recursive: true);
      File(p.join(alternative.parent.path, 'pubspec.yaml'))
          .writeAsStringSync('''
name: alternative_launcher
environment:
  sdk: ^3.13.0
dependencies:
  denial_sdk: any
  denial_flutter_sdk: any
  flutter:
    sdk: flutter
''');
      File(p.join(alternative.path, 'alternative.dart')).writeAsStringSync('''
@Plugin()
library;
import 'package:denial_sdk/composition.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/actions.dart';
import 'package:flutter/widgets.dart';
@Provides(ShellLauncher)
class AlternativeLauncher implements ShellLauncher {
  const AlternativeLauncher();
  @override
  Widget build(BuildContext context, {required LauncherContext launcher}) =>
      const SizedBox.shrink();
}
@Provides(ShellAction)
class ExampleAction implements ShellAction {
  String get id => 'alternative_launcher.arbitrary';
  String get provider => 'Example';
  String label(BuildContext context) => 'Example action';
  String description(BuildContext context) => '';
  void invoke(ShellActionContext context) {}
}
''');
      final application = Directory(p.join(fixture.path, 'app'))..createSync();
      final appConfig = File(
        p.join(application.path, '.dart_tool/package_config.json'),
      );
      appConfig.parent.createSync();
      appConfig.writeAsStringSync(
        jsonEncode({
          ...resolved,
          'packages': [
            ...packages,
            {
              'name': 'launcher_integration',
              'rootUri': application.uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.13',
            },
          ],
        }),
      );
      const contract = TypeId(
        'package:denial_flutter_sdk/launcher.dart',
        'ShellLauncher',
      );
      final discovery = PluginDiscovery(
        cacheDirectory: p.join(fixture.path, 'cache'),
      );
      for (final roots in <List<String>>[
        ['denial_launcher'],
        [],
        ['alternative_launcher'],
        ['denial_launcher', 'alternative_launcher'],
      ]) {
        File(p.join(application.path, 'pubspec.yaml')).writeAsStringSync(
          jsonEncode({
            'name': 'launcher_integration',
            'environment': {'sdk': '^3.13.0'},
            'dependencies': {
              'denial_desktop': {
                'path': p.join(repo, 'plugins/denial_desktop'),
              },
              for (final name in roots) name: 'any',
            },
          }),
        );
        final graph = PackageGraph.read(application.path);
        expect(graph.packages, isNot(contains('denial_dart_shell')));
        validateSdkBoundaries(graph);
        final found = await discovery.discover(graph);
        // The shell's manual entry-point dev dependencies must never activate.
        expect(found.plugins, isNot(contains('denial_taskbar')));
        expect(found.plugins, isNot(contains('denial_top_bar')));
        if (roots.length > 1) {
          expect(
            () => CompositionPlan.resolve(found),
            throwsA(isA<CompositionException>()),
          );
          continue;
        }
        final plan = CompositionPlan.resolve(found);
        expect(plan.providers[contract], hasLength(roots.length));
        final actionProviders =
            plan.providers[const TypeId(
              'package:denial_flutter_sdk/actions.dart',
              'ShellAction',
            )];
        expect(actionProviders ?? [], hasLength(roots.length));
        final source = plan.generate().source;
        expect(source, contains('actions: <'));
        if (roots.contains('alternative_launcher')) {
          expect(source, contains('ExampleAction()'));
        }
        if (roots.contains('denial_launcher')) {
          expect(source, contains('OpenApplicationsAction()'));
        }
        if (roots.isEmpty) {
          expect(found.plugins, isNot(contains('denial_launcher')));
          expect(source, contains('launcher: null'));
          expect(source, isNot(contains('LauncherPlugin')));
        } else {
          expect(source, contains('launcher: provider'));
          expect(
            source,
            contains(
              roots.single == 'denial_launcher'
                  ? 'LauncherPlugin()'
                  : 'AlternativeLauncher()',
            ),
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
