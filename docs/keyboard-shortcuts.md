# Keyboard window resizing

These native shortcuts resize the focused window in stacking, dwindle, and
scrolling layouts:

| Default shortcut | Action | Effect |
| --- | --- | --- |
| `Super+Minus` | `resizeShrinkWidth` | Narrower |
| `Super+Equal` | `resizeGrowWidth` | Wider |
| `Super+Shift+Minus` | `resizeShrinkHeight` | Shorter |
| `Super+Shift+Equal` | `resizeGrowHeight` | Taller |
| Unbound | `resetWindowHeight` | Restore the default height for the current layout |

Change bindings or assign **Reset window height** in Settings → Shortcuts.
Holding a grow/shrink shortcut repeats at the configured keyboard repeat rate.
The key names refer to physical keys, as with Denial's other native shortcuts.
Shortcut schema version 10 adds these defaults to older configurations without
replacing custom bindings on the same keys. Removing a binding after migration
keeps it removed.

The default step is **2% of the focused window's output work area**, along the
axis being resized. To choose a different step, set `layout.keyboardResizeStep`
in `~/.config/denial/settings.json` (or `$XDG_CONFIG_HOME/denial/settings.json`):

```json
{
  "layout": {
    "keyboardResizeStep": "32px"
  }
}
```

Merge the property into the existing `layout` object. Accepted string values
are positive logical pixel amounts such as `"32"` or `"32px"` (up to 32768),
or percentages such as `"5%"` (up to 100%). Fractional values are allowed;
each resize is rounded to at least one logical pixel. Omitting the property
uses `"2%"`. Valid file edits are reloaded by the running session; the settings
control API can also update the property.

For floating windows, resizing keeps the top-left position and the other
dimension unchanged, and honors client minimum and maximum sizes. Reset height preserves horizontal
geometry, respects size limits, and is idempotent. Decorations and reserved
work-area space are excluded from the reset content height.

For dwindle tiles, resizing adjusts the nearest shared split on the requested
axis. The focused side grows or shrinks and its siblings receive the remaining
space. Manual resizing preserves the current split orientations. Reset height
restores an equal split at the nearest vertical boundary, subject to client
minimum sizes. An axis with no shared split already fills
its available space and does not resize.

For scrolling tiles, resizing adjusts the nearest internal split when present.
Otherwise, width changes the column width in horizontal scrolling, and height
changes the tile height in vertical scrolling. Unsplit tiles fill the cross
axis. Reset height equalizes the nearest vertical split, or restores the default
60% tile height in vertical scrolling. Shared splits retain their existing
10–90% limits; scrolling tile extents retain their 25–100% limits. Client minima
can require more space. At a size limit, repeated keys do not spill into an outer
split or accumulate hidden steps.

Maximized or fullscreen clients, locked shell geometry, mobile sessions, and
windows undergoing an interactive grab are not resized. Local Flutter windows
use their normal native placement path; shell fullscreen remains protected.
Preset cycling is outside this version of the feature.
