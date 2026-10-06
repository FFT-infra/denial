import 'package:denial_desktop/settings_app.dart';
import 'package:denial_desktop/welcome_app.dart';
import 'package:denial_flutter_sdk/environment.dart';
import 'package:flutter/material.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.contains('--welcome')) {
    runApp(const DenialWelcomeStandaloneApp());
    return;
  }
  final environment = StartupEnvironment.capture();
  runApp(
    DenialSettingsStandaloneApp(
      initialPage: _initialPage(arguments),
      startupEnvironment: environment,
    ),
  );
}

SettingsPageId _initialPage(List<String> arguments) {
  for (final argument in arguments) {
    if (!argument.startsWith('--page=')) {
      continue;
    }
    final requested = argument.substring('--page='.length);
    for (final page in SettingsPageId.values) {
      if (page.name == requested) {
        return page;
      }
    }
  }
  return SettingsPageId.appearance;
}
