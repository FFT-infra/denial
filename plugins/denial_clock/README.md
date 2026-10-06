# Desktop clock plugin

Provides an independently selectable `ShellSurface`, positioned on the main
output's desktop work area. It owns its placement and visibility policy and reads
the SDK clock/power providers. The non-contributing `ui` helper package owns the
shared clock face used by desktop, mobile and lock UI; depending on that helper
does not enable this desktop contribution.
