import 'dart:async';

import 'model.dart';
import 'notifications.dart';
import 'rebuild.dart';
import 'store.dart';

/// Why a rebuild after a Denial update did not finish.
enum RebuildProblem {
  offline,
  busy,
  stopped,
  buildTools,
  missingBuiltin,

  /// The composition is not in this manager's history; only Apply helps.
  unavailable,
  plugins,
}

RebuildProblem classifyRebuildFailure(String error) {
  if (error.contains('Another plugin manager operation is running')) {
    return RebuildProblem.busy;
  }
  if (error.contains('worker exited') ||
      error.contains('stopped unexpectedly')) {
    return RebuildProblem.stopped;
  }
  if (error.contains('not built by this plugin manager') ||
      error.contains('can no longer be rebuilt')) {
    return RebuildProblem.unavailable;
  }
  if (error.contains(buildKitMismatch) ||
      error.contains('plugin build tools are missing') ||
      error.contains('build tools are missing') ||
      error.contains('Unsupported plugin build kit') ||
      error.contains('Build kit input changed')) {
    return RebuildProblem.buildTools;
  }
  if (error.contains('is not provided by this installed runtime')) {
    return RebuildProblem.missingBuiltin;
  }
  const offline = [
    'SocketException',
    'Failed host lookup',
    'Could not resolve host',
    'Could not resolve hostname',
    'Temporary failure in name resolution',
    'Network is unreachable',
    'Connection timed out',
    'Connection refused',
    'Connection reset',
    'HandshakeException',
    'ClientException',
    'Got socket error',
    'unable to access',
  ];
  if (offline.any(error.contains)) return RebuildProblem.offline;
  // The composition was confirmed before Denial changed. Anything else that
  // stops its rebuild almost always means a plugin needs an update.
  return RebuildProblem.plugins;
}

/// The words the user reads. They promise what the system guarantees: the
/// plugins and their settings are kept, and no logout is needed.
final class ResumeMessages {
  const ResumeMessages(this.version, {required this.hasGitPlugins});
  final String version;
  final bool hasGitPlugins;

  bool get release => isReleaseVersion(version);
  String get _denial => release ? 'Denial $version' : 'this Denial build';
  static const _kept = 'Your plugins and their settings are safe.';

  static const _openPlugins = ('open', 'Open Plugins');
  static const _tryAgain = ('retry', 'Try again');
  static const _checkForUpdates = ('update', 'Check for updates');

  List<(String, String)> _open(bool canOpen) => [
    if (canOpen) _openPlugins,
    if (canOpen) ('default', 'Open Plugins'),
  ];

  List<(String, String)> _recovery({
    required bool canOpen,
    bool retry = true,
    bool updates = true,
  }) => [
    if (retry) _tryAgain,
    if (updates && hasGitPlugins) _checkForUpdates,
    ..._open(canOpen),
  ];

  NotificationContent rebuilding({
    required bool canOpen,
  }) => NotificationContent(
    title: 'Bringing back your plugins',
    body:
        '${release ? 'Denial $version is installed' : 'Denial was updated'}. '
        "Your plugins and their settings are safe: they're being rebuilt in "
        'the background and will come back on their own. No need to log out.',
    actions: _open(canOpen),
    resident: true,
    persistent: true,
  );

  NotificationContent retrying({required bool canOpen}) => NotificationContent(
    title: 'Bringing back your plugins',
    body:
        'Trying again for $_denial. Your desktop switches back as soon as '
        "they're ready.",
    actions: _open(canOpen),
    resident: true,
    persistent: true,
  );

  NotificationContent updating({required bool canOpen}) => NotificationContent(
    title: 'Bringing back your plugins',
    body:
        'Looking for plugin updates for $_denial. Your desktop switches '
        "back as soon as they're ready.",
    actions: _open(canOpen),
    resident: true,
    persistent: true,
  );

