# Custom Flutter shells

A complete shell is a plugin implementing `ShellApplication` from
`package:denial_flutter_sdk/application.dart`. The generated application selects
one provider, calls `createShell()`, and passes that widget to the SDK's
`runDenialShell` bootstrap. `dart_shell/lib/main.dart` is only the handwritten
development composition; it has no public runtime API or default UI implementation.

Use [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md) for contribution declarations,
constructor injection, shortcut actions, and build/activation instructions.
The [minimal custom root](../dart_shell/example/custom_shell.dart) demonstrates
an alternative composition using only SDK imports. It deliberately displays status
rather than pretending to be a complete window manager.

## SDK ownership

`denial_sdk` contains Flutter-independent models and composition contracts.
`denial_flutter_sdk` contains the Flutter platform client, reactive providers,
bootstrap, system services, input/layout models, surface rendering, theme and
materials. SDK libraries never depend on a UI plugin. Native Wayland ownership,
resource lifetimes, authentication enforcement, engine integration and recovery
remain in Rust. Dart clients use the shared SDK bridge and its provider lifetime.

The reference desktop owns its complete UI tree, including desktop and mobile
scenes, window decorations and transitions, lock UI, keyboard, notifications,
settings and welcome screens. It consumes exactly the same public SDK libraries
available to an external plugin. It is an example implementation, not an API that
alternative shells must wrap or import. Its `ShellServices` adapter supplies
reference-desktop behavior to its panel and action contributions.
The adapter implements focused capability interfaces from `services.dart`;
feature helpers can request only window, application, workspace, desktop,
telemetry, media, presentation or tray services. The complete bundle remains
available at composition boundaries.

## Building a complete replacement

Bootstrap creates Flutter bindings and the root `ProviderScope`, captures the
startup environment, and initializes common configuration. It does not secretly
mount stock chrome. The selected root owns presentation and its subscriptions.

Use `state.dart` for shared window, display, authentication, configuration and
system-service providers. Subscribe with Riverpod and obtain the existing bridge
with `ref.read(denialBridgeProvider)`; do not create a second embedded bridge or
replace native channel handlers. `platform.dart` exposes its typed operations.
The bridge connects native reply handlers as soon as its provider is read.
Display, settings and shortcut providers work independently of window state;
`bridge.start` is only a compatibility API for optional window callbacks.
Use `windowSnapshots`, `windowsChanged` and `windowActivations` streams for
cancellable subscriptions.

`rendering.dart` exposes live surface trees, native window planes, geometry,
retained transforms, cursor and wallpaper primitives. `input.dart` exposes the
input/visibility layout and shell interaction registry. `wire.dart` exposes raw
versioned codecs when implementing platform integration; import it with a prefix
to distinguish protocol records from SDK models.

`shellControllerProvider` owns the shared native window subscription and exposes
snapshots, focus and authoritative lock state. Keep gesture, shade, keyboard and
transition state in your root plugin; the reference desktop's controller, profile
and layout constants are internal examples. `ShellWindowsBuilder` offers filtered
windows and actions; `ShellPrimaryWindow` displays the focused application. Its
optional `contentPadding` supplies your shell's safe-area insets to in-bundle apps.

A replacement that paints native windows must publish input and visibility layouts
consistent with those surfaces, their transforms, clipping and popup geometry.
It also owns output/workspace placement, configured work-area reservations,
transient surfaces, keyboard presentation and lock-screen presentation. Consume
SDK authentication and lock-frame state; UI cannot authenticate a session by
changing a local boolean. Keep lock acknowledgements tied to actual frame layout.
These responsibilities require real implementation; painting a client texture alone
does not create a complete shell.

Use `ShellPopupHost` with `shellPopupControllerProvider` from `popups.dart` for managed popup
lifetimes, and `ShellActionsBinding` for the generated action collection. Register
one action catalog owner. Dispose ordinary widget-owned resources normally and
let provider-owned services retain their existing lifecycle.

Assets and fonts use the SDK's package namespace and travel with its Pub package.
Generated applications do not copy assets from a hidden runtime manifest.
The old `denial_dart_shell/denial.dart` and `denial_default_shell.dart` facades are
removed. Plugin planning rejects legacy runtime dependencies and private SDK
imports, including conditional imports and relative access to `lib/src`.

This is trusted compiled shell code, not a security sandbox. Read the
[live UI trust boundary](UI_DEVELOPMENT.md#trust-boundary). Build a new composition
and activate it through the manager; never overwrite mapped libraries. Visual
validation belongs to the user.
