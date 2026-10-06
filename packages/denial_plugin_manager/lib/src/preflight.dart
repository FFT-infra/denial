import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:denial_sdk/plugin_selection.dart';

import 'model.dart';
import 'package_graph.dart';
import 'store.dart';

/// Advisory package declarations only. No Pub, analyzer, network, or plugin code.
/// Positive conflicts can be rejected even when dependency sources are unknown;
/// missing providers are rejected only when every possible source is known.
final class SelectionPreflight {
  SelectionPreflight(this.store);
  final ManagerStore store;

  Map<String, Object?> check({Map<String, Object?>? selection}) {
    selection ??= store.selection;
    return checkPluginSelection(
      selection,
      describe(selection['roots']! as Map),
    );
  }

  /// Cache all available packages, including disabled roots, for local drafts.
  Map<String, Object?> describe(Map roots) {
    final packages = <String, Object?>{};
    String contract(Object? value) {
      if (value is! String ||
          !RegExp(
            r'^package:[a-z][a-z0-9_]*/[^#\s]+\.dart#[A-Za-z_$][A-Za-z0-9_$]*$',
          ).hasMatch(value)) {
        throw const FormatException(
          'Contracts must use package:library.dart#Type identities.',
        );
      }
      return value;
    }

    void visit(String name, String directory) {
      if (packages.containsKey(name)) return;
      final providers = <String, List<String>>{};
      final requirements = <Map<String, Object?>>[];
      final issues = <Map<String, Object?>>[];
      final unknown = <String>{};
      final dependencies = <String>[];
      packages[name] = {
        'providers': providers,
        'requirements': requirements,
        'issues': issues,
        'unknown': unknown,
        'dependencies': dependencies,
      };
      try {
        final manifest = readYamlMap(File(p.join(directory, 'pubspec.yaml')));
        if (manifest['name'] != name) {
          throw const FormatException('Package name does not match.');
        }
        final declaration = manifest['denial_plugin'];
        if (declaration != null) {
          if (declaration is! Map ||
              declaration['schema'] != 1 ||
              declaration['name'] is! String ||
              (declaration['name'] as String).trim().isEmpty) {
            throw const FormatException(
              'Expected denial_plugin schema 1 and a display name.',
            );
          }
          final title = declaration['name'] as String;
          final provided = declaration['provides'] ?? <Object?>[];
          final required = declaration['requires'] ?? <Object?>[];
          if (provided is! List || required is! List) {
            throw const FormatException('provides and requires must be lists.');
          }
          for (final value in provided) {
            if (value is! Map) {
              throw const FormatException('Invalid provider declaration.');
            }
            final id = contract(value['contract']);
            final count = value['count'] ?? 1;
            if (count is! int || count < 1 || count > 1024) {
              throw const FormatException(
                'Provider count must be a positive integer, at most 1024.',
              );
            }
            providers
                .putIfAbsent(id, () => [])
                .addAll(List.filled(count, title));
          }
          for (final value in required) {
            if (value is! Map) {
              throw const FormatException('Invalid requirement declaration.');
            }
            final id = contract(value['contract']);
            final min = value['min'] ?? 1;
            final max = value.containsKey('max') ? value['max'] : 1;
            if (min is! int ||
                min < 0 ||
                (max != null && (max is! int || max < min)) ||
                value['label'] is! String) {
              throw const FormatException(
                'Requirements need a label and valid min/max counts (max may be null).',
              );
            }
            requirements.add({
              'contract': id,
              'label': value['label'],
              'owner': title,
              'min': min,
              'max': max,
            });
          }
        } else {
          // Older annotated plugins may not yet publish advisory declarations.
          unknown.add(name);
        }
        for (final dependency
            in (manifest['dependencies'] as Map? ?? {}).entries) {
          final spec = dependency.value;
          // Platform packages cannot be user-selected plugin implementations.
          if ({'denial_sdk', 'denial_flutter_sdk'}.contains(dependency.key) ||
              (spec is Map && spec['sdk'] != null)) {
            continue;
          }
          if (spec is Map && spec['path'] is String) {
            dependencies.add(dependency.key as String);
            visit(
              dependency.key as String,
              p.normalize(p.join(directory, spec['path'] as String)),
            );
          } else {
            // Pub alone decides hosted/Git versions and their plugin closure.
            unknown.add(dependency.key as String);
          }
        }
      } catch (error) {
        if (error is FileSystemException) {
          unknown.add(name);
        } else {
          issues.add({
            'code': 'invalid_declaration',
            'title': 'Plugin information needs fixing',
            'message':
                '$name has invalid compatibility declarations. ${error.toString()}',
            'plugins': [name],
          });
        }
      } finally {
        (packages[name] as Map)['unknown'] = unknown.toList();
      }
    }

    for (final entry in roots.entries) {
      final value = entry.value as Map;
      final directory = value['directory'];
      if (directory is String) {
        visit(entry.key as String, directory);
      }
    }
    return packages;
  }

  void requireValid({Map<String, Object?>? selection}) {
    final result = check(selection: selection);
    final issues = result['issues']! as List;
    if (issues.isNotEmpty) {
      throw CompositionException((issues.first as Map)['message'] as String);
    }
  }
}