  NotificationContent reconnected({required bool canOpen}) =>
      NotificationContent(
        title: 'Bringing back your plugins',
        body:
            "You're back online. Your plugins will come back on their own as "
            "soon as they're ready.",
        actions: _open(canOpen),
        resident: true,
        persistent: true,
      );

  NotificationContent restored() => NotificationContent(
    title: 'Your plugins are back',
    body: release
        ? 'Everything is as you left it, now on Denial $version. Thanks for '
              'waiting.'
        : 'Everything is as you left it. Thanks for waiting.',
    actions: [if (release) ('whats-new', "What's new")],
  );

  NotificationContent offline({required bool canOpen}) => NotificationContent(
    title: 'Your plugins are waiting for a connection',
    body:
        'Rebuilding them for $_denial needs a few downloads, and continues '
        "once you're online. $_kept",
    actions: _recovery(canOpen: canOpen, updates: false),
    resident: true,
    persistent: true,
  );

  NotificationContent failed(
    RebuildProblem problem, {
    required bool canOpen,
    String? plugin,
  }) => NotificationContent(
    title: "Your plugins couldn't be rebuilt",
    body:
        '${cause(problem, plugin: plugin)} Meanwhile, Denial uses its '
        'standard desktop. $_kept',
    actions: _recovery(
      canOpen: canOpen,
      retry: problem != RebuildProblem.unavailable,
      updates: problem == RebuildProblem.plugins,
    ),
    resident: true,
    persistent: true,
  );

  NotificationContent stillPaused({required bool canOpen}) =>
      NotificationContent(
        title: 'Your plugins are still paused',
        body:
            'Denial uses its standard desktop until your plugins are rebuilt '
            'for $_denial. $_kept',
        actions: _recovery(canOpen: canOpen),
        resident: true,
      );

  String cause(RebuildProblem problem, {String? plugin}) => switch (problem) {
    RebuildProblem.buildTools =>
      "The plugin build tools haven't been updated for $_denial yet. Finish "
          'updating the Denial Plugin Manager package, then try again.',
    RebuildProblem.missingBuiltin =>
      '${plugin ?? 'A built-in plugin'} is no longer included with $_denial. '
          'Choose what to use instead in Plugins.',
    RebuildProblem.unavailable =>
      "They can't be rebuilt automatically. Open Plugins and apply them "
          'again.',
    RebuildProblem.stopped ||
    RebuildProblem.offline => 'The rebuild stopped before it finished.',
    RebuildProblem.busy =>
      'Another plugin operation kept running, so the rebuild could not start.',
    RebuildProblem.plugins => 'One of them may need an update for $_denial.',
  };

  String get releaseNotes =>
      'https://github.com/denialwm/denial/releases/tag/v$version';
}

/// Keeps the user informed while a Denial update's plugin rebuild runs, in one
/// notification that changes only when the outcome does (PLUGIN_MANAGER.md
/// section 21). The rebuild itself is an ordinary detached job.
final class PluginResume {
  PluginResume({
    required this.store,
    required this.status,
    required this.submit,
    required this.notifier,
    this.kitIdentity,
    this.openPlugins,
    this.openUrl,
    this.online,
    this.tick = const Duration(seconds: 1),
    this.clock = DateTime.now,
  });

  final ManagerStore store;
  final Future<Map<String, Object?>> Function() status;
  final Future<String> Function(List<String>) submit;
  final Notifier notifier;

  /// The installed build kit; one automatic attempt is made per kit and
  /// composition.
  final String? kitIdentity;

  /// Present only when Plugins is installed and can be opened.
  final Future<void> Function(String? activationToken)? openPlugins;
  final Future<void> Function(String url, String? activationToken)? openUrl;
  final Future<bool?> Function()? online;
  final Duration tick;
  final DateTime Function() clock;

  static const _operations = {'rebuild', 'apply', 'update'};
  static const _offlineRetries = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  final _queue = <NotificationEvent>[];
  Completer<void>? _arrived;

