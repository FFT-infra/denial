import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';

/// Build/packaging-owned metadata, located beside the actual executable.
/// Users never configure these paths, and PATH is not an installation authority.
final class PluginInstallation {
  const PluginInstallation({required this.buildKit, required this.denialctl});

  factory PluginInstallation.discover({String? executable}) {
    final file = File(
      p.join(
        p.dirname(executable ?? Platform.resolvedExecutable),
        'denial-plugins.installation.json',
      ),
    );
    if (!file.existsSync()) {
      throw const CompositionException(
        'Denial plugin tools are incomplete. Update or repair the Denial installation.',
      );
    }
    final value = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    if (value['schema'] != 1) {
      throw const CompositionException(
        'Unsupported Denial plugin installation metadata',
      );
    }
    String resolve(String key) {
      final path = value[key];
      if (path is! String || path.isEmpty) {
        throw CompositionException(
          'Incomplete Denial plugin installation: $key',
        );
      }
      return p.normalize(p.join(file.parent.path, path));
    }

    return PluginInstallation(
      buildKit: resolve('buildKit'),
      denialctl: resolve('denialctl'),
    );
  }

  final String buildKit;
  final String denialctl;
}
