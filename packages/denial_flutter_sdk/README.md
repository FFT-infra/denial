# Denial Flutter SDK

The public Flutter integration API for all Denial plugins, including the default
UI. This package owns the Dart platform client, provider lifetimes, native models,
surface/input primitives, bootstrap, services, theme, materials and shared assets.
It never depends on `dart_shell` or a UI plugin. Native ownership and enforcement
remain in the compositor.

| Library | Purpose |
| --- | --- |
| `application.dart`, `surfaces.dart`, `launcher.dart`, `actions.dart` | Plugin authoring and typed composition contracts |
| `services.dart` | Injected host behavior for surfaces/actions |
| `surface_hosting.dart` | Root-shell mounting of plugin-declared surfaces |
| `popups.dart` | Temporary UI, dismissal, focus and popup lifetime |
| `panels.dart` | Edge vocabulary shared with native layout settings |
| `shell.dart` | Bootstrap, action binding, Flutter root overlay and window helpers |
| `state.dart`, `models.dart` | Reactive platform state, controllers and native models |
| `platform.dart` | Shared bridge, typed native operations and events |
| `rendering.dart`, `input.dart` | Live surfaces, native window planes, transforms, input and visibility layouts |
| `system_services.dart` | Managed audio, connectivity, Bluetooth, tray, media, power and authentication services |
| `service_backends.dart` | Explicit backend construction and injection contracts for advanced integrations |
| `lifecycle.dart`, `workers.dart` | Plugin-owned asynchronous state guards, event dispatch and background isolates |
| `settings.dart`, `applications.dart`, `wallpaper.dart` | Configuration, application catalog/launching and wallpaper APIs |
| `environment.dart`, `localization.dart`, `diagnostics.dart` | Environment, localization and instrumentation |
| `theme.dart`, `effects.dart`, `materials.dart` | Shared presentation primitives |
| `wire.dart` | Low-level versioned codecs and channel definitions; import with a prefix |

Use the injected `ShellServices` when extending a host. A complete replacement
shell can use the lower-level SDK providers and primitives directly. Reuse
`denialBridgeProvider` inside the SDK bootstrap instead of constructing another
embedded bridge. A host's `ShellServices` implementation describes its UI policy;
it does not own a second native service implementation.

The shared bridge connects native reply channels when created, independently
of `ShellController`. Display, settings and shortcut providers can be used alone.
Window snapshots and events have cancellable stream subscriptions; `start` only
assigns optional legacy callbacks. Internally, feature clients share one transport,
request ID allocator and wire codec under `src/platform/bridge`.

Feature widgets and helpers can depend on `ShellWindowServices`,
`ShellApplicationServices`, `ShellDesktopServices`, `ShellWorkspaceServices`,
`ShellTelemetryServices`, `ShellMediaServices`, `ShellPresentationServices` or
`ShellTrayServices` from `services.dart`. Each exposes only its capability.
`ShellServices` implements the complete bundle for surface/action injection;
existing member calls and host implementations remain compatible. For example,
a preview helper can accept `ShellWindowServices` without depending on media,
tray or telemetry providers.

`ShellController` owns the single native window subscription, focus operations and
authoritative lock state. `ShellState` contains native snapshots and lookup indexes;
root plugins keep their own gesture, overlay, keyboard and transition state. The
reference implementation lives in `plugins/denial_desktop/lib/src/state`, including
its profile and geometry constants. `ShellMetrics` and `ShellProfile` are no longer
SDK APIs. `ShellWindowsBuilder` and `ShellPrimaryWindow` remain useful for custom
shells; supply `contentPadding` when in-bundle apps need shell-specific safe areas.
The unused legacy lock-file watcher and its exports have been removed. Request
locking through `ShellController`/native authentication and observe native state.

Audio/brightness `apply` and screenshot sends return `void`: sending a command
does not confirm completion. Reads and native acknowledgement streams retain
their asynchronous contracts. `SystemActionsService` requires a bridge.

The public state, service, bridge, shell, application and model libraries use
explicit export lists. Reducers, reconciliation algorithms, native worker
protocols, D-Bus endpoints and test helpers remain implementation details.
Use `service_backends.dart` when implementing backend overrides or constructing
a standalone client; its owner must dispose that client. Use `lifecycle.dart`
and `workers.dart` for plugin-owned asynchronous work. Native protocol integration
uses `wire.dart`; ordinary features use the shared typed bridge.

SDK implementation tests and benchmarks may import the specific `src/` library
they exercise. Those imports are not plugin APIs and must not appear in plugin
contribution libraries. New public names require an intentional export and a
namespace regression check; implementation tests do not justify public exports.