  int _id = 0;
  bool _open = false;
  String? _job;
  List<String> _argv = const ['rebuild'];
  _State _state = _State.rebuilding;
  int _busyRetries = 0;
  int _offlineAttempts = 0;
  DateTime? _retryAt;
  bool? _wasOnline;
  int _unavailable = 0;
  DateTime _nextCheck = DateTime.fromMillisecondsSinceEpoch(0);
  late final ResumeMessages _messages;
  late final String _key;

  bool get _canOpen => openPlugins != null;

  /// Returns when nothing remains for the user to act on.
  Future<void> run() async {
    // deniald starts this before its event loop answers control requests.
    var native = await status();
    for (
      var attempt = 0;
      native['available'] == false && attempt < 60;
      attempt++
    ) {
      await Future<void>.delayed(tick);
      native = await status();
    }
    final waiting = native['plugin_rebuild'];
    if (waiting is! Map) return;
    RebuildTarget? target;
    String? unavailable;
    try {
      target = RebuildTarget.fromNative(store, native);
    } on CompositionException catch (error) {
      unavailable = error.message;
    }
    final plan = target == null
        ? const <String, Object?>{}
        : store.read('candidates/${target.candidate}/plan.json');
    _messages = ResumeMessages(
      waiting['version'] as String? ?? '',
      hasGitPlugins: (plan['roots'] as Map? ?? {}).values.any(
        (root) => root is Map && (root['source'] as Map?)?['kind'] == 'git',
      ),
    );
    _key = contentKey({'kit': kitIdentity, 'bundle': waiting['bundle']});
    final events = notifier.events.listen((event) {
      _queue.add(event);
      _arrived?.complete();
      _arrived = null;
    });
    try {
      if (unavailable != null) {
        await _showFailure(unavailable, RebuildProblem.unavailable);
        await _loop();
        return;
      }
      final ledger = store.read('resume.json');
      final running = store.jobs().where(
        (job) =>
            _operations.contains(job['operation']) &&
            (job['arguments'] as Map?)?['argv'] is List &&
            {'queued', 'running'}.contains(job['phase']),
      );
      if (running.isNotEmpty) {
        _job = running.first['id']! as String;
        _argv = ((running.first['arguments']! as Map)['argv']! as List)
            .cast<String>();
        await _show(_messages.rebuilding(canOpen: _canOpen));
      } else if (ledger['key'] == _key && ledger['outcome'] == 'failed') {
        // One automatic attempt per installed build kit and composition.
        _state = _State.failed;
        await _show(_messages.stillPaused(canOpen: _canOpen));
      } else {
        await _start(const ['rebuild']);
        await _show(_messages.rebuilding(canOpen: _canOpen));
      }
      await _loop();
    } finally {
      await events.cancel();
    }
  }

  Future<void> _start(List<String> argv) async {
    _argv = argv;
    _job = await submit(argv);
    _state = _State.rebuilding;
    _record('running');
  }

  void _record(String outcome) => store.write('resume.json', {
    'key': _key,
    'job': _job,
    'outcome': outcome,
    'updated': clock().toUtc().toIso8601String(),
  });

  Future<void> _show(NotificationContent content) async {
    _id = await notifier.show(content, replaces: _open ? _id : 0);
    _open = true;
  }

  Future<void> _loop() async {
    final started = clock();
    while (true) {
      final event = await _next();
      if (event != null) {
        if (event.id != _id) continue;
        if (event is NotificationClosed) {
          _open = false;
          // A dismissed progress notification still deserves its outcome.
          if (_state != _State.rebuilding) return;
          continue;
        }
        await _act(event as NotificationActionInvoked);
        continue;
      }
      switch (_state) {
        case _State.rebuilding:
          await _observeJob();
        case _State.failed || _State.offline:
          // Asking deniald spawns a process; a few seconds' delay is fine.
          final now = clock();
          if (now.isBefore(_nextCheck)) continue;
          _nextCheck = now.add(tick * 10);
          if (await _resolvedElsewhere()) return;
          if (_state == _State.offline) await _maybeRetryOnline();
        case _State.restored:
          // The confirmation expires by itself; never linger without it.
          if (!_open ||
              clock().difference(started) > const Duration(hours: 1)) {
            return;
          }
      }
    }
  }

