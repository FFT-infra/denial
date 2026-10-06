import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;

final parser = ArgParser()
  ..addOption('state', help: 'Internal manager state directory')
  ..addOption(
    'draft',
    help: 'Internal selection draft JSON, committed by Apply',
  )
  ..addOption('ref', help: 'Git branch, tag, or commit')
  ..addOption(
    'path',
    defaultsTo: '.',
    help: 'Package path within the repository',
  )
  ..addFlag('local', negatable: false)
  ..addFlag('builtin', negatable: false)
  ..addFlag('update', negatable: false)
  ..addFlag(
    'now',
    negatable: false,
    help: 'Rebuild: switch as soon as it is built, without waiting for a pause',
  )
  ..addFlag('brief', negatable: false, help: 'Compact status for app polling')
  ..addFlag('help', negatable: false);

Future<void> main(List<String> arguments) async {
  try {
    final options = parser.parse(arguments);
    if (options.flag('help') || options.rest.isEmpty) {
      stdout.writeln(
        'Denial Plugin Manager\n\nCommands: status, bootstrap, initialize, prepare, catalog, refresh-catalog, defaults, inspect SOURCE, add SOURCE, enable PACKAGE, remove PACKAGE, plan, build ID, activate ID, apply, update, rebuild, rebuild-now, resume, revert, restore, discover WORKSPACE, submit COMMAND...\n${parser.usage}',
      );
      return;
    }
    final store = ManagerStore(
      options.option('state') == null
          ? ManagerStore.defaultRoot()
          : Directory(options.option('state')!).absolute,
    );
    final repositories = SourceRepository(
      Directory(p.join(store.root.path, 'repositories')),
    );
    final settings = PluginCatalog.configuration(
      store.read('configuration.json'),
    );
    final available = AvailablePlugins(store, repositories);
    String? setting(String key) => settings[key] as String?;
    final installation = PluginInstallation.discover();
    final kit = BuildKit(store, source: Directory(installation.buildKit));
    final activation = CompositionActivation(
      store,
      denialctl: installation.denialctl,
    );
    Future<void> initialize() async {
      settings
        ..clear()
        ..addAll(await kit.initialize(progress: stderr.writeln));
    }

    Object? result;
    switch (options.rest) {
      case ['submit', ...final operation]:
        final forwarded = <String>[...operation];
        for (final option in ['ref', 'path', 'draft']) {
          if (options.wasParsed(option)) {
            forwarded.addAll(['--$option', options.option(option)!]);
          }
        }
        for (final flag in ['local', 'builtin', 'update', 'now']) {
          if (options.wasParsed(flag)) {
            forwarded.add(options.flag(flag) ? '--$flag' : '--no-$flag');
          }
        }
        result = {'job': await JobWorker(store).submit(forwarded)};
      case ['worker', final id]:
        await JobWorker(store).run(id, (argv) async {
          // Same CLI/backend operation in a process independent of the GUI.
          final packageConfig = Platform.executableArguments
              .where((a) => a.startsWith('--packages='))
              .toList();
          final command = <String>[
            if (Platform.script.path.endsWith('.dart')) ...[
              ...packageConfig,
              Platform.script.toFilePath(),
            ],
            '--state',
            store.root.path,
            ...argv,
          ];
          final process = await Process.start(
            Platform.resolvedExecutable,
            command,
          );
          final output = StringBuffer();
          final errorLines = <String>[];
          Map<String, Object?>? lastProgress;
          final stdoutDone = process.stdout
              .transform(utf8.decoder)
              .listen(output.write)
              .asFuture<void>();
          final stderrDone = process.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                errorLines.add(line);
                if (errorLines.length > 200) errorLines.removeAt(0);
                if (line.trim().isNotEmpty) {
                  final progress = jobProgress(argv.first, line);
                  if (progress != null) {
                    final samePhase =
                        lastProgress?['label'] == progress['label'] &&
                        lastProgress?['completed'] == progress['completed'];
                    progress['started'] = samePhase
                        ? lastProgress!['started']
                        : DateTime.now().toUtc().toIso8601String();
                    lastProgress = progress;
                  }
                  store.updateJob(id, {'message': line, 'progress': ?progress});
                }
                store
                    .file('jobs/$id.progress.log')
                    .writeAsStringSync('$line\n', mode: FileMode.append);
              })
              .asFuture<void>();
          final code = await process.exitCode;
          await Future.wait([stdoutDone, stderrDone]);
          if (code != 0) {
            throw CompositionException(operationFailure(errorLines, code));
          }
          return jsonDecode(output.toString());
        });
        return;
      case ['bootstrap']:
        if (kit.ready &&
            store.read('initialization.json')['complete'] == true) {
          result = {'ready': true};
        } else {
          final pending = store.jobs().where(
            (job) =>
                job['operation'] == 'initialize' &&
                {'queued', 'running'}.contains(job['phase']),
          );
          if (pending.isNotEmpty) {
            result = {'job': pending.first['id']};
          } else {
            result = await store.exclusive(() async {
              if (kit.ready &&
                  store.read('initialization.json')['complete'] == true) {
                return {'ready': true};
              }
              final pending = store.jobs().where(
                (job) =>
                    job['operation'] == 'initialize' &&
                    {'queued', 'running'}.contains(job['phase']),
              );
              return {
                'job': pending.isNotEmpty
                    ? pending.first['id']
                    : await JobWorker(store).submit(['initialize']),
              };
            });
          }
        }
      case ['job-details', final id]:
        ManagerStore.validateId(id);
        final log = store.file('jobs/$id.progress.log');
        result = {
          'job': store.read('jobs/$id.json'),
          'log': log.existsSync() ? log.readAsStringSync() : '',
        };
      case ['catalog']:
        result = await available.list(settings);
      case ['status']:
        final native = await activation.status();
        final jobs = store.jobs();
        final selection = store.selection;
        final last = store.read('last-plan.json');
        final installed = store.read(
          'installed.json',
          fallback: {'plugins': selection['roots']},
        );
        final declarations = SelectionPreflight(store).describe({
          ...installed['plugins']! as Map,
          ...selection['roots']! as Map,
        });
        result = {
          'plan': last['id'] is String
              ? store.read('candidates/${last['id']}/plan.json')
              : <String, Object?>{},
          'build': last['id'] is String
              ? store.read('candidates/${last['id']}/build.json')
              : <String, Object?>{},
          'native': native,
          'configuration': settings,
          'buildKitAvailable': kit.available,
          'dart': kit.dartStatus,
          'ready':
              kit.ready &&
              store.read('initialization.json')['complete'] == true,
          'selection': selection,
          'declarations': declarations,
          'preflight': SelectionPreflight(store).check(selection: selection),
          'installed': store.read(
            'installed.json',
            fallback: {'plugins': store.selection['roots']},
          ),
          'lastPlan': store.read('last-plan.json'),
          'active': store.read('active.json'),
          'jobs': jobs,
        };
        if (options.flag('brief')) {
          final summary = result as Map<String, Object?>;
          summary['plan'] = {
            for (final entry
                in (summary['plan'] as Map<String, Object?>).entries)
              if ({
                'id',
                'roots',
                'discovery',
                'status',
                'selectionRevision',
              }.contains(entry.key))
                entry.key: entry.value,
          };
          // The app needs activation identity to distinguish a pending
          // selection from a built composition already running on the desktop.
          summary['build'] = {
            for (final entry
                in (summary['build'] as Map<String, Object?>).entries)
              if ({'status', 'bundle', 'reusedFrom'}.contains(entry.key))
                entry.key: entry.value,
          };
          summary['jobs'] = [
            for (final job in (summary['jobs']! as List<Map<String, Object?>>))
              if (((job['arguments'] as Map?)?.containsKey('argv') ?? false) ||
                  job['phase'] == 'running' ||
                  job['phase'] == 'queued')
                {
                  for (final entry in job.entries)
                    if (entry.key != 'result') entry.key: entry.value,
                },
          ];
        }
      case ['rebuild']:
        result = await rebuild(
          store: store,
          repositories: repositories,
          activation: activation,
          initialize: () async {
            await initialize();
            return settings;
          },
          now: options.flag('now'),
        );
      case ['resume']:
        await resume(store, activation, kit);
        return;
      case ['rebuild-now']:
        // Not a mutation: a waiting rebuild owns the switch and its checks.
        store.root.createSync(recursive: true);
        switchNowRequest(store).writeAsStringSync('');
        result = {'requested': true};
      case ['discover', final workspace]:
        await store.exclusive(initialize);
        final flutter = setting('flutter')!;
        result = (await PluginDiscovery(
          sdkPath: p.join(
            p.dirname(File(flutter).resolveSymbolicLinksSync()),
            'cache/dart-sdk',
          ),
          cacheDirectory: store.file('cache/analyzer').path,
        ).discover(PackageGraph.read(p.absolute(workspace)))).toJson();
      default:
        result = await store.exclusive(() async {
          await initialize();
          PluginSource source(String location) => PluginSource(
            kind: options.flag('local')
                ? SourceKind.local
                : options.flag('builtin')
                ? SourceKind.builtin
                : SourceKind.git,
            location: location,
            path: options.option('path')!,
            ref: options.option('ref'),
          );
          switch (options.rest) {
            case ['initialize'] || ['prepare']:
              return settings;
            case ['defaults']:
              await available.defaults(setting('runtime'));
              return store.selection;
            case ['refresh-catalog']:
              return available.refresh(settings);
            case ['activate', final id]:
              stderr.writeln('Applying your desktop');
              return activation.activate(id);
            case ['restore']:
              stderr.writeln('Applying your desktop');
              return activation.restore();
            case ['revert']:
              stderr.writeln('Applying your desktop');
              return activation.revert();
            case ['inspect', final location]:
              return repositories.inspect(source(location));
            case ['add', final location]:
              final plugin = await repositories.resolve(source(location));
              store.select(plugin);
              return plugin.toJson();
            case ['enable', final name]:
              final installed = store.read('installed.json')['plugins'] as Map?;
              final value = installed?[name] as Map<String, Object?>?;
              if (value == null) {
                throw CompositionException('Plugin $name is not installed');
              }
              final retained = PluginSource.fromJson(
                value['source']! as Map<String, Object?>,
              );
              final plugin = await repositories.resolve(
                retained,
                pinnedRevision: retained.kind == SourceKind.git
                    ? value['revision'] as String?
                    : null,
              );
              store.select(plugin);
              return plugin.toJson();
            case ['remove', final package]:
              store.remove(package);
              return store.selection;
            case ['build', final id]:
              final engineRoot = setting('engine-root');
              if (engineRoot == null) {
                throw const CompositionException(
                  'Installed release compiler is incomplete',
                );
              }
              return CompositionBuilder(store).build(
                id,
                engineRoot: p.absolute(engineRoot),
                engineTarget: setting('engine-target')!,
                platform: setting('platform')!,
                progress: stderr.writeln,
              );
            case ['plan'] || ['apply'] || ['update']:
              final runtime = setting('runtime');
              final flutter = setting('flutter');
              if (runtime == null || flutter == null) {
                throw const CompositionException(
                  'Installed source and release compiler are incomplete',
                );
              }
              if (options.option('draft') case final String draft) {
                if (options.rest.single != 'apply' &&
                    options.rest.single != 'update') {
                  throw const CompositionException(
                    'Only Apply can commit a selection draft.',
                  );
                }
                await activation.requireSupport();
                await commitSelectionDraft(
                  store,
                  repositories,
                  jsonDecode(draft) as Map<String, Object?>,
                );
              }
              SelectionPreflight(store).requireValid();
              if (options.rest.single != 'plan') {
                await activation.requireSupport();
              }
              final id = store.createJob('plan', {
                'runtime': runtime,
                'flutter': flutter,
              });
              store.updateJob(id, {'phase': 'running', 'pid': pid});
              try {
                final result =
                    await WorkspacePlanner(
                      store: store,
                      repository: repositories,
                    ).plan(
                      runtimeRoot: p.absolute(runtime),
                      flutter: p.absolute(flutter),
                      candidateId: id,
                      update:
                          options.flag('update') ||
                          options.rest.single == 'update',
                      sdkRoot: Platform.environment['DENIAL_SDK_PATH'],
                      progress: (phase) {
                        stderr.writeln(phase);
                        store.updateJob(id, {'message': phase});
                      },
                    );
                if (options.rest.single != 'plan') {
                  final engineRoot = setting('engine-root');
                  if (engineRoot == null) {
                    throw const CompositionException(
                      'Installed release compiler is incomplete',
                    );
                  }
                  await CompositionBuilder(store).build(
                    id,
                    engineRoot: p.absolute(engineRoot),
                    engineTarget: setting('engine-target')!,
                    platform: setting('platform')!,
                    progress: stderr.writeln,
                  );
                  stderr.writeln('Applying your desktop');
                  await activation.activate(id);
                }
                store.updateJob(id, {'phase': 'succeeded', 'candidate': id});
                return result;
              } catch (error) {
                store.updateJob(id, {'phase': 'failed', 'error': '$error'});
                rethrow;
              }
            default:
              throw const CompositionException('Unknown command; use --help');
          }
        });
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } catch (error) {
    stderr.writeln('denial-plugins: $error');
    exitCode = 1;
  }
}

