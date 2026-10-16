# Layered composition

Design contract for agents. Accepted 2026-10-16. Phase 1 is implemented in the
Flutter fork behind an environment switch; the phase table records status.

## Problem

Flutter partial repaint is per output buffer. Any damage, such as an animated
wallpaper texture or a client buffer under glass, re-rasterizes everything
intersecting it through Impeller, whose per-frame CPU is O(scene)
(`docs/benchmarks`, render bench 2026-10-14). Shell content that did not change
is redrawn every frame.

## Model

One bundle, one engine, one widget tree. The layer tree marks **cuts** in
paint order. What lies between two consecutive cuts is a **slice**. The engine
turns a frame into an ordered entry list per output view and composes it.

Entry kinds:

- **Slice**: engine-rendered content (shadows, frames, text, icons). A
  tight-bounds texture, re-rendered by Impeller only when its display list
  changed.
- **External texture**: client buffer, wallpaper video, cursor. Never
  rasterized into a slice. Placed by the cut's clip/transform/opacity
  mutators.
- **Material**: window glass (`DlWindowSurfaceFilter`) or a backdrop filter.
  Evaluated against the composite so far, inside its bounds.

Rules:

- Glass is a cut, never an effect inside a slice. Glass over glass is two
  material cuts in order.
- Opacity, transforms, clips and saveLayers inside a slice behave as today.
- Slice identity = position in the per-frame entry list; a slice is reused
  when its bounds and display list are equal to the previous frame's.
- Fixed "four layers" are rejected: a windows layer cannot host per-window
  glass and re-renders on any window change.

## Seam

Flutter's embedder compositor protocol inside the fork, not a new deniald
protocol. Cuts are platform views registered during preroll
(`ExternalViewEmbedder::DenialRegisterCut`); the layers between them are the
existing `EmbedderExternalView` slices. Composition runs in
`EmbedderExternalViewEmbedder::SubmitDenialLayered` on Impeller into the
single Denial output target, so deniald keeps its one-layer `present_view`
path and all existing window, glass and texture shaders stay the visual
oracle.

No Dart change: `WindowSurfaceLayer`, `BackdropFilterLayer` and
`TextureLayer` become cuts in the fork when layered mode is on. Dart
primitives (`WindowPlane`, `ShellBackdropBlur`, `Texture`) are unchanged.

## Fork implementation (phase 1)

Switch: `DENIAL_LAYERED_COMPOSITION=1` in the compositor's environment; only
Denial output views (negative view ids) use it. Off keeps today's path.

- `flow/embedded_views.h`: `DenialCutEntry` (window surface, material
  begin/end, texture) and the embedder hooks.
- `flow/layers/{window_surface,backdrop_filter,texture}_layer.cc`: register
  cuts in `Preroll`; `Paint` switches the slice canvas instead of drawing.
- `shell/platform/embedder/embedder_external_view_embedder.cc`: renders each
  slice to a retained `DenialSlice` texture when its display list changed,
  then draws entries in order with `PaintWindow`, `DrawImage` or a backdrop
  `SaveLayer`, and presents one backing store.
- `shell/common/rasterizer.cc`: layered frames skip frame damage diffing and
  report full damage.

## Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Cuts for glass, backdrop and textures; slices retained by display-list equality; composition on Impeller; env switch | implemented, untested on device |
| 2 | Slice damage: diff slice display lists, repaint only the changed region; backdrop snapshot cache tokens so still glass is not re-blurred | planned |
| 3 | Texture-only frames: re-compose from the retained entry list without a Flutter frame | planned |
| 4 | Occlusion culling, move-only slice reuse, KMS overlay planes (`docs/direct_scanout.md`) | planned |

Test device: OnePlus Pad 4 (`/mnt/development/onepluspad4`). Benchmarks:
`tools/denial-benchmark`, records in `docs/benchmarks/desktop`.

## Known costs

- Phase 1 still records every layer's display list each frame; the saving is
  rasterization, not recording.
- GPU memory rises: slices are allocated at content bounds even where a client
  texture covers them. Occlusion culling reduces it. CPU is the priority.
- Materials over an animated texture re-evaluate every frame until phase 2.
- The composition pass redraws the whole output every frame; the scanout
  path then copies it as today.
