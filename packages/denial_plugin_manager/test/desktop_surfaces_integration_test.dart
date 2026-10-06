import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Pure Dart analysis of real Flutter packages, without starting an engine/UI.
// Supply a resolved development app to exercise the actual SDK and plugins.
void main() {
  final workspace =
      Platform.environment['DENIAL_DESKTOP_COMPOSITION_WORKSPACE'];
  const surfaces = TypeId(
    'package:denial_flutter_sdk/surfaces.dart',
    'ShellSurface',
  );
  const workArea = TypeId(
    'package:denial_flutter_sdk/surfaces.dart',
    'ShellWorkArea',
  );

  Future<CompositionPlan> compose({
    bool clock = true,
    bool topBar = false,
  }) async {
    final root = Directory.systemTemp.createTempSync(
      'denial-surfaces-integration-',
    );
    try {
      final sourceConfig = File(
        p.join(workspace!, '.dart_tool/package_config.json'),
      ).absolute;
      final config =
          jsonDecode(sourceConfig.readAsStringSync()) as Map<String, dynamic>;
      final records = (config['packages'] as List).cast<Map<String, dynamic>>();
      for (final record in records) {
        record['rootUri'] = sourceConfig.uri
            .resolve(record['rootUri'] as String)
            .toString();
      }
      records.removeWhere((record) => record['name'] == 'denial_dart_shell');
      records.add({
        'name': 'surface_fixture',
        'rootUri': root.uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      });
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
        jsonEncode({
          'name': 'surface_fixture',
          'environment': {'sdk': '^3.13.0'},
          'dependencies': {
            'denial_desktop': 'any',
            'denial_taskbar': 'any',
            if (clock) 'denial_clock': 'any',
            if (topBar) 'denial_top_bar': 'any',
          },
        }),
      );
      Directory(p.join(root.path, 'lib')).createSync();
      final targetConfig = File(
        p.join(root.path, '.dart_tool/package_config.json'),
      );
      targetConfig.parent.createSync();
      targetConfig.writeAsStringSync(jsonEncode(config));
      if (!topBar) {
        SelectionPreflight(ManagerStore(Directory(p.join(root.path, 'state'))))
            .requireValid(
              selection: {
                'revision': 0,
                'roots': {
                  for (final name in [
                    'denial_desktop',
                    'denial_taskbar',
                    if (clock) 'denial_clock',
                  ])
                    name: {
                      'directory': Uri.parse(
                        records.singleWhere(
                              (record) => record['name'] == name,
                            )['rootUri']
                            as String,
                      ).toFilePath(),
                    },
                },
              },
            );
      }
      final discovery = await PluginDiscovery().discover(
        PackageGraph.read(root.path),
      );
      expect(discovery.plugins, isNot(contains('denial_clock_ui')));
      return CompositionPlan.resolve(discovery);
    } finally {
      root.deleteSync(recursive: true);
    }
  }

  final skip = workspace == null
      ? 'Set DENIAL_DESKTOP_COMPOSITION_WORKSPACE to a resolved dart_shell.'
      : false;
  test(
    'authoring, hosting and popups have separate public namespaces',
    () async {
      final root = p.absolute(workspace!);
      final contexts = AnalysisContextCollection(includedPaths: [root]);
      try {
        final session = contexts.contextFor(root).currentSession;
        Future<LibraryElementResult> library(String name) async {
          final result = await session.getLibraryByUri(
            'package:denial_flutter_sdk/$name.dart',
          );
          expect(result, isA<LibraryElementResult>());
          return result as LibraryElementResult;
        }

        final authoring = (await library('surfaces')).element.exportNamespace;
        for (final name in [
          'ShellSurface',
          'ShellWorkArea',
          'ShellSurfacePlacement',
          'ShellSurfaceEnvironment',
          'ShellSurfaceContext',
          'ShellSurfaceFade',
          'ShellSurfacePresentation',
          'DisplayOutput',
          'ShellServices',
          'ShellLayoutSettings',
        ]) {
          expect(authoring.get2(name), isNotNull, reason: name);
        }
        for (final name in [
          'ShellSurfaceEntry',
          'ShellSurfacePlane',
          'ShellSurfaceTransition',
          'ShellSurfaceOwnsVisibilityFade',
          'ShellPopupHost',
        ]) {
          expect(authoring.get2(name), isNull, reason: name);
        }
        for (final name in ['ShellSurface', 'ShellWorkArea']) {
          expect(
            authoring.get2(name)!.library!.uri.toString(),
            'package:denial_flutter_sdk/surfaces.dart',
          );
        }
        final hosting = (await library('surface_hosting'))
            .element
            .exportNamespace;
        expect(hosting.get2('ShellSurfacePlane'), isNotNull);
        expect(hosting.get2('resolveShellSurfaces'), isNotNull);
        expect(hosting.get2('ShellSurfaceTransition'), isNull);
        final popups = (await library('popups')).element.exportNamespace;
        expect(popups.get2('ShellPopupHost'), isNotNull);
        expect(popups.get2('shellPopupControllerProvider'), isNotNull);
        expect(popups.get2('ShellSurfaceHost'), isNull);
        final rendering = (await library('rendering')).element.exportNamespace;
        expect(rendering.get2('ShellPopupHost'), isNull);
        expect(rendering.get2('ShellSurfaceHost'), isNull);
      } finally {
        await contexts.dispose();
      }
    },
    skip: skip,
  );

  test('real desktop composes Taskbar and clock surfaces together', () async {
    final plan = await compose();
    expect(
      plan.providers[surfaces]!.map((p) => p.type.name),
      unorderedEquals(['TaskbarPlugin', 'DesktopClockPlugin']),
    );
    expect(plan.providers[workArea]!.single.type.name, 'TaskbarWorkArea');
    expect(plan.generate().source, contains('surfaces:'));
  }, skip: skip);

  test(
    'shared clock face does not force the desktop clock contribution',
    () async {
      final plan = await compose(clock: false);
      expect(plan.providers[surfaces]!.map((p) => p.type.name), [
        'TaskbarPlugin',
      ]);
    },
    skip: skip,
  );

  test('real competing native reservations fail composition', () async {
    await expectLater(
      compose(topBar: true),
      throwsA(isA<CompositionException>()),
    );
  }, skip: skip);
}
