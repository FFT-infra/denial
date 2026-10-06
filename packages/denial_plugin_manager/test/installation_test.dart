import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('installation discovery survives relocation and ignores the working directory', () {
    final root = Directory.systemTemp.createTempSync('denial-installation-');
    try {
      final bin = Directory(p.join(root.path, 'bin'))..createSync();
      final metadata = File(
        p.join(bin.path, 'denial-plugins.installation.json'),
      );
      expect(
        () => PluginInstallation.discover(
          executable: p.join(bin.path, 'denial-plugins'),
        ),
        throwsA(isA<CompositionException>()),
      );
      metadata.writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'buildKit': '../lib/denial/plugin-build-kit',
          'denialctl': 'denialctl',
        }),
      );
      final installation = PluginInstallation.discover(
        executable: p.join(bin.path, 'denial-plugins'),
      );
      expect(
        installation.buildKit,
        p.join(root.path, 'lib/denial/plugin-build-kit'),
      );
      expect(installation.denialctl, p.join(bin.path, 'denialctl'));
      metadata.writeAsStringSync('{"schema":2}');
      expect(
        () => PluginInstallation.discover(
          executable: p.join(bin.path, 'denial-plugins'),
        ),
        throwsA(isA<CompositionException>()),
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
