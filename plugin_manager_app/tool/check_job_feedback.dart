import 'dart:io';

import 'package:denial_plugin_manager_app/job_feedback.dart';

void main() {
  void check(String name, bool value) {
    if (!value) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  Map<String, Object?> job(String id, String phase, {bool nested = false}) => {
    'id': id,
    'phase': phase,
    'operation': 'apply',
    'error': 'failed $id',
    'arguments': nested
        ? <String, Object?>{}
        : {
            'argv': ['apply'],
          },
  };
  final connection = ConnectionFeedback();
  connection.failed('Plugin tools are temporarily unavailable');
  check(
    'Connection failure disables changes',
    !connection.available && connection.error != null,
  );
  connection.dismiss();
  check(
    'Dismissing a connection error does not make tools available',
    !connection.available && connection.error == null,
  );
  connection.failed('temporary failure');
  final failedApply = JobFeedback()..observe([job('failed-apply', 'failed')]);
  connection.succeeded();
  check(
    'Successful polling removes stale connection errors',
    connection.available && connection.error == null,
  );
  check(
    'Connection recovery preserves failed Apply details',
    failedApply.failure?['id'] == 'failed-apply',
  );
  final feedback = JobFeedback();
  feedback.observe([job('1', 'succeeded')]);
  check('No failure for success', feedback.failure == null);
  feedback.observe([job('2', 'failed'), job('1', 'succeeded')]);
  check('Failure between polls is visible', feedback.failure?['id'] == '2');
  feedback.observe([job('2', 'failed')]);
  check('Failure persists across polling', feedback.failure?['id'] == '2');
  feedback.dismiss();
  feedback.observe([job('2', 'failed')]);
  check('Dismissed failure is not resurrected', feedback.failure == null);
  feedback.observe([job('3', 'running'), job('2', 'failed')]);
  feedback.observe([job('3', 'interrupted'), job('2', 'failed')]);
  check('Vanished worker reports failure', feedback.failure?['id'] == '3');
  feedback.dismiss();
  feedback.observe([job('4', 'failed', nested: true), job('3', 'interrupted')]);
  check('Nested planning job cannot duplicate error', feedback.failure == null);
  final reopened = JobFeedback()
    ..observe([job('4', 'failed', nested: true), job('3', 'failed')]);
  check(
    'Reopen restores latest operation failure',
    reopened.failure?['id'] == '3',
  );
  final recovered = JobFeedback()
    ..observe([job('5', 'succeeded'), job('3', 'failed')]);
  check(
    'Old failures stay in history after success',
    recovered.failure == null,
  );
  final progress = OperationProgress.fromJob({
    'progress': {'completed': 2, 'total': 5, 'label': 'Compiling your desktop'},
  });
  check(
    'Bar counts completed stages',
    progress.fraction == .4 && progress.description.startsWith('Step 3 of 5'),
  );
  final timed = OperationProgress.fromJob({
    'progress': {
      'completed': 2,
      'total': 5,
      'label': 'Compiling Dart sources',
      'started': '2026-09-28T12:00:00Z',
    },
  });
  check(
    'Elapsed time keeps increasing during a quiet compiler',
    timed
        .descriptionAt(DateTime.parse('2026-09-28T12:01:05Z'))
        .endsWith('1:05 elapsed'),
  );
  check(
    'Phase text remains stable for accessibility',
    !timed.stageDescription.contains('elapsed'),
  );
  final nextPhase = OperationProgress.fromJob({
    'progress': {
      'completed': 2,
      'total': 5,
      'label': 'Preparing assets',
      'started': '2026-09-28T12:01:05Z',
    },
  });
  check(
    'Elapsed time resets for the new compilation substep',
    nextPhase
        .descriptionAt(DateTime.parse('2026-09-28T12:01:07Z'))
        .endsWith('0:02 elapsed'),
  );
  check(
    'Future clock values never produce negative elapsed time',
    timed
        .descriptionAt(DateTime.parse('2026-09-28T11:59:59Z'))
        .endsWith('0:00 elapsed'),
  );
  check(
    'Unknown progress is indeterminate',
    OperationProgress.fromJob(job('6', 'queued')).fraction == null,
  );
  check(
    'Panel conflict explains how to recover',
    failureSummary(
      'requires package:denial_flutter_sdk/panels.dart#ShellPanel; found 2 providers',
    ).contains('Keep one enabled'),
  );
  check(
    'Other conflicts remain generic',
    failureSummary('requires Feature; found 10 providers')
        .contains('Multiple plugins'),
  );
  const raw =
      'Operation failed (1). Snapshotting\nResolving packages\ndenial-plugins: requires package:denial_flutter_sdk/panels.dart#ShellPanel; found 2 providers';
  check(
    'Legacy details extract only the actual error',
    failureCause(raw).startsWith('requires ') &&
        !failureCause(raw).contains('Snapshotting'),
  );
  check(
    'Legacy progress remains a separate log',
    legacyBuildLog(raw).contains('Resolving packages') &&
        !legacyBuildLog(raw).contains('found 2'),
  );
  check(
    'Missing preflight cannot enable Apply',
    !selectionCanApply({
      'selection': {'revision': 1},
    }),
  );
  check(
    'Stale preflight cannot enable Apply',
    !selectionCanApply({
      'selection': {'revision': 2},
      'preflight': {'selectionRevision': 1, 'canApply': true},
    }),
  );
  check(
    'Known conflict disables Apply',
    !selectionCanApply({
      'selection': {'revision': 2},
      'preflight': {'selectionRevision': 2, 'canApply': false},
    }),
  );
  check(
    'Matching successful preflight permits Apply',
    selectionCanApply({
      'selection': {'revision': 2},
      'preflight': {'selectionRevision': 2, 'canApply': true},
    }),
  );
}
