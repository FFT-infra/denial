import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'model.dart';
import 'package_graph.dart';

const _sdkPackages = {'denial_sdk', 'denial_flutter_sdk'};

/// Enforce the same public SDK boundary for first- and third-party code.
/// This is architecture validation, not a security sandbox for trusted Dart.
void validateSdkBoundaries(PackageGraph graph) {
  if (graph.packages.containsKey('denial_dart_shell')) {
    throw const CompositionException(
      'denial_dart_shell is an application, not a plugin API. '
      'Depend on denial_sdk and denial_flutter_sdk instead.',
    );
  }
  final clients = {..._sdkPackages};
  var changed = true;
  while (changed) {
    changed = false;
    for (final package in graph.packages.values) {
      if (package.dependencies.any(clients.contains)) {
        changed = clients.add(package.name) || changed;
      }
    }
  }
  for (final name in clients) {
    final package = graph.packages[name];
    if (package == null) continue;
    final library = Directory(package.libraryRoot);
    if (!library.existsSync()) continue;
    for (final file in library.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      validateSdkImports(
        package: name,
        path: file.path,
        source: file.readAsStringSync(),
        sdkLibraryRoots: {
          for (final sdk in _sdkPackages)
            if (graph.packages[sdk] case final resolved?)
              sdk: resolved.libraryRoot,
        },
      );
    }
  }
}

void validateSdkImports({
  required String package,
  required String path,
  required String source,
  Map<String, String> sdkLibraryRoots = const {},
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final directive in unit.directives.whereType<UriBasedDirective>()) {
    final uris = [
      directive.uri.stringValue,
      if (directive is NamespaceDirective)
        for (final branch in directive.configurations) branch.uri.stringValue,
    ];
    for (final value in uris.whereType<String>()) {
      final uri = Uri.parse(value);
      if (uri.scheme == 'package') {
        final segments = uri.pathSegments;
        final owner = segments.first;
        if (owner == 'denial_dart_shell' ||
            (_sdkPackages.contains(owner) &&
                owner != package &&
                segments.length > 1 &&
                segments[1] == 'src')) {
          throw CompositionException(
            '$path imports unsupported API $value. Use a public SDK library.',
          );
        }
      } else if (uri.scheme.isEmpty || uri.scheme == 'file') {
        final target = p.normalize(
          File(path).absolute.uri.resolveUri(uri).toFilePath(),
        );
        for (final sdk in sdkLibraryRoots.entries) {
          if (sdk.key != package &&
              p.isWithin(p.join(sdk.value, 'src'), target)) {
            throw CompositionException(
              '$path reaches SDK internals through $value. '
              'Use a public SDK library.',
            );
          }
        }
      }
    }
  }
}
