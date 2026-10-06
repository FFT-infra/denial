/// Canonical power-profile identifiers.
abstract final class PowerProfile {
  static const String powerSave = 'power-save';
  static const String balanced = 'balanced';
  static const String performance = 'performance';

  /// Cycles power-save -> balanced -> performance -> power-save.
  static String next(String current) => switch (current) {
    powerSave => balanced,
    balanced => performance,
    _ => powerSave,
  };

  static String? normalize(String? value) => switch ((value ?? '').trim()) {
    'power-save' || 'power-saver' || 'powersave' || 'power_save' => powerSave,
    'performance' => performance,
    'balanced' => balanced,
    _ => null,
  };
}
