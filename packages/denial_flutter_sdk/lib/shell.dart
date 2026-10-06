/// Shell bootstrap, root composition and window hosting APIs.
/// Plugin-owned event dispatch and notifier guards live in lifecycle.dart.
library;

export 'src/core/bounded_text.dart' show normalizeBoundedText;
export 'src/core/denial_shell_bootstrap.dart'
    show DenialLocalApplicationsBuilder, runDenialShell;
export 'src/core/fingerprint_stage.dart' show FingerprintStage;
export 'src/core/shell_actions_binding.dart' show ShellActionsBinding;
export 'src/core/shell_overlay_host.dart' show ShellOverlayHost;
export 'src/core/shell_scene.dart' show DenialShellScene;
export 'src/core/shell_window_providers.dart' show userAppWindowsProvider;
export 'src/core/shell_windows.dart'
    show
        ShellPrimaryWindow,
        ShellWindowActions,
        ShellWindowsBuilder,
        ShellWindowsWidgetBuilder;
export 'src/core/utf8_size.dart' show fitsUtf8ByteLimit;
