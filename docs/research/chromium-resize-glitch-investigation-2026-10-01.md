# Chromium and Electron resize glitch investigation

Status: **resolved** as of 2026-10-01. The user visually validated the crop
canvas fix after a fresh login and reported that the glitch no longer
occurs. See [Root cause](#root-cause) and
[Fix](#fix-crop-canvas-presentation).

This document records the observed behavior, the evidence collected, the
changes that did not fix it, and the root cause found afterwards. Passing
compositor or engine tests must not be treated as evidence that the visual
defect is fixed. The user reproduced the defect after the final experimental
build and reported that nothing visibly changed; the later analysis below
explains why that experiment could not have had an effect.

## Observed behavior

- The defect occurs in native Wayland Chromium and Electron applications. It
  has not been observed in other application toolkits.
- The tested machine uses an AMD GPU and 1x output scaling. Xwayland and
  fractional scaling are not involved.
- A very brief incorrect frame can appear when resizing starts.
- A second incorrect frame can appear once when the pointer enters the window
  after resizing. If the pointer is already inside the window, the equivalent
  glitch occurs immediately during the resize.
- Tiling makes the pointer-entry case easy to reproduce because resizing one
  window can resize another window while the pointer remains outside it. The
  problem also occurs in stacking layouts, so tiling is not the cause.
- Slow-motion recording showed that the client frame content itself looked
  valid, but it was rendered at an oversized presentation extent and overflowed
  the window on both axes. The bad frame appeared larger regardless of whether
  the window had just grown or shrunk, so it was not simply the previous window
  size being displayed.
- The apparent transparency was over Chromium's content rather than an opacity
  change applied to the entire window. It may be the visual result of two
  differently placed or sized frames being mixed during the brief transition.
- The delayed pointer-entry glitch could reproduce even while Chrome was
  playing video. This matters because Chromium had continued submitting
  same-geometry video frames for roughly a second before the old-looking
  geometry became visible again.

## Instrumentation and evidence

A targeted `DENIAL_RESIZE_AUDIT` trace was added for Chromium/Electron windows.
It records configure and commit state, native scene metadata, Dart layout and
paint geometry, external-texture queue/advance/sample state, and pointer focus
transitions. It is gated and disabled during normal sessions. Wallpaper and
unrelated application activity are excluded because the first logs contained
too much unrelated wallpaper output.

The focused reproduction log was saved as
`/tmp/denial-focused-reproduction.txt`. One suspicious interval showed:

- at `18:58:45.374`, Flutter requested texture 20 with dimensions
  `1454 x 1792` while the current Chromium DMA-BUF was `1454 x 1318`;
- approximately 6 ms later, the requested dimensions changed to
  `1454 x 1318`.

This proved that a raster transaction could observe inconsistent requested and
buffer dimensions. It did **not** prove that this mismatch caused the visible
glitch. The scene-transaction experiment built around that interpretation made
no visible difference. [Root cause](#root-cause) shows that this mismatch
*is* the defect and that the experiment never engaged for it.

## Root cause

Chromium crops an over-allocated buffer through `wp_viewport` during and after
interactive resizes. In the focused log, window 20 has a 1422 x 1240 window
geometry inside a 1454 x 1282 buffer (client-side shadow margins). On the first
commit after the resize starts (`18:58:36.8487`), Chromium switches to a
**1454 x 1792** allocation whose viewport source is only 1454 x 1283, and keeps
growing the crop inside that allocation while the resize continues.

Dart lays each texture out from the published buffer size and source crop:
`windowPlaneTextureGeometry` draws the full buffer extent
(`bufferSize * target / source`) and relies on the window clip, so with the
over-allocated buffer the texture bounds are about 1454 x 1795. The engine has
no crop of its own: without an external-texture presentation it stretches
whichever image it resolves into those bounds. Dart metadata and the sampled
buffer travel through separate channels, so any frame that pairs one buffer's
layout with another buffer's image is scaled by the ratio of their
allocations:

- **Resize end and pointer entry.** After the resize settles, Chromium keeps
  presenting the cropped 1792-row buffer (`42.99`-`45.37`: `buf [1454, 1792]
  src [...1318]`, including same-geometry frames), and reallocates an exact
  1454 x 1318 buffer only when it next repaints for some other reason. In this
  log that was pointer entry: the pointer entered at `45.336`, Chromium
  committed the exact buffer at `45.3735`, the texture advanced at `45.3742`,
  and the engine resolved it at `45.3743` with **requested 1454 x 1792**, the
  previous Dart layout, because the matching Dart paint only ran at `45.3782`.
  That texture-only frame stretched 1318 rows into about 1795: about 36%
  oversized. This is the delayed pointer-entry glitch; it also explains why it
  survives video playback (video frames keep the cropped buffer) and why
  pointer-inside resizes show it immediately.
- **Resize start.** The mirror pairing, a new layout for the 1792-row
  allocation sampled with the previous exact 1282-row image, stretches by about
  40%. The native trace has no texture events in that interval (the detail
  budget was exhausted), so this direction is inferred from the same mechanism
  rather than directly logged.

Both pairings put a small image into bounds sized for the larger allocation,
so the bad frame is oversized whether the window grew or shrank, matching the
slow-motion recording. The exact-size buffer is not the window's previous size,
which is why "old window size" explanations did not fit. Only clients that crop
over-allocated buffers are affected, which is why only Chromium and Electron
showed it. Tiling makes pointer entry after a neighbouring resize frequent,
but layout policy plays no part.

### Why the final experiment changed nothing

The scene-transaction barrier classified a buffer as geometry-changing by
comparing `ExternalTexturePresentation` values (`same_scene_layout`). On the
desktop every surface texture is queued with an all-zero presentation
(`surface_pipeline.rs` set `presentation = Some(Default::default())`; only the
mobile content-inset path supplies a real one). Two zero presentations always
compare equal, so `scene_layout_changed` was never true for Chromium, no output
was ever marked `requires_scene_rebuild`, and the engine-side deferral in
`caef8836139` had no texture IDs to defer. The experiment was therefore a no-op
for this defect rather than evidence against the mismatch hypothesis. Even with
a corrected classification it would have been racy: the "next" Flutter scene
can be one built from metadata older than the buffer it samples.

## Experiments that did not fix the issue

### Niri-style configure pacing

Denial's interactive resize path was changed to keep only the newest requested
size while a previous size request was still waiting for a matching client
commit. State changes and the end of an interactive resize bypass the
size-only throttle.

Purpose:

- avoid flooding a client with configure sizes it cannot commit in time;
- make resize negotiation closer to Niri's more conservative Smithay flow;
- keep the committed buffer and authoritative requested geometry in a clearer
  sequence.

Result:

- the Chromium glitch remained;
- this pacing was therefore insufficient to explain either the resize-start or
  pointer-entry frame.

The pacing change remains in the current working tree because it is a separate
resize-policy change, not a demonstrated fix for this defect.

### External-texture cache retirement and cleanup

An earlier attempt added explicit render-thread cleanup and retirement for
external textures and DMA-BUF cache entries. It tried to prevent a destroyed or
superseded client buffer from remaining available to a later Flutter texture
sample.

Result:

- the delayed pointer-hover glitch remained;
- Chrome became severely laggy while resizing on the secondary output, while
  the same operation remained comparatively normal on the primary output;
- the cleanup/retirement change was reverted.

This regression is evidence against reintroducing broad cache pruning or
per-frame texture destruction without a more specific lifetime failure.

### Forced composed Chromium rendering

A diagnostic forced Chromium away from its usual direct imported-texture path
and through the composed multi-layer window path. The corresponding environment
flag was enabled only for the experiment.

Purpose:

- determine whether the bug belonged to the direct window-plane primitive;
- exercise Flutter's multi-layer composition and clipping path for the same
  Chromium content.

Result:

- the glitch was still visible in slow-motion recording;
- the incorrect frame was still rendered too large;
- the Chrome-specific forcing branch and its environment flag were reverted.

This argues against a workaround based only on selecting the composed path or
adding a Chromium-specific clip.

### Geometry-changing buffer and Flutter scene transaction barrier

The final experiment implemented the following rule:

> A buffer whose presentation extent or viewport mapping changed must not
> advance through a texture-only render. It must wait for a Flutter scene
> rebuild that contains the matching layer geometry. Same-geometry content,
> including video frames, retains the texture-only fast path.

The compositor classified changes to texture width, height, source rectangle,
and destination rectangle. It marked affected outputs as requiring a Flutter
scene rebuild and prevented the scheduler from servicing those updates through
an autonomous texture-only frame. Pending geometry-changing texture IDs were
attached to the next global Flutter scene transaction.

The experimental Flutter engine commit
`caef8836139d31f6a457333e080ce490376a088b` then deferred external-texture cache
invalidation until a framework scene had successfully acquired an authorized
native render target. Autonomous renders skipped texture IDs still waiting for
that scene.

Purpose:

- prevent a newly advanced client buffer from being sampled with bounds from
  the preceding successful Flutter layer tree;
- preserve the fast path for same-geometry Chromium video frames;
- avoid client-specific behavior and clipping adjustments.

Result:

- the user reproduced the same resize and pointer-hover glitch;
- the user reported that nothing visibly changed;
- the log mismatch between requested dimensions and DMA-BUF dimensions was
  therefore either incidental, downstream of the real fault, or not fully
  covered by the transaction boundary that was added.

Later analysis showed the classification never fired on the desktop; see
[Why the final experiment changed nothing](#why-the-final-experiment-changed-nothing).
The compositor side has since been removed from the working tree: with real
crop presentations it would start firing, and its rebuild requirement is
cleared only by a Flutter tick that a reallocation no longer triggers, which
could stall a window's texture-only updates. The engine side remains a local
commit in the canonical Flutter fork; Denial's `SOURCE_LOCK.json` was
deliberately not advanced to it and it should not be promoted.

## Build and validation record

The final experiment passed mechanical validation despite failing visually:

- all 368 compositor tests passed, with one unrelated ignored test;
- the release compositor built successfully;
- the experimental release engine built successfully;
- Denial's engine ABI and AOT bundle check passed;
- the corrected shell candidate was
  `1790888002011912-367085`;
- the compositor classification and scheduler barrier unit tests passed.

Flutter's complete `shell_unittests` binary could not be rebuilt because
existing test sources fail against the current Skia headers: `dl_test_snippets.cc`
does not see `DlSkCanvasAdapter`, and existing code in
`rasterizer_unittests.cc` sees incomplete `SkPaint` and `SkCanvas` types. The
production engine target was not affected by those test-only failures.

Crop canvas fix (the user confirmed it visually on 2026-10-01; mechanical
validation below):

- `tools/denial-pc compositor-test`: 370 passed, 1 ignored, including the five
  `cropped_canvas_tests`;
- `tools/denial-pc compositor`: the release compositor built successfully; it
  takes effect at the next normal `Denial (development)` login, which uses the
  active plugin candidate with the pinned engine.

## Current negative conclusions

The evidence so far does not support any of these as a complete explanation:

- Xwayland behavior or fractional output scaling;
- tiling layout policy;
- configure-event volume by itself;
- the direct imported-texture path by itself;
- retained DMA-BUF cache entries by themselves;
- a simple old-window-size frame, because the bad presentation was observed to
  be oversized in both resize directions.

An earlier version of this list also excluded "a geometry-changing client
buffer advancing through a texture-only Flutter render". That entry was
withdrawn: the experiment it rested on never engaged, and the root cause is
precisely that pairing.

The pointer is a trigger only indirectly. Pointer entry causes a new Chromium
surface commit: the repaint on which Chromium finally replaces its cropped,
over-allocated buffer with an exact-size one.

## Fix: crop canvas presentation

The engine already supports a per-texture virtual canvas
(`DenialFlutterExternalTexturePresentation`). It maps a source rectangle of
the resolved image onto a canvas, and it is read once alongside each resolved
image, so the crop is atomic with the buffer it describes. The compositor's
texture slots already advance each presentation together with its buffer
generation.

`append_surface_tree` now publishes any texture whose viewport crops an
untransformed buffer with an integral crop (`cropped_buffer_canvas`) as:

- an engine presentation with a canvas of the crop size, `source` set to the
  crop in buffer pixels, `destination` set to the whole canvas, and an empty
  background (which adds no draw);
- a Dart layer description whose width and height are the crop size and whose
  source is the whole canvas.

Dart's layout therefore depends only on the visible crop, never on the
allocation. In both pairings above, the published extent is identical or
differs by the 1-3 rows of normal per-frame resize growth, so a stale pairing
is no longer visible. Uncropped, fractional, or transformed sources keep the
existing path unchanged. The mobile content-inset projection maps its root
source back through the crop (`canvas_rect_to_buffer`) before replacing it
with its own presentation; clipped subsurface sources stay in canvas
coordinates, which the engine resolves through each subsurface's own crop.

Cost in the pinned engine: while a window uses a cropped buffer, `PaintWindow`
treats any presentation as a composed input, so that window loses the
single-draw direct path. That covers Chromium during a resize and afterwards
until its next reallocation, and it costs CPU on lower-end machines.

### Engine follow-up: crop-only presentations stay direct

Flutter fork commit `c15961e900c` (on `31e1a6882a3`) classifies a presentation
as crop-only when it has no backing strip (empty `background`), its `source`
lies inside the resolved image, and its `destination` lies inside the canvas.
`Paint` draws it as one `DrawImageRect` with `DlSrcRectConstraint::kStrict`
(no `Save`/`ClipRect`, no background draw), and `PaintWindow` keeps the direct
WindowSurface plan for it. The direct plan already honours the draw's source
rectangle: `WindowSurfaceContents` maps UVs through the `TextureContents`
source and destination, the strict constraint clamps sampling half a texel
inside the crop, and the shader treats UVs outside the source coverage as
uncovered. Filtering therefore never reads the unused rows of an
over-allocated buffer. The mobile content-inset presentation still has a
backing strip and remains a composed input. The compositor needs no change.

Status: the user validated it on `.188`. Its pushed form is fork commit
`6b561e66412` (identical apart from one clang-format line wrap), and
Denial's source lock pins it.

## Current code state

- The Chromium-only forced-composition diagnostic is reverted.
- The lag-producing external-texture cleanup/retirement attempt is reverted.
- The `DENIAL_RESIZE_AUDIT` trace used during this investigation has been
  removed.
- Niri-style configure pacing remains but is not considered a fix.
- The compositor-side scene transaction barrier is removed (see above); the
  pre-removal working tree was preserved as a patch before editing.
- The crop canvas presentation is implemented in
  `compositor/src/bin/deniald/wayland_frontend/surface_pipeline.rs` and
  `insets.rs`, with unit tests in `cropped_canvas_tests`. It needs no Dart
  bundle change.
- The failed engine-side scene texture deferral exists only in local Flutter
  commit `caef8836139` (branch `experiment/scene-texture-deferral-20261001`);
  it is not an ancestor of `denia/3.47.5`.
- The crop-only direct-path engine change is Flutter fork commit
  `6b561e66412`, pinned by Denial's source lock.