/// Rebuilds the composition deniald was running before Denial was updated
/// (PLUGIN_MANAGER.md section 21). The manager lock is released while waiting
/// for a quiet moment, so Plugins stays usable.
Future<Map<String, Object?>> rebuild({
  required ManagerStore store,
  required SourceRepository repositories,
  required CompositionActivation activation,
  required Future<Map<String, Object?>> Function() initialize,
  required bool now,
}) async {
  final built = await store.exclusive(() async {
    // Only a request made while this rebuild waits may skip the wait.
    final request = switchNowRequest(store);
    if (request.existsSync()) request.deleteSync();
    final settings = await initialize();
    final target = RebuildTarget.fromNative(store, await activation.status());
    if (target == null) return null;
    final runtime = settings['runtime'] as String?;
    final flutter = settings['flutter'] as String?;
    final engineRoot = settings['engine-root'] as String?;
    if (runtime == null || flutter == null || engineRoot == null) {
      throw const CompositionException(
        'Installed source and release compiler are incomplete',
      );
    }
    requireMatchingBuildKit(runtime, target);
    await activation.requireSupport();
    final id = store.createJob('plan', {
      'runtime': runtime,
      'flutter': flutter,
      'rebuildOf': target.candidate,
    });
    store.updateJob(id, {'phase': 'running', 'pid': pid});
    try {
      await WorkspacePlanner(store: store, repository: repositories).plan(
        runtimeRoot: p.absolute(runtime),
        flutter: p.absolute(flutter),
        candidateId: id,
        rebuildOf: target.candidate,
        sdkRoot: Platform.environment['DENIAL_SDK_PATH'],
        progress: (phase) {
          stderr.writeln(phase);
          store.updateJob(id, {'message': phase});
        },
      );
      await CompositionBuilder(store).build(
        id,
        engineRoot: p.absolute(engineRoot),
        engineTarget: settings['engine-target']! as String,
        platform: settings['platform']! as String,
        progress: stderr.writeln,
      );
      store.updateJob(id, {'phase': 'succeeded', 'candidate': id});
    } catch (error) {
      store.updateJob(id, {'phase': 'failed', 'error': '$error'});
      rethrow;
    }
    return (candidate: id, base: target.candidate);
  });
  if (built == null) return {'rebuilt': false, 'switched': false};
  final (:candidate, :base) = built;
  final unchanged = {
    'rebuilt': true,
    'switched': false,
    'candidate': candidate,
  };
  if (!now &&
      !await waitForQuietMoment(
        store,
        activation.status,
        base,
        progress: stderr.writeln,
      )) {
    return unchanged;
  }
  return store.exclusive(() async {
    final request = switchNowRequest(store);
    if (request.existsSync()) request.deleteSync();
    if (!waitsForRebuildOf(store, await activation.status(), base)) {
      return unchanged;
    }
    stderr.writeln('Applying your desktop');
    return {
      ...unchanged,
      'switched': true,
      'native': await activation.activate(candidate),
    };
  }, wait: const Duration(minutes: 2));
}

