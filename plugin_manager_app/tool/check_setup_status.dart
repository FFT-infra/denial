import 'dart:io';

import 'package:denial_plugin_manager_app/setup_status.dart';

void main() {
  void check(String name, bool value) {
    if (!value) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  final missing = SetupNotice.fromState({
    'dart': {
      'available': false,
      'found': false,
      'expectedVersion': '3.13.4',
      'constraint': '>=3.13.0 <4.0.0',
    },
  });
  check(
    'Missing Dart prompts package installation',
    missing.title == 'Dart is required' &&
        missing.description.contains('recommends Dart 3.13.4') &&
        missing.description.contains('PATH'),
  );

  final incompatible = SetupNotice.fromState({
    'dart': {
      'available': false,
      'found': true,
      'expectedVersion': '3.13.4',
      'constraint': '>=3.13.0 <4.0.0',
      'version': '4.0.0',
    },
  });
  check(
    'Incompatible Dart names both versions',
    incompatible.title == 'Compatible Dart is required' &&
        incompatible.description.contains('4.0.0') &&
        incompatible.description.contains('>=3.13.0 <4.0.0'),
  );

  check(
    'Other setup failures retain generic recovery',
    SetupNotice.fromState(const {}).title == 'Plugin tools need attention',
  );
}