The reference UI lives in a plugin, including its desktop/mobile hierarchy and
stock application screens. There is no parallel runtime facade or privileged
private import path. See [plugin development](../../docs/PLUGIN_DEVELOPMENT.md)
and [custom shells](../../docs/CUSTOM_SHELLS.md). These are repository-local APIs;
publication and long-term compatibility still require explicit versioning.

Validate using `tools/denial-pc plugin-check` outside the sandbox. It uses the
locked release engine's Dart declarations for low-level APIs and runs pure Dart
checks without building a Flutter development engine.

Glass has three independent backing opacities: `ShellGlassConfiguration.opacity`
for Denial shell surfaces, `windowOpacity` for compatible application window
backgrounds, and `appPanelOpacity` for their glass sidebars and toolbars. Missing
window/app-panel values migrate from the legacy shared `opacity`; serialization
writes all three and `copyWith` preserves unmodified values. UI sliders show
opacity directly, increasing from clear to opaque. Blur/refraction and other
optical tuning remain shared. This does not change whole-window focus opacity.

Settings and Plugins pass the unmodified glass configuration to
`DenialApplicationTheme`: the frame uses window opacity and navigation/command
panels use app-panel opacity. The legacy `ShellThemeData.forWindowSurfaces()` scope
is only for older in-shell material consumers; it must not wrap the application
material API because it replaces panel opacity. These APIs change backings, not
foreground text/icon opacity. Other Wayland clients still own their submitted
pixels; this does not rewrite third-party client backgrounds.

The glass configuration parser and migration tests run with `dart test` in this
package, without a Flutter development engine. They are also part of
`tools/denial-pc plugin-check`.

`surfaces.dart` exposes plugin-owned geometry, output selection, scene-layer
declarations and visibility snapshots/events. Host implementation widgets live in
`surface_hosting.dart`; popup lifecycle lives in `popups.dart`. Fade ownership is
explicit (`ShellSurfaceFade.automatic` or `.custom`), with glass-safe presentation
provided through `ShellSurfacePresentation`. The reference
composition accepts any number of `ShellSurface` providers. Native work-area
reservation is separate (`ShellWorkArea`, currently optional/exclusive because of
the native protocol). See the [placement guide](../../docs/PLUGIN_DEVELOPMENT.md#declare-your-own-position-and-visibility).

Application presentation is defined in [APPLICATION_MATERIALS.md](../../docs/APPLICATION_MATERIALS.md).
Plugins is the first consumer of `DenialApplicationTheme`, `DenialMaterial`,
`DenialApplicationFrame` and `DenialContentPane`. The frame reveals the desktop
above an opaque content surface; inset glass navigation spans both regions and
grouped commands float above them. Denial's compositor supplies desktop pixels;
client-side filters sample available application pixels. Shared semantic tokens
own the palette and floating geometry. Adopt these roles for new application UI
instead of using shell `panelColor` or duplicating Plugins' old color constants.

Nested application surfaces use `DenialSurfaceGeometry` from `materials.dart`:
resolve the containing radius (default `ShellTheme.windowRadius`), then derive
`max(minimumRadius, outerRadius - inset)` (minimum 4 logical pixels). `DenialMaterial(inset: ...)` shares that resolved
geometry with its children. Insets are layout pixels, not scaled radius tokens.

`launcher.dart` exposes the optional exclusive `ShellLauncher` contract and
`LauncherContext`: immutable application/history snapshots, visibility, localized
labels, host-owned focus and cursors, icon rendering, and launch/dismiss callbacks.
IDs are opaque and shared between catalog entries and recent history. Hosts retain
catalog identity until its contents or locale change. Implementations own their
search/navigation state; the runtime owns native input, activation and transitions.
The reference implementation lives in `plugins/denial_launcher`.

### Shortcut actions

Plugins can contribute arbitrary operations to Settings → Shortcuts → Denial
actions using `actions.dart` (inside a `@Plugin()` library):

```dart
@Provides(ShellAction)
class ShowSearch implements ShellAction {
  String get id => 'my_plugin.showSearch'; // Stable across releases.
  String get provider => 'My plugin';
  String label(BuildContext context) => 'Show search';
  String description(BuildContext context) => 'Open the plugin search panel';
  void invoke(ShellActionContext context) {
    // Call your plugin's controller or context.services public operations.
  }
}
```

Import `package:denial_sdk/composition.dart`,
`package:denial_flutter_sdk/actions.dart`, and Flutter widgets. Labels can use
localizations from the supplied build context. Handlers may return `Future<void>`.
The reference desktop receives the generated action collection automatically.
Saved shortcuts retain the ID while the provider is disabled; plugins must keep
IDs stable. There is no native enum to extend when introducing another action.
The action contract supplies operations, not automatic key assignments.
