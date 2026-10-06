import 'dart:convert';
import 'dart:io';

/// Installation-owned discovery only: no PATH search or user configuration.
/// Retain a resolved backend while the app's bundle is replaced underneath it.
class BackendInstallation {
  BackendInstallation({String Function()? applicationExecutable})
    : _applicationExecutable = applicationExecutable ?? _runningExecutable;

  final String Function() _applicationExecutable;
  String? _backend;

  static String _runningExecutable() {
    // /proc follows a renamed live executable. Dart may have cached its startup
    // pathname, which can temporarily disappear during an application update.
    try {
      return Link('/proc/self/exe').resolveSymbolicLinksSync();
    } on FileSystemException {
      return Platform.resolvedExecutable;
    }
  }

  String resolve() {
    final cached = _backend;
    if (cached != null && File(cached).existsSync()) return cached;
    final app = File(_applicationExecutable()).absolute;
    final beside = File.fromUri(
      app.parent.uri.resolve('denial-plugin-manager.installation.json'),
    );
    final stable = File.fromUri(
      app.parent.parent.uri.resolve('denial-plugin-manager.installation.json'),
    );
    for (final file in [beside, stable]) {
      try {
        final value = jsonDecode(file.readAsStringSync());
        if (value is! Map || value['schema'] != 1) continue;
        final backend = value['backend'];
        if (backend is! String || backend.isEmpty) continue;
        // Only development builds install this stable parent descriptor. Its
        // explicit marker and absolute path distinguish it from bundle sidecars
        // with relative paths, including old descriptors from earlier builds.
        if (file.path == stable.path &&
            (value['application'] != 'denial-plugin-manager' ||
                !backend.startsWith('/'))) {
          continue;
        }
        final resolved = File.fromUri(
          file.parent.uri.resolveUri(Uri.file(backend)),
        ).path;
        if (File(resolved).existsSync()) return _backend = resolved;
      } on FileSystemException {
        // A publication window is recoverable on the next status poll.
      } on FormatException {
        // Try the independent installed descriptor if this copy is incomplete.
      }
    }
    throw const PluginToolsUnavailable();
  }
}

class PluginToolsUnavailable implements Exception {
  const PluginToolsUnavailable();
  @override
  String toString() =>
      'Plugin tools are temporarily unavailable. Retrying automatically.';
}
