import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model.dart';
import 'package_graph.dart';

enum SourceKind { git, builtin, local }

/// User intent, distinct from the immutable resolution used in a plan.
final class PluginSource {
  PluginSource({
    required this.kind,
    required this.location,
    this.path = '.',
    this.ref,
  }) {
    if (location.isEmpty ||
        location.contains('\u0000') ||
        location.startsWith('-')) {
      throw const CompositionException('Invalid plugin source');
    }
    if (p.posix.isAbsolute(path) ||
        path.contains('\\') ||
        p.posix.split(path).contains('..')) {
      throw const CompositionException(
        'Package path must stay inside its repository',
      );
    }
    if (ref != null &&
        (ref!.isEmpty || ref!.startsWith('-') || ref!.contains('\u0000'))) {
      throw const CompositionException('Invalid Git ref');
    }
  }
  factory PluginSource.fromJson(Map<String, Object?> value) => PluginSource(
    kind: SourceKind.values.byName(value['kind']! as String),
    location: value['location']! as String,
    path: value['path'] as String? ?? '.',
    ref: value['ref'] as String?,
  );
  final SourceKind kind;
  final String location;
  final String path;
  final String? ref;
  String get identity =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'location': location,
    'path': path,
    if (ref != null) 'ref': ref,
  };
}

final class ResolvedSource {
  const ResolvedSource({
    required this.source,
    required this.name,
    required this.directory,
    required this.revision,
    required this.description,
  });
  final PluginSource source;
  final String name;
  final String directory;
  final String revision;
  final String description;
  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    'name': name,
    'directory': directory,
    'revision': revision,
    'description': description,
  };
}

typedef CommandRunner = Future<String> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  void Function(String line)? onOutput,
});

Future<String> runCommand(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  void Function(String line)? onOutput,
}) async {
  if (onOutput != null) {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    final output = StringBuffer();
    final errors = StringBuffer();
    Future<void> consume(Stream<List<int>> stream, StringBuffer buffer) async {
      await for (final line
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        buffer.writeln(line);
        onOutput(line);
      }
    }

    // Drain both pipes concurrently; otherwise a verbose compiler can block on
    // a full stderr pipe while its stdout is being consumed.
    final drained = Future.wait([
      consume(process.stdout, output),
      consume(process.stderr, errors),
    ]);
    final code = await process.exitCode;
    await drained;
    if (code != 0) {
      throw CompositionException(
        '$executable failed ($code):\n$errors\n$output',
      );
    }
    return output.toString();
  }
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: {'GIT_TERMINAL_PROMPT': '0'},
  );
  if (result.exitCode != 0) {
    throw CompositionException(
      '$executable failed (${result.exitCode}):\n${result.stderr}\n${result.stdout}',
    );
  }
  return result.stdout as String;
}

/// Fetches repository bytes only. Hooks, build scripts, and Dart entry points
/// are not invoked to inspect metadata. Pub remains the dependency resolver.
final class SourceRepository {
  SourceRepository(this.cache, {this.run = runCommand});
  final Directory cache;
  final CommandRunner run;

