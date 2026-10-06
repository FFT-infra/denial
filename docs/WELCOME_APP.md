# Welcome

Welcome is a standalone application with the Wayland/GApplication identity
`dev.denial.Welcome`. Its launcher invokes `denial-settings --welcome`: the two
applications share the packaged GTK runner and synchronized settings host, but
have independent single-instance windows. Settings can remain open alongside it.

The five steps begin with a welcome screen and a Get started command, then show
authoritative shortcut bindings, select the existing window layout, select
transparency and appearance, and offer optional support links.
Layout and appearance use the normal settings controller and apply immediately.
Pointer move/resize gestures are native Super + left/right drag; keyboard actions
come from the current shortcut service, including unassigned actions.

The horizontal progress surface uses numbered circles with labels underneath
and the shared glass material with saved optical settings unchanged. The corner
commands are ordinary filled buttons without glass wrappers. Commands overlay the
scrolling sheet; trailing content padding lets its final rows clear the buttons.
Shortcuts start with resize and move, adapt to two columns, and use thin rules
between desktop, workspace and tiling groups. Neutral content surfaces and
contrast-checked accent labels keep controls readable.

Finish and confirmed Exit flush pending settings, atomically persist
`$XDG_CONFIG_HOME/denial/welcome` (default `~/.config/denial/welcome`), and close
only the Welcome window. Cancel makes no lifecycle change. The launcher always
opens Welcome, even after completion. Each full Denial startup launches the app
with `--autostart` after initial scanout and session environment publication.
This is independent of systemd and XDG autostart. Bounded diagnostics, test runs,
and Flutter bundle refreshes do not start it. The runner checks completion before
registering or activating the application, so completed setup cannot steal focus
from a manually opened window. The original state-directory marker is migrated
on startup without reopening completed setup. Remove the config marker to enable
automatic setup again.
Closing an unfinished window through the compositor does not mark it complete.

In stacking mode, Welcome ignores saved placement and centers on the opening
monitor after the client supplies its actual size. This one-time placement does
not recenter later moves or resizes. Dwindle and scrolling own placement normally.

`tools/denial-pc settings` builds both applications. `tools/denial-pc welcome`
also installs Welcome's development launcher entry. All commands
run outside the sandbox. Do not rebuild over a bundle mapped by a running app;
build an isolated copy and use the following to point Welcome at that bundle:

```sh
DENIAL_SETTINGS_BINARY=/path/to/denial-settings tools/denial-pc install-welcome-entry
```

The app is localized in English and simplified Chinese. Donation destinations
are defined in `welcome_support.dart`, with separate English/Chinese Stripe
redirects, GitHub Sponsors, and the repository action. Only the Stripe redirect
for the active language is used by the localized Donate button. Browser launches happen
only in response to a button press. Visual validation belongs to the user.

Static analysis and a locked release app build validate the app without a
development engine.
