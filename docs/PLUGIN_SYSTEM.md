# Denial plugin system: agent implementation contract

Status: accepted architecture; SDK/composition implementation present, manager integration validation underway.
Decision date: 2026-09-27.
Audience: agents designing, implementing, reviewing, or documenting Denial plugins.

Companion contract: [Plugin Manager distribution and backend](PLUGIN_MANAGER.md).
Read both for manager work. The companion records Git-first plugin distribution,
installed SDK distribution, the catalog, and multi-package repository selection.

This document records the final architecture agreed with the user. It supersedes
earlier brainstorming about runtime plugin registries, arbitrary source rewriting,
and plugins limited to adding panels. It does not authorize implementation or
deployment. Follow repository `AGENTS.md` for execution and validation constraints.

MUST/MUST NOT identify architecture requirements. Proposed identifiers, directory
names, and code examples illustrate contracts; they are not existing APIs.

## 1. Objective and boundaries

- Users select desktop functionality by enabling and disabling plugins.
- Plugins can supply UI, behavior, layout, policies, and services through public
  contracts. They are not restricted to isolated widgets or additive overlays.
- The reference desktop is assembled from first-party plugins. It is not a
  privileged monolithic implementation with special third-party attachment points.
- A default desktop preset selects a coherent set of those plugins.
- Users can disable default plugins and select alternatives, subject to dependency
  and required-capability checks.
- Plugins may publish new contracts and depend on other plugins. The system must
  accommodate alternative desktop architectures, not just the current desktop.
- An alternative shell composition can replace the complete reference desktop
  while retaining Denial's platform services and compositor integration.
- Flutter remains embedded in the compositor and owns desktop composition.
- Native resource lifetimes, Wayland correctness, authentication enforcement, and
  recovery remain platform responsibilities. Dart plugins do not gain unimplemented
  native capabilities simply by supplying different UI.

Design around reusable platform primitives and extensible contracts, not a list
of special cases for the first demonstration plugin. No architecture guarantees
permanent compatibility with arbitrary internal changes; version public contracts.

## 2. Compilation and activation model

The plugin manager is a build-time composition tool. Plugin selection, discovery,
dependency resolution, provider selection, and registration-code generation happen
before Flutter compilation.

```text
user-selected plugin packages
  -> Pub dependency resolution
  -> static discovery and contract validation
  -> deterministic composition generation
  -> Flutter AOT compilation
  -> existing shell refresh mechanism
```

The result is one ordinary compiled Flutter shell application with a fixed plugin
composition. Enabling, disabling, or updating a plugin changes build inputs and
requires generating/building the resulting composition, or reusing a verified
cached build with identical inputs.

The resulting application MUST NOT require:

- runtime filesystem/package scanning for plugins;
- `dart:mirrors` or another runtime reflection mechanism;
- dynamic Dart module loading;
- runtime enable/disable or dependency resolution;
- a runtime plugin registry that decides which implementations to activate;
- runtime `Plugin.configure(registry)` calls to assemble the selected plugin set.

Ordinary object construction, initialization, widget lifecycle, service startup,
reactive state, and disposal still occur at runtime. Build-time activation means
deciding and generating the composition, not executing Flutter widgets during a
build. Generated factory calls and static provider wiring are permitted.

## 3. Package boundaries

The SDK is the sole public Denial platform API. `denial_sdk` owns pure Dart models
and composition contracts; `denial_flutter_sdk` owns the Dart platform client,
bootstrap, reactive services/controllers, rendering/input primitives and shared
assets. Neither SDK may depend on a UI plugin or `denial_dart_shell`.

```text
generated application
  +-> denial_flutter_sdk -> denial_sdk
  +-> first-party plugins -> SDK
  +-> third-party plugins -> SDK

native compositor -> Wayland/engine/resource/authentication enforcement
```

