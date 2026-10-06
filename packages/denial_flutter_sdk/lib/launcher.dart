import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

/// Launcher presentation selected when the shell application is compiled.
/// The host owns placement, transitions, native input capture and launching.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrOne)
abstract interface class ShellLauncher {
  Widget build(BuildContext context, {required LauncherContext launcher});
}

/// A launchable application. IDs are opaque and shared with recent history.
@immutable
class LauncherApplication {
  const LauncherApplication({
    required this.id,
    required this.name,
    required this.searchableText,
  });

  final String id;
  final String name;

  /// Normalized lowercase application metadata for searching.
  final String searchableText;
}

/// Current host data and actions. Rebuilt when catalog, locale, history or
/// visibility changes. Plugins must not dispose the host's focus node.
@immutable
class LauncherContext {
  const LauncherContext({
    required this.applications,
    required this.recentApplicationIds,
    required this.visible,
    required this.searchFocusNode,
    required this.onEnter,
    required this.onExit,
    required this.onDismiss,
    required this.onLaunch,
    required this.buildIcon,
    required this.strings,
    required this.linkCursor,
    required this.textCursor,
  });

  /// Immutable snapshot; hosts retain its identity until catalog/locale changes.
  final List<LauncherApplication> applications;
  final List<String> recentApplicationIds;
  final bool visible;
  final FocusNode searchFocusNode;
  final VoidCallback onEnter;
  final VoidCallback onExit;

  /// Immediately dismisses the surface and releases keyboard capture.
  final VoidCallback onDismiss;

  /// Launch by opaque ID; the host records history and dismisses the surface.
  final ValueChanged<String> onLaunch;
  final Widget Function(BuildContext context, String applicationId) buildIcon;
  final LauncherStrings strings;
  final MouseCursor linkCursor;
  final MouseCursor textCursor;
}

abstract interface class LauncherStrings {
  String get suggestionsTitle;
  String get searchApplications;
  String get clearSearch;
  String get noApplicationsFound;
  String get loadingApplications;
  String launchApplication(String name);
}
