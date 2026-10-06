# Shell and SDK cleanup candidates

Reviewed 2026-09-29; cleanup completed 2026-09-30.

1. **Keep window helpers:** unused here, but useful public primitives for third-party kiosk/mobile shells: filtered windows, actions and a primary surface. [ShellPrimaryWindow](../packages/denial_flutter_sdk/lib/src/core/shell_windows.dart) now accepts shell-chosen content padding.
2. **Removed legacy lock-file bridge:** no callers/writers remained. Deleted its watcher, file mirroring, provider and exports; lock requests and authoritative state use native authentication.
3. **Fixed rotation placeholder:** removed the local boolean, toggle and nonfunctional quick-settings tile.
4. **Fixed duplicate brightness control:** quick settings now shares [DisplayBrightnessController](../packages/denial_flutter_sdk/lib/src/state/display_brightness.dart) with Settings, including native updates and debouncing.
5. **Fixed artificial async commands:** audio/brightness/screenshot sends return `void`; actual reads, acknowledgements and delays stay asynchronous. Screenshot service requires a bridge, eliminating silent no-ops.
6. **Fixed UI ownership:** SDK [ShellController](../packages/denial_flutter_sdk/lib/src/state/shell_controller.dart)/`ShellState` retain native snapshots, focus and security. Reference gestures, shades, keyboard, transitions, profile and geometry live in [the plugin](../plugins/denial_desktop/lib/src/state/reference_shell_controller.dart), sharing the existing bridge and snapshot index.
7. **Split host interface:** [services.dart](../packages/denial_flutter_sdk/lib/services.dart) now defines focused window, application, desktop, workspace, telemetry, media, presentation and tray contracts. `ShellServices` aggregates them for host injection, preserving existing calls; system-bar features use the narrow contracts.
8. **Removed desktop shared scope:** dashboard, launcher hosting, scene and window presentation are ordinary libraries with explicit imports/inputs. No `DesktopShell` parts or import cycles remain. [Scene selection](../plugins/denial_desktop/lib/src/desktop/desktop_scene_selection.dart) stores immutable live-placement IDs directly, replacing `Expando` bookkeeping.

All requested cleanup is implemented; the useful public window helpers remain. Moving policy into its owner mainly improves boundaries, not LOC.

Validation: plugin-check, shell analysis, real-composition checks, import-cycle audit and normal/generated release AOT builds. Rendered behavior has not been validated.