`dart_shell` is only a development application selecting plugin providers. Its
old public runtime and default-shell facades are removed. The reference plugin
owns the complete stock desktop/mobile UI, including its stock application
screens. It imports public SDK libraries exactly like an external plugin.
It may initially remain one large plugin; splitting its presentation into more
packages is independent of achieving the SDK boundary.

This clarifies the earlier illustrative runtime-package split: the SDK includes
Dart-side native integration and its managed providers, including low-level APIs.
Rust remains authoritative for native lifetimes, protocol correctness,
authentication, composition/recovery and capabilities. Moving an API into the SDK
does not implement a new native operation or delegate enforcement to plugins.

Generated entry points use SDK bootstrap directly. Plugin planning rejects old
runtime dependencies and private SDK imports. Do not retain compatibility facades
or duplicate implementations in the old application. UI plugins own layout and
presentation policy; they reuse SDK providers and the shared bridge rather than
creating parallel native channel handlers. Root plugins can compose low-level
SDK primitives without importing any default UI.

Public interfaces, provider lifetimes, models and contribution contracts belong
in the SDK. No particular default widget hierarchy is a platform contract. See
[custom shells](CUSTOM_SHELLS.md) for complete-root responsibilities and
[plugin development](PLUGIN_DEVELOPMENT.md) for authoring APIs.

## 4. Pub is the dependency authority

Plugin-to-plugin dependencies MUST be declared in the plugin's `pubspec.yaml`.
Do not invent a second dependency manifest or separately maintained plugin
dependency graph.

```yaml
# Illustrative package names and versions, not existing packages.
name: classic_taskbar
dependencies:
  denial_sdk: ^1.0.0
  application_catalog: ^1.0.0
```

If `application_catalog` is a plugin, selecting `classic_taskbar` brings it into
the composition automatically. Pub resolves compatible package versions; the
plugin manager discovers plugin contributions within the resolved application
dependency closure.

Rules:

- Record user-selected root plugins separately from automatically required plugins.
- An installed package is not necessarily a plugin. SDKs, API packages, and normal
  Dart libraries do not activate merely because Pub resolved them.
- Build/dev tooling dependencies MUST NOT accidentally become runtime plugins.
- A required plugin cannot be omitted while an enabled dependent requires it.
  Report the dependent chain and resolve the selection before compilation.
- Removing a root can remove dependencies no longer reachable from another root.
- Persist the resolved Pub lockfile with the composition inputs.
- Derive dependency information from Pub's result; do not maintain a contradictory
  resolver alongside Pub.

Pub resolves packages, not semantic capability conflicts. The composition builder
must separately validate the contracts supplied by the resolved plugins.

## 5. Static discovery and generated composition

Use Dart source analysis to discover declarations and resolve actual types.
The `analyzer` package is the proposed foundation. `build_runner`/`source_gen`
are possible orchestration tools, not required architectural dependencies.

Annotations such as `@Provides` are Denial-defined SDK APIs. They are
not built-in Dart functionality. Dart annotations and type references supply
metadata; the plugin manager supplies discovery and generation semantics.

Illustrative declaration:

```dart
@Provides(DesktopPanel)
class ClassicTaskbar implements DesktopPanel {
  // Implements the public contract.
}

@Provides(WindowFrame)
class ClassicWindowFrame implements WindowFrame {
  // Implements the public contract.
}
```

Illustrative generated application:

```dart
void main() {
  runDenialShell(
    panels: [ClassicTaskbar()],
    windowFrame: ClassicWindowFrame(),
  );
}
```

The builder must resolve declarations to their library/type identities, validate
contract conformance and construction requirements, and generate imports and
statically checked calls. Do not use unqualified class-name string matching as
the contract identity. Diagnostics must identify source package and declaration.

The resolved package configuration locates package sources. Discovery must be
restricted to the intended plugin/application dependency closure, rather than
indiscriminately activating every package found in `.dart_tool/package_config.json`.

