/// Connection failures are transient; successful polling clears only these.
/// Dismissing a message must not enable Apply while the backend is unreachable.
class ConnectionFeedback {
  bool available = false;
  String? error;
  void succeeded() {
    available = true;
    error = null;
  }

  void failed(Object failure) {
    available = false;
    error = '$failure';
  }

  void dismiss() => error = null;
}

/// Keeps detached-worker failure feedback alive across polling, including jobs
/// that complete between polls. Nested planning jobs do not own the UI operation.
class JobFeedback {
  final Set<String> _seen = {};
  bool _initialized = false;
  Map<String, Object?>? failure;

  void observe(List<Map<String, Object?>> jobs) {
    final operations = jobs
        .where((job) => (job['arguments'] as Map?)?['argv'] is List)
        .toList();
    final completed = operations
        .where(
          (job) =>
              {'failed', 'interrupted', 'succeeded'}.contains(job['phase']),
        )
        .toList();
    final fresh = completed.where((job) => !_seen.contains(job['id'])).toList();
    // On reopen, only the most recent request should announce a past failure.
    final candidate = !_initialized
        ? operations.firstOrNull
        : fresh.firstOrNull;
    _initialized = true;
    _seen.addAll(completed.map((job) => job['id']! as String));
    if (candidate != null &&
        {'failed', 'interrupted'}.contains(candidate['phase'])) {
      failure = candidate;
    }
  }

  void dismiss() => failure = null;
}

String failureCause(String error) {
  const prefix = 'denial-plugins: ';
  final marker = error.lastIndexOf(prefix);
  if (marker >= 0) return error.substring(marker + prefix.length).trim();
  return error
      .replaceFirst(RegExp(r'^Operation failed \(\d+\)\.\s*'), '')
      .trim();
}

String legacyBuildLog(String error) {
  final marker = error.lastIndexOf('denial-plugins: ');
  return marker < 0
      ? ''
      : error
            .substring(0, marker)
            .replaceFirst(RegExp(r'^Operation failed \(\d+\)\.\s*'), '')
            .trim();
}

String failureSummary(String error) {
  error = failureCause(error);
  if (error.contains('plugin bundle needs a different engine')) {
    return 'Your applied plugins are saved, but this session uses a different Flutter engine. Use a Denial session with the matching engine to load them again.';
  }
  if (error.contains('plugin bundle source does not match installed Denial')) {
    return 'Your saved plugins were built for another Denial version. Rebuild them with the matching installed build tools.';
  }
  if (error.contains("before applying.") ||
      error.contains("compatibility declarations")) {
    return error;
  }
  if (error.contains('#ShellPanel; found') &&
      !error.contains('found 0 providers')) {
    return 'More than one desktop panel is selected. Keep one enabled, then apply again.';
  }
  if (RegExp(r'found (?:[2-9]|[1-9][0-9]+) providers').hasMatch(error)) {
    return 'Multiple plugins provide the same feature. Choose one, then apply again. Details identify the conflicting plugins.';
  }
  if (error.contains('found 0 providers') ||
      error.contains('has no provider') ||
      error.contains('no provider is enabled')) {
    return 'A required desktop feature is missing. Enable a plugin that provides it, then apply again.';
  }
  if (error.contains('Log out and back')) {
    return 'Log out and back into Denial once to finish the update. Your choices are saved.';
  }
  if (error.contains('worker exited')) {
    return 'The background operation stopped unexpectedly. Check Activity before trying again.';
  }
  if (error.contains('SocketException') ||
      error.contains('Could not resolve host') ||
      error.contains('Connection timed out')) {
    return 'A download failed. Check your connection and try again.';
  }
  return 'This change could not be completed. Open details to see the cause.';
}

class OperationProgress {
  const OperationProgress(
    this.label,
    this.completed,
    this.total, {
    this.started,
  });
  factory OperationProgress.fromJob(Map<String, Object?>? job) {
    final progress = job?['progress'];
    if (progress is Map &&
        progress['completed'] is int &&
        progress['total'] is int &&
        (progress['total'] as int) > 0 &&
        progress['label'] is String) {
      final total = progress['total'] as int;
      return OperationProgress(
        progress['label'] as String,
        (progress['completed'] as int).clamp(0, total),
        total,
        started: progress['started'] is String
            ? DateTime.tryParse(progress['started'] as String)
            : null,
      );
    }
    return OperationProgress(
      job?['phase'] == 'queued'
          ? 'Waiting to start'
          : 'Working on your changes',
      null,
      null,
    );
  }
  final String label;
  final DateTime? started;
  final int? completed;
  final int? total;
  double? get fraction => completed == null ? null : completed! / total!;
  String get stageDescription => total == null
      ? 'You can close this window. We’ll keep going.'
      : completed == total
      ? 'Completed'
      : 'Step ${completed! + 1} of $total · $label';
  String get description => descriptionAt(DateTime.now());
  String descriptionAt(DateTime now) {
    if (started == null || completed == total && total != null) {
      return stageDescription;
    }
    final seconds = now.difference(started!).inSeconds.clamp(0, 1 << 30);
    final clock =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return '$stageDescription · $clock elapsed';
  }
}

/// Apply must never use a check from an earlier selection revision.
bool selectionCanApply(Map<String, Object?> state) {
  final selection = state['selection'];
  final preflight = state['preflight'];
  return selection is Map &&
      preflight is Map &&
      selection['revision'] is int &&
      preflight['selectionRevision'] == selection['revision'] &&
      preflight['canApply'] == true;
}
