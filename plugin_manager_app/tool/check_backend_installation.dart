import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager_app/backend.dart';
import 'package:denial_plugin_manager_app/backend_installation.dart';

Future<void> main() async {
  void check(String name, bool result) {
    if (!result) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  final root = Directory.systemTemp.createTempSync('denial-backend-');
  try {
    var bundle = Directory('${root.path}/bundle')..createSync();
    final backend = File('${root.path}/tools/backend #1')
      ..parent.createSync()
      ..writeAsStringSync('fixture');
    var beside = File('${bundle.path}/denial-plugin-manager.installation.json');
    beside.writeAsStringSync(
      jsonEncode({'schema': 1, 'backend': '../tools/backend #1'}),
    );
    final installation = BackendInstallation(
      applicationExecutable: () => '${bundle.path}/denial-plugin-manager',
    );
    check(
      'packaged relative paths are resolved literally',
      installation.resolve() == backend.path,
    );
    beside.deleteSync();
    check(
      'running app retains backend during bundle replacement',
      installation.resolve() == backend.path,
    );

    final stable = File('${root.path}/denial-plugin-manager.installation.json');
    stable.writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'application': 'denial-plugin-manager',
        'backend': backend.path,
      }),
    );
    BackendInstallation fresh() => BackendInstallation(
      applicationExecutable: () => '${bundle.path}/denial-plugin-manager',
    );
    check(
      'fresh process recovers through installed stable descriptor',
      fresh().resolve() == backend.path,
    );
    bundle = bundle.renameSync('${root.path}/bundle-retained');
    check(
      'retained executable still finds stable installation',
      fresh().resolve() == backend.path,
    );
    beside = File('${bundle.path}/denial-plugin-manager.installation.json')
      ..writeAsStringSync('{');
    check(
      'incomplete sidecar recovers through independent descriptor',
      fresh().resolve() == backend.path,
    );

    stable.writeAsStringSync(
      jsonEncode({'schema': 1, 'backend': backend.path}),
    );
    final unavailable = fresh();
    try {
      unavailable.resolve();
      throw StateError('Unmarked parent descriptor was accepted');
    } on PluginToolsUnavailable catch (error) {
      check(
        'genuine missing installation gives a readable retry message',
        !error.toString().contains('FormatException') &&
            error.toString().contains('Retrying'),
      );
    }
    stable.writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'application': 'denial-plugin-manager',
        'backend': backend.path,
      }),
    );
    check(
      'same instance recovers after installation repair',
      unavailable.resolve() == backend.path,
    );
    backend.deleteSync();
    try {
      installation.resolve();
      throw StateError('Missing cached backend was accepted');
    } on PluginToolsUnavailable {
      check('cached executable must still exist', true);
    }
  } finally {
    root.deleteSync(recursive: true);
  }

  final backend = _RecoveringBackend();
  try {
    await backend.status();
    throw StateError('Expected initial missing backend');
  } on PluginToolsUnavailable {
    check('temporary setup failure remains retryable', true);
  }
  check(
    'next status retries bootstrap automatically',
    (await backend.status())['ready'] == true && backend.bootstrapCalls == 2,
  );
  await backend.status();
  check(
    'healthy polling does not repeatedly bootstrap',
    backend.bootstrapCalls == 2,
  );
  check(
    'recovery never submits an Apply request',
    !backend.commands.any(
      (command) => command.contains('apply') || command.contains('submit'),
    ),
  );
}

class _RecoveringBackend extends PluginBackend {
  int bootstrapCalls = 0;
  final commands = <List<String>>[];
  @override
  Future<Object?> invoke(List<String> arguments) async {
    commands.add(arguments);
    if (arguments.singleOrNull == 'bootstrap') {
      bootstrapCalls++;
      if (bootstrapCalls == 1) throw const PluginToolsUnavailable();
      return {'ready': true};
    }
    return {'ready': true};
  }
}