The SDK defines `@Plugin()` on contribution libraries, `@ExtensionPoint` on public
contracts, and `@Provides(ContractType)` on implementation classes. The manager now analyzes marked libraries under a package's `lib/` within the
selected application dependency closure, excluding tests, examples, and build
tooling. It MUST NOT reintroduce runtime entry-point loading or duplicate Pub
dependencies. Current constructor wiring supports public unnamed constructors,
typed contracts, optional nullable contracts and ordered contract collections;
other factory/build-script mechanisms require explicit design.

Public contract references should be actual Dart types. Package IDs, source
locations, user selections, and serialized lock records naturally use strings.
There is no requirement to eliminate strings from build metadata.

## 6. Build-time programmable composition

Support a path for Dart-authored build logic when declarations alone cannot express
composition. Such logic runs in the plugin manager's build process and operates
on source declarations/composition data to emit code.

It MUST NOT require importing and executing Flutter widget implementations in an
ordinary Dart command-line process. Analyze Flutter source statically and emit
references to runtime implementations instead.

Exact script API, ordering, execution isolation, allowed side effects, and cache
input declaration require design before implementation. Do not introduce an
unrestricted script runner as an undocumented shortcut. If scripts can observe
untracked inputs, do not claim deterministic/reproducible builds or reuse caches
as though those inputs did not exist.

This programmable path does not adopt arbitrary rewriting of shell method bodies
as the normal plugin mechanism. Generate composition against public contracts.

## 7. Contracts and composition rules

The plugin loader must remain generic. Domain concepts belong to versioned public
contracts, including contracts published by plugins.

Useful general mechanisms include:

- supplying an implementation of a contract;
- selecting an implementation for an exclusive capability;
- contributing multiple implementations/items to a collection;
- explicitly composing decorators/wrappers where a contract supports them;
- connecting typed commands, events, services, and state;
- declaring ownership and lifecycle of resources.

The generated application may contain these normal runtime abstractions. It must
not rediscover or resolve its plugin set at startup.

Define cardinality and requirements per contract. Optional collections can be
empty. Required exclusive capabilities need one selected implementation. Multiple
candidate providers must not silently win by installation or filesystem order.
Generate explicit selection/composition, or fail with actionable diagnostics.

Support deterministic ordering where order has meaning. Dependency relationships
alone are not a universal ordering rule for UI, wrappers, or service startup.
Define initialization/disposal and dependency-cycle behavior before relying on it.

Allow composition at multiple scales, including the complete shell. Do not make
the default desktop's widget hierarchy the only representable desktop structure.
Public composition data may support rearrangement and selection; private Flutter
implementation details must not become implicit permanent compatibility promises.

## 8. Installer/build pipeline

1. Determine the installed/running Denial source identity and engine compatibility
   inputs from authoritative metadata. Do not fetch a moving branch or infer the
   release from Cargo/Dart manifest versions.
2. Materialize the matching shell/platform source in a dedicated build workspace,
   including generated protocol packages and required assets/build inputs.
3. Fetch user-selected plugins and resolve their declared Pub dependencies. Record
   exact source identities and integrity information for the resulting inputs.
4. Discover typed contributions and execute supported build-time composition logic.
5. Validate requirements, selected providers, ordering, and compatibility.
6. Generate the root application's dependencies, imports, factories, and composition.
7. Analyze and compile an AOT bundle with Denial's matching pinned toolchain/engine.
8. Stage the bundle in a new directory and validate it before activation.
9. Invoke the existing native-controlled shell refresh path.

Keep the active shell running while preparing the replacement. Build failures must
leave the active composition usable. Preserve the packaged recovery bundle and
retain sufficient previous-build/configuration information for rollback.

Do not overwrite active mapped libraries or truncate files used by the running
shell. Ordinary plugin composition changes do not require changing the native
engine. Do not rebuild Rust or the Flutter engine for each plugin installation.

Source fetches, toolchain setup, local runtime transitions, and validation remain
subject to `AGENTS.md`; this design does not authorize restarting a local session.

