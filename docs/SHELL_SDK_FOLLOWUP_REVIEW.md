# Shell and SDK follow-up review

Reviewed 2026-09-30. Points 6–8 fixed; points 1–5 remain open.

1. **High — brightness loses edits:** [native feedback](../packages/denial_flutter_sdk/lib/src/state/display_brightness_model.dart) can replace newer slider intent; the next debounced write then sends that old value. Track pending intent separately from observed brightness.
2. **High — settings lose concurrent edits:** [conflict retry](../packages/denial_flutter_sdk/lib/src/settings/settings_store.dart) refreshes the document but reapplies the complete old typed projection. Concurrent changes to known shell preferences can be overwritten. Apply only the user's patch instead.
3. **Medium — brightness resets unnecessarily:** [controller rebuilds](../packages/denial_flutter_sdk/lib/src/state/display_brightness.dart) on every layout update, including workspace switches, cancel pending writes and reread every monitor. Reconcile output identities without resetting surviving outputs.
4. **Medium — screenshot outlives its owner:** [delayed capture](../plugins/denial_desktop/lib/src/state/quick_settings.dart) sends after disposal/rebuild; its generation guard protects only the final state update. Check the generation before dispatch.
5. **Medium — inconsistent power backends:** [Quick Settings](../packages/denial_flutter_sdk/lib/src/services/power_profile_service.dart) uses hardcoded `denia-powerd` paths and silently accepts failures; [the dashboard](../packages/denial_flutter_sdk/lib/src/services/desktop_power_modes_service.dart) uses D-Bus. Share a service reporting availability and failures.
6. **Fixed — independent bridge startup:** [DenialBridge](../packages/denial_flutter_sdk/lib/src/platform/denial_bridge.dart) connects all native reply channels at construction. Its provider lives independently of `ShellController`, which now owns cancellable window subscriptions. [Private domain clients](../packages/denial_flutter_sdk/lib/src/platform/bridge/) separate settings, configuration, windows/displays, input, audio/brightness and session operations behind the existing public API.
7. **Fixed — plugin preferences survive saves:** [NativeSettingsStore](../packages/denial_flutter_sdk/lib/src/settings/settings_store.dart) retains the full native document and overlays its typed projection, preserving unknown root/nested fields and refreshed plugin data after conflicts. Environment override maps still replace their contents so deletions work.
8. **Fixed — manager import cycle removed:** `fileDigest` lives beside the shared hashing helpers in [store.dart](../packages/denial_plugin_manager/lib/src/store.dart); builder, cache and workspace use that owner. Public barrel imports remain valid.

Point 6 cleanup: one shared transport owns native handlers, disposal and request IDs; one shared codec preserves window delta state. Unsolicited snapshots remain synchronous with texture metadata. Existing `start` callbacks remain available for compatibility; native reception no longer depends on calling it. The public facade is 507 lines, down from the former 2,909-line implementation; forwarding keeps the existing 99 methods/getters intact.

Evidence: actual brightness model reproduced an 80% edit reverting to 40%; remaining findings traced through callers/native handling. The current import audit covers 523 Dart library files with no handwritten cycles. Three pure Dart persistence regressions cover point 7. No UI events or Flutter development-engine tests were run.

Fix validation: plugin-check (analysis, 14 core SDK tests and 57 manager tests), all four real desktop composition checks, shell/core-test analysis, release shell compilation and import audit passed. The release-path compositor suite also passed before .188 deployment. The new Flutter bridge regression was analyzed but not run with a development engine.

.188 validation deployment: new compositor PID 3666 replaced 630; the mapped shell and engine hashes match the locally checked artifacts (`d8174331f084…` / `dca6786e931a…`). Native status is idle with no error, and the portal service is active. Matching Settings, Plugin Manager and compiler inputs are installed; plugin choices are preserved. The previous runtime is retained for rollback. Visual validation remains with the user.

Earlier open findings remain in [the SDK review](PLUGIN_SDK_REVIEW.md).