  Future<NotificationEvent?> _next() async {
    if (_queue.isEmpty) {
      final arrived = _arrived = Completer<void>();
      await arrived.future.timeout(tick, onTimeout: () {});
    }
    return _queue.isEmpty ? null : _queue.removeAt(0);
  }

  Future<void> _act(NotificationActionInvoked action) async {
    switch (action.key) {
      case 'open' || 'default':
        await openPlugins?.call(action.activationToken);
      case 'whats-new':
        await openUrl?.call(_messages.releaseNotes, action.activationToken);
      case 'retry' when _state != _State.rebuilding:
        await _start(const ['rebuild', '--now']);
        await _show(_messages.retrying(canOpen: _canOpen));
      case 'update' when _state != _State.rebuilding:
        await _start(const ['update']);
        await _show(_messages.updating(canOpen: _canOpen));
    }
  }

  Future<void> _observeJob() async {
    final job = store.job(_job!);
    if ({'queued', 'running'}.contains(job['phase'])) return;
    final native = await status();
    final waiting = native['plugin_rebuild'] is Map;
    if (!waiting) {
      if (native['active_mode'] == 'custom_optimized' &&
          native['plugin_healthy'] == true) {
        _record('succeeded');
        _state = _State.restored;
        await _show(_messages.restored());
      } else {
        // The user chose the standard desktop meanwhile; respect it quietly.
        _record('superseded');
        if (_open) await notifier.close(_id);
        _state = _State.restored;
        _open = false;
      }
      return;
    }
    final error = job['phase'] == 'succeeded'
        ? 'The rebuilt plugins were not switched on'
        : '${job['error'] ?? 'The rebuild stopped unexpectedly'}';
    final problem = classifyRebuildFailure(error);
    if (problem == RebuildProblem.busy && _busyRetries++ < 3) {
      await Future<void>.delayed(tick * 5);
      await _start(_argv);
      return;
    }
    if (problem == RebuildProblem.offline) {
      _record('offline');
      _state = _State.offline;
      _offlineAttempts++;
      _retryAt = _offlineAttempts <= _offlineRetries.length
          ? clock().add(_offlineRetries[_offlineAttempts - 1])
          : null;
      _wasOnline = await online?.call();
      await _show(_messages.offline(canOpen: _canOpen));
      return;
    }
    await _showFailure(error, problem);
  }

  Future<void> _showFailure(String error, RebuildProblem problem) async {
    _record('failed');
    _state = _State.failed;
    final plugin = RegExp(
      r'^(\S+) is not provided by this installed runtime',
      multiLine: true,
    ).firstMatch(error)?.group(1);
    await _show(_messages.failed(problem, canOpen: _canOpen, plugin: plugin));
  }

  /// The user may have fixed it in Plugins, or chosen the standard desktop.
  /// A session that stays unavailable has ended; nothing is left to show.
  Future<bool> _resolvedElsewhere() async {
    final native = await status();
    if (native['available'] == false) return ++_unavailable >= 6;
    _unavailable = 0;
    if (native['plugin_rebuild'] is Map) return false;
    if (_open) await notifier.close(_id);
    return true;
  }

  /// Retries automatically when the connection comes back, or after a few
  /// growing delays when nobody can tell or downloads failed while online.
  Future<void> _maybeRetryOnline() async {
    final connected = await online?.call();
    final reconnected = connected == true && _wasOnline == false;
    _wasOnline = connected ?? _wasOnline;
    final due = _retryAt != null && !clock().isBefore(_retryAt!);
    // Known offline: wait for the connection instead of the timer.
    if (!reconnected && (connected == false || !due)) return;
    await _start(const ['rebuild']);
    await _show(_messages.reconnected(canOpen: _canOpen));
  }
}

enum _State { rebuilding, failed, offline, restored }