Cache keys must cover source/SDK identity, resolved plugins and dependencies,
generation tooling and inputs, selection/order, toolchain/engine compatibility,
target architecture, and build configuration. Do not promise instant rebuilds or
reproducibility without measurement and input accounting.

## 9. Refresh, persistence, distribution, and trust

Reuse existing shell refresh and packaged-shell recovery infrastructure. Do not
design a second refresh engine or claim that refresh needs to be invented.
Inspect the current bundle preparation/validation paths before integrating the
builder; existing custom-optimized support is profile-oriented. A release custom
bundle may need integration changes, not a new runtime replacement mechanism.

Ship a precompiled default composition. Users do not need a compiler for initial
use. Custom composition builds require the compatible build tooling, which can be
cached and reused.

The planned manager installs plugin source packages from Git and lists built-ins
alongside entries from a Denial-owned YAML catalog. SDK packages ship in the
matching installed compiler kit; SDK and plugin publication to pub.dev is optional.
Authors manually configure local SDK overrides and editor paths as documented in
[plugin development](PLUGIN_DEVELOPMENT.md). Multi-package repositories use
package-level selection and repository-relative paths. See
[PLUGIN_MANAGER.md](PLUGIN_MANAGER.md) for the accepted distribution/backend
contract and remaining decisions. Pub remains the dependency authority. Local
development/installations should use the same composition rules.

These plugins compile into trusted shell code and share its process/failure domain.
Compile-time discovery is not a runtime security sandbox. Do not present package
signatures, interface conformance, or build success as proof of harmless behavior.

Persist selection and resolved build provenance separately from ephemeral runtime
state. Compatibility checks, last-working rollback, startup recovery, and durable
custom-selection behavior need explicit implementation verification. Existing
refresh support alone does not establish that these are all implemented.

## 10. Platform boundaries and source anchors

- Public Dart platform services, controllers, surface/input primitives and
  bootstrap live in `packages/denial_flutter_sdk`; pure contracts/models live
  in `packages/denial_sdk`.
- The full reference UI lives in `plugins/denial_desktop`. Panel, launcher and
  action contributions are consumed there using public SDK contracts.
- There is no reusable `denial_dart_shell` API. The generated composition does
  not depend on or copy assets from that application.
- Work-area modeling still includes one selected panel's reservation. General
  multi-panel geometry must keep native layout and Flutter presentation consistent.
- Native decoration negotiation and configure/commit ownership remain in
  `compositor/src/bin/deniald/wayland_frontend`.
- Refresh, recovery and the trust boundary are documented in
  [UI development](UI_DEVELOPMENT.md).

General geometry APIs must consistently account for outer frame, client content,
per-edge insets, input ownership, client configure sizes, popup coordinates,
minimum sizes, fullscreen/maximize, tiling, and animated/overview presentation.
Do not solve these with plugin-specific branches in core.

Decoration APIs must distinguish client preference, negotiated ownership, and
relevant X11 hints. Presence of an XDG decoration object does not mean the client
draws its own title bar. Follow protocol configure/commit state; do not infer
decoration ownership from application names or visual inspection.

## 11. Demonstration scenario, not an architecture boundary

The user proposed a plugin composition that:

- adds a taskbar;
- removes the default top CPU/GPU/etc. cards;
- supplies title bars with window controls;
- avoids adding title bars where clients own decorations.

Use this as an integration exercise, not as the list of capabilities the system
is allowed to support. Taskbar appearance, grouping, title-bar buttons, and chosen
desktop organization belong in plugins. Core changes must be general SDK/runtime,
protocol, or composition infrastructure.

Validate dependency closure, typed discovery, provider conflicts, generated builds,
disabled-plugin absence, default-preset behavior, geometry/input correctness,
decoration negotiation, refresh, and recovery as applicable. The user owns visual
validation. Never trigger visible test events or inspect screenshots without the
authorization required by `AGENTS.md`.