/// Started by deniald after an update left its plugins behind. It submits the
/// rebuild and keeps one notification about it until nothing is left to do.
Future<void> resume(
  ManagerStore store,
  CompositionActivation activation,
  BuildKit kit,
) async {
  store.root.createSync(recursive: true);
  final lock = await store.file('resume.lock').open(mode: FileMode.append);
  try {
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      return; // Another resume already keeps the user informed.
    }
    final Notifier notifier;
    try {
      notifier = await DesktopNotifications.connect();
    } catch (error) {
      // Without notifications the rebuild still runs; Plugins shows it.
      stderr.writeln('denial-plugins: notifications are unavailable: $error');
      if (RebuildTarget.fromNative(store, await activation.status()) != null) {
        await JobWorker(store).submit(['rebuild']);
      }
      return;
    }
    final plugins = desktopEntryCommand('dev.denial.PluginManager.desktop');
    try {
      await PluginResume(
        store: store,
        status: activation.status,
        submit: JobWorker(store).submit,
        notifier: notifier,
        kitIdentity: kit.available ? kit.identity : null,
        openPlugins: plugins == null
            ? null
            : (token) => launchDetached(plugins, activationToken: token),
        openUrl: (url, token) =>
            launchDetached(['xdg-open', url], activationToken: token),
        online: networkConnected,
      ).run();
    } finally {
      await notifier.dispose();
    }
  } finally {
    await lock.close();
  }
}