  Future<(String, String)> checkout(
    PluginSource source, {
    String? pinnedRevision,
  }) async {
    if (source.kind != SourceKind.git) {
      final directory = Directory(source.location).absolute
          .resolveSymbolicLinksSync();
      return (directory, pinnedRevision ?? 'local');
    }
    if (pinnedRevision != null &&
        !RegExp(r'^[a-f0-9]{40,64}$').hasMatch(pinnedRevision)) {
      throw const CompositionException(
        'Git resolution must be a full commit identity',
      );
    }
    cache.createSync(recursive: true);
    final urlKey = sha256.convert(utf8.encode(source.location)).toString();
    final mirror = p.join(cache.path, '$urlKey.git');
    if (!Directory(mirror).existsSync()) {
      final staging = cache.createTempSync('.mirror-');
      try {
        await run('git', [
          'clone',
          '--bare',
          '--',
          source.location,
          staging.path,
        ]);
        staging.renameSync(mirror);
      } finally {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
    } else if (pinnedRevision == null) {
      await run('git', [
        '-C',
        mirror,
        'fetch',
        '--prune',
        'origin',
        '+refs/heads/*:refs/heads/*',
        '+refs/tags/*:refs/tags/*',
      ]);
    }
    String revision;
    if (pinnedRevision != null) {
      revision = pinnedRevision;
    } else {
      var requested = source.ref;
      if (requested == null) {
        // Refresh remote HEAD explicitly: bare clone's HEAD can be stale when
        // upstream changes its default branch.
        final head = await run('git', [
          'ls-remote',
          '--symref',
          '--',
          source.location,
          'HEAD',
        ]);
        final match = RegExp(
          r'^([a-f0-9]{40,64})\s+HEAD$',
          multiLine: true,
        ).firstMatch(head);
        if (match == null) {
          throw const CompositionException(
            'Repository has no default-branch commit',
          );
        }
        requested = match.group(1)!;
      }
      revision = (await run('git', [
        '-C',
        mirror,
        'rev-parse',
        '--verify',
        '--end-of-options',
        '$requested^{commit}',
      ])).trim();
    }
    if (!RegExp(r'^[a-f0-9]{40,64}$').hasMatch(revision)) {
      throw const CompositionException(
        'Git did not return a full commit identity',
      );
    }
    final destination = p.join(cache.path, '$urlKey-$revision');
    if (!Directory(destination).existsSync()) {
      // Publish only a completed checkout, on the cache filesystem. A failed
      // checkout must not leave a directory that a later attempt treats as ready.
      final staging = cache.createTempSync('.checkout-');
      try {
        await run('git', [
          'clone',
          '--no-checkout',
          '--',
          mirror,
          staging.path,
        ]);
        await run('git', [
          '-C',
          staging.path,
          '-c',
          'core.hooksPath=/dev/null',
          'checkout',
          '--detach',
          revision,
        ]);
        staging.renameSync(destination);
      } finally {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
    }
    return (destination, revision);
  }

  Future<ResolvedSource> resolve(
    PluginSource source, {
    String? pinnedRevision,
  }) async {
    final (repository, revision) = await checkout(
      source,
      pinnedRevision: pinnedRevision,
    );
    final directory = Directory(p.join(repository, source.path))
        .resolveSymbolicLinksSync();
    if (directory != repository && !p.isWithin(repository, directory)) {
      throw const CompositionException(
        'Package symlink escapes its source repository',
      );
    }
    final pubspec = readYamlMap(File(p.join(directory, 'pubspec.yaml')));
    final name = pubspec['name'];
    if (name is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      throw const CompositionException('Invalid Dart package name');
    }
    return ResolvedSource(
      source: source,
      name: name,
      directory: directory,
      revision: revision,
      description: pubspec['description'] as String? ?? '',
    );
  }

  /// Return package candidates, not activations. Typed discovery during planning
  /// must confirm @Plugin identity before accepting a candidate as a plugin.
  Future<List<Map<String, Object?>>> inspect(PluginSource source) async {
    final (repository, revision) = await checkout(source);
    final result = <Map<String, Object?>>[];
    void visit(Directory directory) {
      final manifest = File(p.join(directory.path, 'pubspec.yaml'));
      if (manifest.existsSync()) {
        final pubspec = readYamlMap(manifest);
        final lib = Directory(p.join(directory.path, 'lib'));
        if (lib.existsSync()) {
          // Candidate inspection intentionally does not claim type validity.
          final candidate = lib
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .any(
                (f) =>
                    RegExp(r'@\w*[.]?Plugin\s*\(')
                        .hasMatch(f.readAsStringSync()),
              );
          if (candidate) {
            result.add({
              'name': pubspec['name'],
              'description': pubspec['description'] ?? '',
              'path': p.relative(directory.path, from: repository),
              'revision': revision,
            });
          }
        }
      }
      for (final child
          in directory.listSync(followLinks: false).whereType<Directory>()) {
        if ({
          '.git',
          '.dart_tool',
          'build',
          'test',
          'tests',
          'example',
          'examples',
        }.contains(p.basename(child.path))) {
          continue;
        }
        visit(child);
      }
    }

    final base = Directory(p.join(repository, source.path));
    final canonical = base.resolveSymbolicLinksSync();
    if (canonical != repository && !p.isWithin(repository, canonical)) {
      throw const CompositionException('Package path escapes repository');
    }
    visit(base);
    result.sort(
      (a, b) => (a['path']! as String).compareTo(b['path']! as String),
    );
    return result;
  }
}
