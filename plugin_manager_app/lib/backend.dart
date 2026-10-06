import 'dart:convert';
import 'dart:io';

import 'backend_installation.dart';

/// The app owns no build process. Mutations are submitted to detached workers;
/// closing a window leaves their state and compilation intact.
class PluginBackend {
  PluginBackend({this.executableOverride, BackendInstallation? installation})
    : installation = installation ?? BackendInstallation();
  final String? executableOverride;
  final BackendInstallation installation;
  bool _bootstrapped = false;

  String get executable => executableOverride ?? installation.resolve();

  Future<Object?> invoke(List<String> arguments) async {
    late final ProcessResult process;
    try {
      process = await Process.run(executable, arguments);
    } on ProcessException {
      _bootstrapped = false;
      throw const PluginToolsUnavailable();
    } on PluginToolsUnavailable {
      _bootstrapped = false;
      rethrow;
    }
    if (process.exitCode != 0) {
      throw Exception((process.stderr as String).trim());
    }
    return jsonDecode(process.stdout as String);
  }

  Future<Map<String, Object?>> status() async {
    // Bootstrap is idempotent; only retry reads/setup, never an Apply request.
    if (!_bootstrapped) {
      await invoke(['bootstrap']);
      _bootstrapped = true;
    }
    return (await invoke(['--brief', 'status']))! as Map<String, Object?>;
  }

  Future<Map<String, Object?>> catalog() async =>
      (await invoke(['catalog']))! as Map<String, Object?>;
  Future<String> submit(List<String> operation) async {
    final result = object(await invoke(['submit', ...operation]));
    return result['job']! as String;
  }
}

Map<String, Object?> object(Object? value) =>
    value is Map<String, Object?> ? value : {};
List<Map<String, Object?>> objects(Object? value) =>
    value is List ? value.whereType<Map<String, Object?>>().toList() : [];
