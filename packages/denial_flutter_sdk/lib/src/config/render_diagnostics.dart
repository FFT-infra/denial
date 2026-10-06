/// Release-only experiments must be explicitly selected when assembling AOT.
/// Normal builds retain the complete desktop scene.
///
/// By default this removes stock desktop UI and wallpaper, not composition:
/// client windows retain their existing clipping, opacity, glass, and motion.
/// The native input bridge, cursor, and secure lock stage remain installed.
const desktopWindowsOnly = bool.fromEnvironment(
  'DENIAL_DIAGNOSTIC_WINDOWS_ONLY',
);

/// Restores the configured wallpaper behind the diagnostic window scene for
/// shadow validation, without restoring the rest of the stock desktop UI.
/// Keep disabled for comparisons with the original windows-only CPU baseline.
const desktopDiagnosticWallpaper = bool.fromEnvironment(
  'DENIAL_DIAGNOSTIC_WALLPAPER',
);
