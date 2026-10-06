import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

final class DartSdk {
  const DartSdk({
    required this.root,
    required this.executable,
    required this.version,
  });

  final String root;
  final String executable;
  final String version;

  static Map<String, Object?> status({
    required String expectedVersion,
    required String constraint,
    String? executable,
    Map<String, String>? environment,
  }) {
    try {
      final sdk = discover(
        expectedVersion: expectedVersion,
        constraint: constraint,
        executable: executable,
        environment: environment,
      );
      return {
        'available': true,
        'found': true,
        'expectedVersion': expectedVersion,
        'constraint': constraint,
        'version': sdk.version,
        'executable': sdk.executable,
      };
    } on DartSdkException catch (error) {
      return {
        'available': false,
        'found': error.found,
        'expectedVersion': expectedVersion,
        'constraint': constraint,
        if (error.version != null) 'version': error.version,
        'error': error.message,
      };
    }
  }

  static DartSdk discover({
    required String expectedVersion,
    required String constraint,
    String? executable,
    Map<String, String>? environment,
  }) {
    final command = executable ?? _onPath(environment ?? Platform.environment);
    if (command == null) {
      throw DartSdkException(
        'Dart $expectedVersion was not found in PATH. Install the dart package and try again.',
      );
    }
    final file = File(command);
    if (!file.existsSync()) {
      throw DartSdkException(
        'Dart $expectedVersion was not found in PATH. Install the dart package and try again.',
      );
    }
    late final String resolved;
    try {
      resolved = file.resolveSymbolicLinksSync();
    } on FileSystemException {
      throw DartSdkException(
        'The dart command in PATH could not be resolved. Reinstall Dart $expectedVersion and try again.',
        found: true,
      );
    }
    if (File(resolved).statSync().mode & 0x49 == 0) {
      throw DartSdkException(
        'The dart command in PATH is not executable. Reinstall the dart package and try again.',
        found: true,
      );
    }
    final roots = <String>{
      p.dirname(p.dirname(resolved)),
      p.dirname(p.dirname(file.absolute.path)),
    };
    for (final root in roots) {
      final versionFile = File(p.join(root, 'version'));
      if (!versionFile.existsSync()) continue;
      final version = versionFile.readAsStringSync().trim();
      late final bool compatible;
      try {
        compatible = VersionConstraint.parse(constraint)
            .allows(Version.parse(version));
      } on FormatException {
        throw DartSdkException(
          'The installed Dart SDK has an invalid version: $version.',
          found: true,
          version: version,
        );
      }
      if (!compatible) {
        throw DartSdkException(
          'Dart $version is installed, but Denial requires $constraint. Install a compatible dart package and try again.',
          found: true,
          version: version,
        );
      }
      for (final required in [
        'bin/dart',
        'bin/snapshots/frontend_server_aot.dart.snapshot',
        'lib/core/core.dart',
      ]) {
        if (!File(p.join(root, required)).existsSync()) {
          throw DartSdkException(
            'The Dart $expectedVersion SDK in PATH is incomplete. Reinstall the dart package and try again.',
            found: true,
            version: version,
          );
        }
      }
      return DartSdk(root: root, executable: resolved, version: version);
    }
    throw DartSdkException(
      'The dart command in PATH is not part of a complete Dart SDK. Install Dart $expectedVersion and try again.',
      found: true,
    );
  }

  static String? _onPath(Map<String, String> environment) {
    for (final directory in (environment['PATH'] ?? '').split(':')) {
      if (directory.isEmpty) continue;
      final candidate = File(p.join(directory, 'dart'));
      if (candidate.existsSync()) return candidate.absolute.path;
    }
    return null;
  }
}

final class DartSdkException implements Exception {
  const DartSdkException(this.message, {this.found = false, this.version});

  final bool found;
  final String? version;
  final String message;

  @override
  String toString() => message;
}
