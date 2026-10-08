/// Parse actual Flutter build-target starts. Verbose output also contains
/// commands and unrelated parallel targets; those are never progress signals.
final class CompilerProgress {
  String? _last;
  String? observe(String line) {
    final clean = line.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    final match = RegExp(
      r'^\s*(?:\[\s*(?:[+]?\d+ ms)?\s*\]\s*)?(kernel_snapshot(?:_program)?|aot_elf_release|release_bundle_linux-(?:x64|arm64)_assets): Starting(?:\s|$)',
    ).firstMatch(clean);
    final phase = switch (match?.group(1)) {
      'kernel_snapshot' ||
      'kernel_snapshot_program' => 'Compiling Dart sources',
      'aot_elf_release' => 'Optimizing and generating native code',
      final String target when target.startsWith('release_bundle_') =>
        'Preparing assets',
      _ => null,
    };
    if (phase == null || phase == _last) return null;
    _last = phase;
    return phase;
  }
}

/// Completed operation stages, not an estimate of elapsed compile time.
/// Unknown diagnostic lines must never replace the last reported stage.
Map<String, Object?>? jobProgress(String operation, String message) {
  // A rebuild after a Denial update also waits for a quiet moment to switch.
  final rebuilding = operation == 'rebuild';
  final applying = rebuilding || operation == 'apply' || operation == 'update';
  int? step;
  String? label;
  if (message.startsWith('Snapshotting') || message.startsWith('Resolving')) {
    step = 0;
    label = 'Preparing your plugins';
  } else if (message.startsWith('Discovering') ||
      message == 'Reusing checked plugin contributions') {
    step = 1;
    label = 'Checking plugin compatibility';
  } else if (message == 'Preparing the release compiler') {
    step = applying ? 2 : 0;
    label = 'Preparing your desktop build';
  } else if ({
    'Compiling Dart sources',
    'Optimizing and generating native code',
    'Preparing assets',
  }.contains(message)) {
    step = applying ? 2 : 0;
    label = message;
  } else if (message.startsWith('Compiling') ||
      message == 'Reusing a verified desktop bundle') {
    step = applying ? 2 : 0;
    label = message.startsWith('Reusing')
        ? 'Loading your saved desktop'
        : 'Compiling your desktop';
  } else if (message.startsWith('Validating and sealing')) {
    step = applying ? 3 : 1;
    label = 'Verifying your desktop';
  } else if (rebuilding && message == 'Waiting for a pause to switch') {
    step = 4;
    label = 'Switching when you pause';
  } else if (message == 'Applying your desktop') {
    step = rebuilding
        ? 5
        : applying
        ? 4
        : 0;
    label = 'Applying and checking your desktop';
  } else if (message == 'Verifying the installed release build tools') {
    step = 0;
    label = 'Verifying plugin tools';
  } else if (message == 'Preparing your compiler cache') {
    step = applying ? 0 : 1;
    label = 'Preparing plugin tools';
  }
  if (step == null || label == null) return null;
  final total = rebuilding
      ? 6
      : applying
      ? 5
      : {'activate', 'restore', 'revert'}.contains(operation)
      ? 1
      : 2;
  return {'completed': step, 'total': total, 'label': label};
}
