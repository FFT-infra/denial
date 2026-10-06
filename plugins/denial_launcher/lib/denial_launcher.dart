@Plugin()
library;

import 'package:denial_sdk/composition.dart';
import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:flutter/widgets.dart';

import 'src/desktop_application_launcher.dart';

@Provides(ShellLauncher)
final class LauncherPlugin implements ShellLauncher {
  const LauncherPlugin();

  @override
  Widget build(BuildContext context, {required LauncherContext launcher}) =>
      DesktopApplicationLauncher(launcher: launcher);
}

/// The launcher supplies the action; Rust only routes its stable identity.
@Provides(ShellAction)
final class OpenApplicationsAction implements ShellAction {
  const OpenApplicationsAction();
  @override
  String get id => 'denial_launcher.openApplications';
  @override
  String get provider => 'Launcher';
  @override
  String label(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh'
      ? '打开应用列表'
      : 'Open applications';
  @override
  String description(BuildContext context) => '';
  @override
  void invoke(ShellActionContext context) => context.services.toggleLauncher();
}
