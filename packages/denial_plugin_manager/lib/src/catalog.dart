import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'package_graph.dart';
import 'source.dart';

/// Catalog membership is discovery only. No version/dependency authority is
/// delegated to this file. A configured Git catalog is retained at an exact ref.
final class PluginCatalog {
  static const defaultRepository =
      'https://github.com/denialwm/denial-plugins.git';

  /// Missing settings use the shipped collection. Explicit overrides,
  /// including a null repository to disable discovery, remain user-owned.
  static Map<String, Object?> configuration(Map<String, Object?> settings) => {
    'catalog-git': defaultRepository,
    'catalog-file': 'plugins.yaml',
    ...settings,
  };

  static List<PluginSource> read(File yaml) {
    final value = readYamlMap(yaml);
    if (value['schema'] != 1 || value['plugins'] is! List) {
      throw const CompositionException('Unsupported plugin catalog schema');
    }
    final sources = <PluginSource>[];
    final seen = <String>{};
    for (final item in value['plugins']! as List<Object?>) {
      if (item is! Map<String, Object?> ||
          item['git'] is! String ||
          item.keys.any((k) => !{'git', 'path', 'ref'}.contains(k))) {
        throw const CompositionException(
          'Catalog entries accept only git, path, and ref',
        );
      }
      final source = PluginSource(
        kind: SourceKind.git,
        location: item['git']! as String,
        path: item['path'] as String? ?? '.',
        ref: item['ref'] as String?,
      );
      if (!seen.add(source.identity)) {
        throw const CompositionException('Duplicate plugin catalog entry');
      }
      sources.add(source);
    }
    return sources;
  }

  static Future<List<PluginSource>> fetch(
    SourceRepository repository,
    PluginSource catalog, {
    String file = 'plugins.yaml',
  }) async {
    if (p.posix.isAbsolute(file) || p.posix.split(file).contains('..')) {
      throw const CompositionException(
        'Catalog path must stay in the repository',
      );
    }
    final (directory, _) = await repository.checkout(catalog);
    return read(File(p.join(directory, file)));
  }
}
