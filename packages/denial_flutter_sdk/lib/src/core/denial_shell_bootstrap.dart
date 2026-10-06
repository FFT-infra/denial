import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_window_render_telemetry.dart';
import '../launcher/runtime_paths.dart';
import '../local_apps/local_flutter_application.dart';

import 'package:denial_flutter_sdk/motion.dart';

import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';

typedef DenialLocalApplicationsBuilder = List<LocalFlutterApplication> Function(
  StartupEnvironment environment,
);

/// Starts a Denial shell with the complete required process configuration.
///
/// The generated entry point passes its selected ShellApplication's root here.
/// Startup environment capture, Flutter binding setup, diagnostics, Riverpod
/// ownership, and local application registration are independent of stock UI.
Future<void> runDenialShell({
  required Widget shell,
  DenialLocalApplicationsBuilder? localApplications,
}) async {
  final environment = StartupEnvironment.capture();
  WidgetsFlutterBinding.ensureInitialized();
  MotionTelemetry.install(enabled: environment.flag('DENIAL_DART_FRAME_TRACE'));
  DesktopWindowRenderTelemetry.install(
    enabled: environment.flag('DENIAL_RENDER_AUDIT'),
  );
  final wallpaperStore = WallpaperStore(
    RuntimePaths(environment: environment.values),
  );
  final initialWallpaper =
      await wallpaperStore.read() ?? WallpaperAssignment.initial();
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
        wallpaperStoreProvider.overrideWithValue(wallpaperStore),
        initialWallpaperAssignmentProvider.overrideWithValue(initialWallpaper),
        localFlutterApplicationsProvider.overrideWithValue(
          localApplications?.call(environment) ??
              const <LocalFlutterApplication>[],
        ),
      ],
      child: shell,
    ),
  );
}