## 12. Superseded approaches / do not reintroduce

- A runtime plugin registry populated by imported plugins calling `configure()`.
- Treating imports alone as activation or relying on top-level registration effects.
- A second manifest that duplicates plugin dependencies from `pubspec.yaml`.
- Requiring users to manually enable plugin dependencies.
- A privileged monolithic default shell that third-party code can only decorate.
- An extension system restricted to the first taskbar example.
- Arbitrary AST/source rewriting or raw patches as the supported default mechanism.
- Assuming `@Provides`, `@Replaces`, or `@Wraps` are existing Dart features.
- Depending on Dart's discontinued macro project or experimental dynamic loading.
- Runtime reflection/scanning to discover the enabled composition.
- A process-per-plugin architecture as the selected design.
- Treating compile-time composition as execution of Flutter UI during the build.

## 13. Implementation decisions and remaining boundaries

The manager now resolves annotated types, validates constructor injection and
contract cardinality/order, emits direct static wiring, persists selected roots
and Pub pins, and integrates sealed bundles with native startup/recovery. Its
README and the companion contract describe the implemented APIs and validation.
Earlier illustrative syntax does not supersede those actual APIs.

The following boundaries still require design or publication work:

- optional subdivision of the large reference UI plugin and public API/versioning policy;
- factory injection beyond supported public unnamed constructors;
- build-script contract, declared inputs, and execution isolation;
- explicit composition-owned resource lifecycle beyond ordinary widget/owner
  disposal (constructor dependency cycles already fail during planning);
- future persisted-schema migrations (current schemas reject unsupported versions);
- store source provenance, package verification, and publication workflow.

The initial SDK lives in [packages/denial_sdk](../packages/denial_sdk/README.md):
typed contribution metadata, shared application/window-action/system models, and
analyzer tests. [packages/denial_flutter_sdk](../packages/denial_flutter_sdk/README.md)
adds typed surface contracts, service injection, theme, effects, and input-region
primitives. [plugins/denial_top_bar](../plugins/denial_top_bar/README.md) owns bar
presentation and uses those public APIs without importing shell internals.

The handwritten development app and generated applications both instantiate the
selected `ShellApplication` provider and call SDK bootstrap. The default provider
owns its UI directly; it does not delegate to a runtime-owned desktop. The SDK
provides native integration and shared primitives; the reference plugin supplies
its placement policy, reservations, transitions and tray/menu presentation.

Desktop UI placement uses the SDK's `ShellSurface` collection. Contributions
specify arbitrary bounds, output selection, scene layer and visibility from live
scene facts. The reference desktop mounts those declarations through SDK planes;
it has no panel-position slot or desktop-clock grid. `ShellSurfaceContext` supplies
state snapshots, an event stream and public services. Temporary hiding preserves
state and uses the SDK input/fade lifecycle, including separate glass fades. The
plugin authoring API is `surfaces.dart`; root hosting is `surface_hosting.dart`.
Temporary popup instances use `popups.dart`, separately from contributions.
Surface events report environment changes rather than every host rebuild.

Native reservations are a distinct optional exclusive `ShellWorkArea` contribution.
Its current single-provider cardinality reflects the native protocol's one shared
edge/thickness/output selection, not a limit on surface count. Conflicts fail
composition validation. General per-output, multi-edge native reservations require
extending that protocol. Plugin placement and native reservations must not be
silently conflated.

The desktop clock is independently selectable. Its reusable clock face is an
ordinary helper package without contribution annotations; mobile and lock UI can
reuse it without implicitly selecting the desktop clock contribution.

Collection distribution: `denial_taskbar` lives at
`plugins/denial_taskbar` in the public `denialwm/denial-plugins` repository.
The collection root is a source container, not a Dart package. The shell pins
that package by repository, path, and exact commit; generated offline workspaces
vendor the resolved package. Plugin authors still use ignored local SDK overrides
as documented in `PLUGIN_DEVELOPMENT.md`. Plugin installation receives the SDK
and compiler kit from Denial and does not require publishing either SDK to pub.dev.


