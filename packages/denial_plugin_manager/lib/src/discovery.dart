import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import 'analysis_cache.dart';
import 'model.dart';
import 'package_graph.dart';

/// Analyzes source; it never imports or executes plugin Dart code.
final class PluginDiscovery {
  const PluginDiscovery({this.sdkPath, this.cacheDirectory});
  final String? sdkPath;
  final String? cacheDirectory;

  Future<Discovery> discover(PackageGraph graph) async {
    if (!graph.packages.containsKey('denial_sdk')) {
      throw const CompositionException(
        'The runtime graph must depend on denial_sdk',
      );
    }
    // A package can use SDK annotation identities only through its declared
    // dependency closure (including re-exporting libraries). Do not resolve
    // unrelated @deprecated/@JS library metadata in Flutter and its platform
    // dependencies: those packages cannot contribute Denial plugins.
    final dependents = <String, List<String>>{};
    for (final package in graph.packages.values) {
      for (final dependency in package.dependencies) {
        dependents.putIfAbsent(dependency, () => []).add(package.name);
      }
    }
    final eligible = <String>{'denial_sdk'};
    final pending = <String>['denial_sdk'];
    for (var i = 0; i < pending.length; i++) {
      for (final name in dependents[pending[i]] ?? const <String>[]) {
        if (eligible.add(name)) pending.add(name);
      }
    }
    // All libraries must resolve through the application's Pub configuration,
    // including Git cache packages which have no package_config of their own.
    final applicationRoot = graph.packages[graph.application]!.root;
    final contexts = pluginAnalysisContexts(
      applicationRoot: applicationRoot,
      sdkPath: sdkPath,
      cacheDirectory: cacheDirectory,
    );
    final session = contexts.contextFor(applicationRoot).currentSession;
    try {
      final contracts = <TypeId, Contract>{};
      final contributions = <Contribution>[];
      final plugins = <String>{};
      final files = <(String, String)>[];
      for (final package in graph.packages.values) {
        if (!eligible.contains(package.name)) continue;
        final lib = Directory(package.libraryRoot);
        if (!lib.existsSync()) continue;
        for (final file
            in lib
                .listSync(recursive: true, followLinks: false)
                .whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          // This is only a candidate filter; aliases and SDK identity are
          // resolved by the analyzer below.
          final source = file.readAsStringSync();
          if (!source.contains('@') || !source.contains('library')) continue;
          final unit = parseString(
            content: source,
            throwIfDiagnostics: false,
          ).unit;
          if (!unit.directives.whereType<LibraryDirective>().any(
            (d) => d.metadata.isNotEmpty,
          )) {
            continue;
          }
          files.add((package.name, file.path));
        }
      }
      files.sort((a, b) => a.$2.compareTo(b.$2));
      final markerResult = await session.getLibraryByUri(
        'package:denial_sdk/src/composition/annotations.dart',
      );
      if (markerResult is! LibraryElementResult) {
        throw const CompositionException(
          'Cannot resolve SDK composition metadata',
        );
      }
      final markers = {for (final c in markerResult.element.classes) c.name: c};
      for (final (package, path) in files) {
        final resolved = await session.getLibraryByUri(graph.libraryUri(path));
        if (resolved is! LibraryElementResult) {
          throw CompositionException(
            'Cannot resolve contribution library $path',
          );
        }
        final library = resolved.element;
        List<DartObject> annotations(Element element, String marker) => element
            .metadata
            .annotations
            .map((a) => a.computeConstantValue())
            .whereType<DartObject>()
            .where(
              (a) =>
                  a.type is InterfaceType &&
                  (a.type! as InterfaceType).element == markers[marker],
            )
            .toList();
        if (annotations(library, 'Plugin').isEmpty) continue;
        plugins.add(package);
        TypeId identity(InterfaceElement element) {
          final uri = element.library.uri;
          return TypeId(
            uri.scheme == 'package'
                ? uri.toString()
                : graph.libraryUri(
                    element.library.firstFragment.source.fullName,
                  ),
            element.name!,
          );
        }

        TypeId contractType(InterfaceType type, String origin) {
          final metadata = annotations(type.element, 'ExtensionPoint');
          if (metadata.length != 1 ||
              type.typeArguments.isNotEmpty ||
              type.element.isPrivate) {
            throw CompositionException(
              '$origin: ${type.getDisplayString()} must be a public, non-generic @ExtensionPoint',
            );
          }
          final index = metadata.single
              .getField('cardinality')
              ?.getField('index')
              ?.toIntValue();
          if (index == null ||
              index < 0 ||
              index >= Cardinality.values.length) {
            throw CompositionException('$origin: invalid cardinality');
          }
          final id = identity(type.element);
          contracts[id] = Contract(id, Cardinality.values[index]);
          return id;
        }

        for (final implementation in library.classes) {
          final provides = annotations(implementation, 'Provides');
          if (provides.isEmpty) continue;
          final id = identity(implementation);
          if (implementation.isAbstract ||
              implementation.isPrivate ||
              implementation.typeParameters.isNotEmpty) {
            throw CompositionException(
              '$id must be public, concrete, and non-generic',
            );
          }
          final supplied = <TypeId>[];
          for (final annotation in provides) {
            final type = annotation.getField('contract')?.toTypeValue();
            if (type is! InterfaceType) {
              throw CompositionException(
                '$id: @Provides needs an interface type',
              );
            }
            final contract = contractType(type, id.key);
            if (!library.typeSystem.isSubtypeOf(
              implementation.thisType,
              type,
            )) {
              throw CompositionException('$id does not implement $contract');
            }
            if (supplied.contains(contract)) {
              throw CompositionException(
                '$id provides $contract more than once',
              );
            }
            supplied.add(contract);
          }
          final constructor = implementation.unnamedConstructor;
          if (constructor == null) {
            throw CompositionException(
              '$id needs an unnamed constructor for generated injection',
            );
          }
          final arguments = <Injection>[];
          for (final parameter in constructor.formalParameters) {
            final type = parameter.type;
            InterfaceType? dependency;
            var many = false;
            if (type is InterfaceType) {
              if (type.isDartCoreList &&
                  type.typeArguments.single is InterfaceType &&
                  annotations(
                    (type.typeArguments.single as InterfaceType).element,
                    'ExtensionPoint',
                  ).isNotEmpty) {
                dependency = type.typeArguments.single as InterfaceType;
                many = true;
              } else if (annotations(
                type.element,
                'ExtensionPoint',
              ).isNotEmpty) {
                dependency = type;
              }
            }
            if (dependency == null) {
              if (parameter.isOptionalNamed) continue;
              throw CompositionException(
                '$id parameter ${parameter.name}: use a typed extension point, List<Contract>, or an optional named default',
              );
            }
            final contract = contractType(dependency, id.key);
            arguments.add(
              Injection(
                parameter.name!,
                contract,
                named: parameter.isNamed,
                many: many,
                nullable: type.nullabilitySuffix == NullabilitySuffix.question,
              ),
            );
          }
          contributions.add(
            Contribution(
              package: package,
              type: id,
              contracts: supplied..sort(),
              arguments: arguments,
            ),
          );
        }
      }
      contributions.sort((a, b) => a.type.compareTo(b.type));
      final sortedContracts = contracts.values.toList()
        ..sort((a, b) => a.type.compareTo(b.type));
      return Discovery(
        plugins: plugins.toList()..sort(),
        contracts: sortedContracts,
        contributions: contributions,
        dependencyChains: graph.chains,
      );
    } finally {
      await contexts.dispose();
    }
  }
}
