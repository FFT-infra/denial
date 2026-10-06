final class SetupNotice {
  const SetupNotice({required this.title, required this.description});

  final String title;
  final String description;

  static SetupNotice fromState(Map<String, Object?> state) {
    final dart = state['dart'];
    if (dart is Map && dart['available'] == false) {
      final expected = dart['expectedVersion'] as String?;
      final constraint = dart['constraint'] as String?;
      final installed = dart['version'] as String?;
      if (installed != null && constraint != null) {
        return SetupNotice(
          title: 'Compatible Dart is required',
          description:
              'Dart $installed is installed, but Denial requires $constraint. Install a compatible Dart package and make sure dart is available in PATH, then try again.',
        );
      }
      if (expected != null) {
        return SetupNotice(
          title: 'Dart is required',
          description:
              'Install Dart with your system package manager. Denial recommends Dart $expected. Make sure dart is available in PATH, then try again.',
        );
      }
    }
    return const SetupNotice(
      title: 'Plugin tools need attention',
      description: 'Preparation could not finish. See Activity for details, then try again.',
    );
  }
}
