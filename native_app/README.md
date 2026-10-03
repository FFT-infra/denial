# Minimal native Flutter app runner

`denial-app` runs an existing release AOT bundle in its own Wayland process.
It reuses Denial's raw engine host, text editor and cursor decoder. Settings,
Welcome, Plugin Manager and the Polkit dialog use this runner for their windows
and input; none links a GTK runner. Flutter assets are assembled directly.

The rendering path is Flutter → reusable RGBA8 framebuffer → GPU blit →
alpha-capable EGL/Wayland window. Denial still supplies the desktop glass.
The runner preserves the application's alpha; it does not synthesize blur.
Before graphics startup, it appends `-GL_EXT_shader_framebuffer_fetch` to
`MESA_EXTENSION_OVERRIDE`, preserving other overrides. This avoids the engine
buffer transition that corrupts layers below the final backdrop filter on .188.
The workaround affects this app process; Denial's shell keeps its capabilities.
Old-size frames are discarded during resize. Frame callbacks pace animation;
the event loop sleeps until Wayland events or engine task deadlines arrive.

Build from the repository root (native dependencies: Wayland, EGL, GLES3,
libxkbcommon):

```sh
cargo build --manifest-path native_app/Cargo.toml --release --locked
cargo test --manifest-path native_app/Cargo.toml --locked
cargo clippy --manifest-path native_app/Cargo.toml --all-targets --locked -- -D warnings
```

Run from an existing Wayland terminal:

```sh
native_app/target/release/denial-app \
  --bundle settings_app/build/linux/x64/release/bundle \
  --engine dart_shell/build/linux/x64/release/bundle/lib/libflutter_engine.so \
  --app-id dev.denial.Settings --title Settings
```

`--overlay` presents a centered, undecorated wlr-layer-shell surface on the
overlay layer instead of a window. It takes exclusive keyboard focus, uses the
app ID as its namespace, and has the fixed `--width` and `--height`; the
application paints any transparency around its content. The Polkit dialog uses
it.

`--check` validates bundle components, AOT loading and the raw engine ABI
without starting Flutter or opening a window. Impeller is the default.
This repository builds Slimpeller, so Skia is unavailable in its engine.

The runner supports one window/view and seat, integer display scaling, resize,
pointer/buttons/scrolling, keyboard layout/compose/repeat, basic text editing,
cursor shapes and window close. Dart entrypoint arguments follow `--`.
Installed `denial-settings` and `denial-plugin-manager` executables find their
adjacent bundles; Settings also accepts `--welcome`, `--autostart`, and `--page=`.
Welcome retains its completion-marker check before opening a window.
Plugin Manager retains its installation descriptor beside the runner.

Settings file selection uses the external FileChooser portal, and Welcome web
links use `xdg-open`. The portal backend can be supplied by any desktop toolkit;
it does not handle Denial application windows or input. Accessibility, external
IME, clipboard, activation/single-instance handling, touch and platform plugins
remain outside this runner's current scope.

Flutter's Linux key-event JSON codec calls its XKB format `gtk`. That protocol
label remains required by Flutter; the runner obtains keyboard events directly
from Wayland and never calls GTK.

The source inclusion of the two private input modules is deliberate read-only
reuse for this first version. A small transaction type adapter satisfies the
text editor's import. This creates a checkout dependency, not a new public SDK
contract; extracting those modules later would require a separate Denial change.

Difficulty: moderate for this MVP because engine startup and platform logic
already exist. Correct GPU ownership, resize commits and scheduling are the
hard parts. Broader platform-plugin compatibility is a larger follow-up.
The user validated correct rendering and glass on .188 with framebuffer fetch
disabled on 2026-09-30. All standalone Denial apps now share that process-local
workaround through this runner.