## Automatic manager setup

Users select plugins and apply them; they MUST NOT configure compiler/runtime
paths, backend flags, or development modes. The installed Denial payload supplies
matching source templates, compiler inputs, SDKs, and native control. The app
prepares its writable cache automatically. Only `DENIAL_SDK_PATH` may optionally
substitute the SDK pair for development. See `PLUGIN_MANAGER.md` section 14 for
the implementation and validation boundary.

## Advisory compatibility declarations

Plugins may now declare `denial_plugin` schema 1 metadata in their Pub manifest
for a fast selection preflight: a display name, provided contract counts, and
required contract min/max counts. See `PLUGIN_MANAGER.md` section 16. These are
serialized public Dart type identities and advisory author claims. Pub still
resolves dependency versions/closure, and actual-type analysis still validates
all contributions before compilation. Immediate checks block known conflicts
without introducing a hardcoded list of incompatible plugins.

## Desktop launcher extraction

`plugins/denial_launcher` now supplies the optional exclusive `ShellLauncher`
contract from `denial_flutter_sdk/launcher.dart`. `ReferenceDesktop` accepts a
nullable launcher through generated constructor injection, independently of its
panel. The built-in preset and manual development entry point select the launcher;
existing saved plugin selections are not changed automatically.

The plugin owns launcher presentation, filtering, suggestions and keyboard
navigation. Its public context supplies application/history snapshots, localized
labels, icons, cursors, focus and semantic actions. Native launching and recents persistence use SDK services. The consuming root
plugin owns surface placement, transitions and input publication through SDK APIs.
With no provider the desktop omits the launcher and its edge trigger and ignores
launcher-open actions. Alternative providers use the same contract; conflicts fail
before compilation. The mobile home grid remains part of the mobile composition.

## Plugin-provided shortcut actions

`ShellAction` in `denial_flutter_sdk/actions.dart` is a `zeroOrMore` public
contract. Plugins annotate implementations with `@Provides(ShellAction)`. The
builder injects the selected implementations into the desktop's `actions` list;
custom shells can mount the SDK's `ShellActionsBinding` with their generated
list and public `ShellServices`. This does not change build-time composition.

Each action supplies a stable package-qualified ID, localized label/description,
provider name, and an `invoke(ShellActionContext)` handler. The ID, not its label,
is saved in shortcuts. `native.*` is reserved. Catalogs allow at most 256 actions,
128 KiB of JSON, 256-byte labels/provider names and 2048-byte descriptions; text
must not contain control characters. Duplicate or invalid descriptors fail the
host binding instead of silently overriding another handler.

The running shell publishes the complete catalog over one generic native bridge.
Rust matches shortcut IDs and sends generation-tagged invocations back to the
shell. It does not contain per-plugin enums or implementations. Shell replacement
clears the catalog and pending calls; the new host publishes a fresh generation.
Locked sessions cannot dispatch plugin actions. Native authentication and service
policy still apply to operations requested by handlers.

Settings lists native actions alongside the current plugin catalog, including
provider names. Its open shortcuts page refreshes the catalog periodically.
Removing a provider makes saved bindings unavailable without deleting them;
restoring the same ID makes them usable again. Plugins do not override user
shortcut choices or silently install suggested bindings.

The Launcher plugin provides `denial_launcher.openApplications`. Shortcut schema
11 migrates legacy `openApplications` targets to that ID, preserving customized
keys and removed bindings. The default SUPER binding uses this ID. Without the
Launcher contribution, it cannot open the launcher.

The initial generic bridge requires one native update. Subsequent plugin action
additions/removals require only the normal composition build and live shell
refresh, with no Rust rebuild or compositor restart. Build kits declare required
native capabilities in their source identity; activation checks the running
compositor before attempting a shell replacement.
