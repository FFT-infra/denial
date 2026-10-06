# Application theming

The **Theme** card in Appearance includes **Theme supported application using Denial styling**,
disabled by default. Enabling it applies supported settings; changing Window
glass opacity updates them. **Re-apply** repeats discovery for newly installed
applications. Disabling removes Denial's managed block, if present.

The initial adapter maps `appearance.glass.windowOpacity` directly to Kitty's
`background_opacity`. Discovery checks only the expected configuration file
(`$XDG_CONFIG_HOME/kitty/kitty.conf`, falling back to
`~/.config/kitty/kitty.conf`) and an executable named `kitty` on `PATH`.
If neither exists, nothing is created. An existing empty configuration file is
enough for installations outside `PATH`. Custom config paths, package discovery,
and included configuration files are outside this initial implementation.

The adapter removes active `background_opacity` entries from the main file and
appends a block such as:

```conf
# BEGIN Denial managed appearance: 1-3fe3333333333333
# Changes made to this block will be lost
background_opacity 0.6
# END Denial managed appearance
```

The ID combines the adapter format version with the opacity's exact numeric
identity. It stays the same across unrelated settings edits and restarts. A
matching ID skips the write without inspecting the block's values, including
on Re-apply. A different ID replaces the complete block. Disabling removes the
block without restoring previously removed entries.

`deniald` queues synchronization at startup and after settings commits. One
worker coalesces updates and writes outside the compositor loop. Re-apply uses
the existing settings commit path, so no additional control protocol is needed.
Writes preserve existing symlinks and file permissions and use atomic rename.
Missing blocks are harmless; IO errors and unterminated blocks produce warning
logs and do not fail the settings operation.

Denial only updates configuration. It does not launch or restart Kitty, signal
it, or change its reload options. Kitty's existing reload behavior applies.

The implementation is in `compositor/src/bin/deniald/application_theming.rs`.
Its tests use temporary files and run with `tools/denial-pc compositor-test`.
