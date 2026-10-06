# Glass refraction on narrow surfaces — 2026-09-28

The taskbar's reported horizontal centre seam has two numerical causes in the
Impeller glass material. This audit uses source inspection and CPU evaluation
of the shader's optical calculations, without screenshots or rendered-output
inspection.

## Cause and fix

The engine limits physical thickness to half the material's short dimension,
but multiplies that thickness by `bevel_width_scale` afterward. A wide bevel
can therefore overlap the opposing edge. The rounded-box normal changes sign
at the centre while the surface slope is still nonzero, abruptly changing the
background sample position. The current settings request a 35px bevel
(`thickness=20`, `bevelWidthScale=1.75`), which overlaps on a surface shorter
than 70px. The taskbar plugin requests 52px thickness.

`FitGlassBevelWidthScale` now fits the bevel to half the full material's short
dimension. It leaves the existing physical optical thickness, refraction depth,
dispersion, and lighting parameters intact. Damage crops do not redefine that
dimension. Profiles that already fit retain their requested width.

The existing harmonic corner-normal smoothing also retained nonzero components
across the horizontal and vertical centre lines inside the corner core. This
left shorter seams near lightly rounded ends even after fitting the bevel.
The shader now cancels each opposing component continuously toward its centre
line, preserving its straight-edge joins.

The implementation is committed in the canonical Flutter fork as
`43d164738f1b` (`Fit glass bevels to narrow surfaces and smooth opposing normals`).
Denial's source lock remains at the accepted engine revision pending user
visual validation.

## Nonvisual validation

- All 15 `glass_filter_unittests` pass, including new narrow horizontal/vertical
  material cases, unchanged wide profiles, fractional scaling, reflection, and
  partial-damage cases.
- CPU evaluation extracted the actual GLSL distance, normal, height, and Snell
  calculations and the C++ bevel-fit helper. Across 10,080 centre-line checks,
  all samples remained finite and the differences converged toward zero as
  the separation decreased. Cases include 8px and 24px small surfaces,
  horizontal and vertical bars, large panels, square through fully rounded
  corners, and maximum depth/dispersion settings.
- With the current optical settings on a representative 48px bar, the old
  centre jump was approximately 6.134 background pixels across 0.002px of
  surface. The corrected centre difference is approximately 0.00113px.
- Edge displacement in that case remains 83.428596px before and after fitting.
- The broad `impeller_unittests` build encounters an existing unrelated
  `DlSkCanvasAdapter`/incomplete `SkCanvas` compilation failure in
  `display_list/testing/dl_test_snippets.cc`. A dedicated, nonvisual glass test
  target avoids that dependency and runs the complete glass-filter test file.

Numerical harnesses and build logs for this session are under
`/tmp/check_glass_{bevel,continuity}.{py,cc}` and
`/tmp/denial-glass-*.log`.

## Activation boundary

The candidate uses the release-only `engine-test-build` / `engine-test-check`
workflow. The release build and engine ABI/AOT load check passed. The staged
engine SHA-256 is
`54ad026dab873243fd9b71d285a8afde7774c677bb6f9e76d9a5fbb53efc24c3`.
The sealed candidate is at
`~/.cache/denial/engine-test/43d164738f1b1540bf4d5601968f2ae50a4be2de-54ad026dab873243/bundle`
and is armed for the next development login only.

Its baseline copies the active compiled plugin composition
`1790625150356226-19228` so the user's existing taskbar and assets are present.
All 56 copied app, ICU, and asset files match the active composition byte for
byte by SHA-256.
It is an isolated shell baseline, not a new Plugin Manager candidate; the
original sealed candidate and saved plugin selection are untouched.

Plugin Manager's normal engine-hash gate will reject the saved old-engine
candidate during the experimental login, so that login uses the copied
composition as its baseline shell. Normal engine login can use the original
selected candidate again. Plugin Manager health for the old candidate is not
an acceptance criterion for this isolated engine experiment.

Local session restart and visual acceptance belong to the user. No local
session was stopped, and no visual or interactive test event was triggered.
