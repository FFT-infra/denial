# Denial wire format

Protocol version 1 uses FlatBuffers 25.9.23 for structured messages. The root
is `Denial.Wire.Envelope` with file identifier `DENW`. Generated Dart and Rust
code is committed, so normal builds need neither network access nor `flatc`.

Regenerate the committed bindings with the exact compiler version recorded in
`protocol/FLATBUFFERS_VERSION`:

```sh
tools/generate-denial-wire
tools/generate-denial-wire --check
```

The check form generates into a temporary directory and compares both
languages without modifying the checkout.

Every structured envelope has a nonzero sequence number. Native verifies the
FlatBuffer, direction, version, size/count limits, enums, flags, identities,
strings, geometry, request rules, and topmost-first input-window ordering
before it copies callback-owned bytes. The retained input layout is an
immutable owned buffer swapped as one unit.

Settings use typed `SettingsRequest` and `SettingsResponse` payloads. The
shared shell document is bounded to 256 KiB and revision checked; the native
keyboard payload bounds layouts, XKB options, repeat timing, and active group.
Rust sends keyboard state with request ID zero when a physical or XKB-defined
layout shortcut changes the active group.

Input-layout rectangles accept every finite, strictly positive width and
height. In particular, shell-region subtraction can legitimately produce
strips narrower than one logical pixel; rejecting one would discard the whole
atomic layout and leave native hit testing on an obsolete snapshot. Configure
requests retain their separate 64-pixel minimum, and fixed placement packets
retain their one-pixel minimum.

InputLayout flag bit 3 specifies an active presentation; bit 4 selects mobile
geometry when set and desktop geometry when clear. Without bit 3, native keeps
its current presentation for compatibility. Scene publishers set these flags
even with no client windows. Changing presentation releases mobile geometry
and its status inset, restores retained desktop targets, and reenrolls windows
in the selected desktop layout. Startup security policy remains independent.

`ConfigureSystemBar` publishes the complete active work area, including window
padding. A visible bar requires live output IDs and positive thickness. A hidden
bar uses an empty output list and zero thickness; its padding may still be
positive for desktops without a panel. Mobile presentation publishes hidden,
zero-thickness, zero-padding policy. Entering desktop resolves a live panel
output even when the previous layout had no reservation, then republishes the
desktop panel and padding settings. Native legacy `-1` metric values still keep
the corresponding metric unchanged.

`MinimizeWindow` targets a nonzero window ID and accepts no flags. The native
window manager owns the transition for both client and local Flutter windows,
including focus, tile membership and window-state publication. `FocusWindow`
restores a minimized window through the same native manager.

## Fixed window-placement packet

On the ordered `denial/wire/to_flutter` stream, a message beginning with
`DENP` carries exactly 80 bytes in little-endian order. Structured messages on
the same stream retain the FlatBuffers `DENW` file identifier. Keeping both
formats on one channel preserves the ordering of placement, activation,
snapshots, actions, and cursor state from the pre-migration bridge.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `DENP` |
| 4 | 2 | protocol version (`1`) |
| 6 | 2 | message kind (`2`, window placement) |
| 8 | 4 | exact packet length (`80`) |
| 12 | 8 | sequence number |
| 20 | 8 | unsigned window ID |
| 28 | 8 | signed monitor ID |
| 36 | 8 | signed workspace ID |
| 44 | 1 | phase: begin `0`, update `1`, end `2` |
| 45 | 1 | change: move `0`, resize `1` |
| 46 | 2 | reserved, must be zero |
| 48 | 8 | logical x (`float64`) |
| 56 | 8 | logical y (`float64`) |
| 64 | 8 | logical width (`float64`) |
| 72 | 8 | logical height (`float64`) |

Readers reject a wrong magic, version, kind, length, reserved value, zero
window ID, invalid monitor/workspace ownership, unknown enum, non-finite
number, or width/height below 1. Begin and end are
never coalesced. Update packets may be coalesced later only if measurement
shows that it helps and behavior tests still pass.

The Dart shell retains a decoder for the previously designed fixed `DEND`
drag-icon packet, but the current native compositor does not emit it. `DEND`
is therefore not part of the active version 1 wire contract.
