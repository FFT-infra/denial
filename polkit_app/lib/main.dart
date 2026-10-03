import 'dart:async';

import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent.dart';
import 'prompt.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = StartupEnvironment.capture();
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
        denialBridgeProvider.overrideWith((ref) {
          final bridge = DenialBridge(useControlSocket: true);
          ref.onDispose(bridge.dispose);
          return bridge;
        }),
      ],
      child: const AuthenticationApp(),
    ),
  );
}

/// The authentication prompt in the user's live Denial appearance.
///
/// Authentication policy and the conversation remain Rust's. Appearance is
/// presentation only: an unavailable control socket leaves the defaults.
class AuthenticationApp extends ConsumerStatefulWidget {
  const AuthenticationApp({super.key});

  @override
  ConsumerState<AuthenticationApp> createState() => _AuthenticationAppState();
}

class _AuthenticationAppState extends ConsumerState<AuthenticationApp> {
  final session = AgentSession();

  @override
  void initState() {
    super.initState();
    unawaited(session.connect());
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(
      shellSettingsProvider.select((settings) => settings.appearance),
    );
    final durationScale = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.durationScale,
      ),
    );
    final locale = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.localization.localeOverride,
      ),
    );
    final syncing =
        ref.watch(shellSettingsSyncStatusProvider).phase ==
        ShellSettingsSyncPhase.loading;
    final accent = ref.watch(shellAccentProvider);
    // Match the shell's own theme construction, including the opacity
    // threshold that decides where the compositor frosts the card.
    final light = appearance.transparencyMode == ShellTransparencyMode.glass
        ? appearance.glass.appearance == ShellGlassAppearance.light
        : appearance.colorSchemePreference.effectiveBrightness ==
              Brightness.light;
    final theme = ShellThemeData(
      colors: light ? ShellColorScheme.light : ShellColorScheme.dark,
      accent: accent.color,
      fontFamily: appearance.fontFamily,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      transparencyMode: appearance.transparencyMode,
      backdropBlurLevel: appearance.backdropBlurLevel,
      backdropBlurOpacityThreshold: appearance.backdropBlurOpacityThreshold,
      glass: appearance.glass,
    );
    final material = theme.toMaterialTheme();
    return AnimatedShellTheme(
      data: theme,
      duration: Duration(milliseconds: (240 * durationScale).round()),
      child: MaterialApp(
        title: 'Authentication',
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: material,
        darkTheme: material,
        themeMode: light ? ThemeMode.light : ThemeMode.dark,
        // Only the card is painted. The overlay canvas around it stays fully
        // transparent, so neither glass nor tint appears outside the card.
        builder: (context, child) =>
            ColoredBox(color: Colors.transparent, child: child),
        home: AuthenticationDialog(
          session: session,
          // Reveal in the final accent rather than recoloring a visible card.
          appearanceReady:
              !syncing &&
              (appearance.accentSource == ShellAccentSource.custom ||
                  accent.isResolved),
          durationScale: durationScale,
        ),
      ),
    );
  }
}
