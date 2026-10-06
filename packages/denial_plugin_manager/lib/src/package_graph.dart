import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';

Map<String, Object?> readYamlMap(File file) {
  final value = loadYaml(file.readAsStringSync());
  if (value is! YamlMap) {
    throw CompositionException('Expected a map in ${file.path}');
  }
  return jsonDecode(jsonEncode(value)) as Map<String, Object?>;
}

final class ResolvedPackage {
  const ResolvedPackage(this.name, this.root, this.libraryRoot, this.pubspec);
  final String name;
  final String root;
  final String libraryRoot;
  final Map<String, Object?> pubspec;
  List<String> get dependencies =>
      (pubspec['dependencies'] as Map<String, Object?>? ?? {}).keys.toList()
        ..sort();
}

/// Pub owns resolution; this class only walks its resolved application graph.
final class PackageGraph {
  PackageGraph._(this.application, this.packages, this.chains);
  final String application;
  final Map<String, ResolvedPackage> packages;
  final Map<String, List<String>> chains;

  static PackageGraph read(String workspace) {
    final config = File(p.join(workspace, '.dart_tool/package_config.json'))
        .absolute;
    final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    if (json['configVersion'] != 2) {
      throw const CompositionException('Unsupported Pub package configuration');
    }
    final all = <String, ResolvedPackage>{};
    for (final item in json['packages'] as List<Object?>) {
      final record = item! as Map<String, Object?>;
      final name = record['name']! as String;
      final rootUri = config.uri.resolve(record['rootUri']! as String);
      final root = p.normalize(rootUri.toFilePath());
      final lib = Directory(root).uri
          .resolve(record['packageUri'] as String? ?? 'lib/')
          .toFilePath();
      final manifest = readYamlMap(File(p.join(root, 'pubspec.yaml')));
      if (manifest['name'] != name) {
        throw CompositionException(
          'Pub package $name declares a different name in $root',
        );
      }
      all[name] = ResolvedPackage(name, root, p.normalize(lib), manifest);
    }
    final app =
        readYamlMap(File(p.join(workspace, 'pubspec.yaml')))['name']! as String;
    final chains = <String, List<String>>{
      app: [app],
    };
    final pending = <String>[app];
    final selected = <String, ResolvedPackage>{};
    for (var i = 0; i < pending.length; i++) {
      final name = pending[i];
      final package = all[name];
      if (package == null) {
        throw CompositionException(
          'Unresolved runtime dependency: ${chains[name]!.join(' -> ')}. Run Pub first.',
        );
      }
      selected[name] = package;
      for (final dep in package.dependencies) {
        if (!chains.containsKey(dep)) {
          chains[dep] = [...chains[name]!, dep];
          pending.add(dep);
        }
      }
    }
    return PackageGraph._(app, selected, chains);
  }

  String libraryUri(String path) {
    final absolute = p.normalize(p.absolute(path));
    for (final package in packages.values) {
      final lib = p.normalize(package.libraryRoot);
      if (p.isWithin(lib, absolute)) {
        return 'package:${package.name}/${p.relative(absolute, from: lib).split(p.separator).join('/')}';
      }
    }
    throw CompositionException(
      'Declaration outside runtime package libraries: $path',
    );
  }
}
