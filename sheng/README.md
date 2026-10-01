# sheng ARM64 candidate builds

This directory is the build and packaging adapter for the `sheng-build` branch
of `FFT-infra/denial`. It leaves Denial's compositor, SDK, Flutter source lock,
and existing upstream tools unchanged. It does not install on a device, activate
a plugin, restart a graphical session, create a release, or sign packages.

## Inputs and boundaries

`source.lock.json` pins upstream Denial, its engine source-lock digest, the
architecture, Dart version, and the official `denial_taskbar` Git package. The
taskbar source must match `dart_shell/pubspec.lock`: collection revision
`4b7adf998852b09b9a91c1cfab48be58debf2e80`, path `plugins/denial_taskbar` in
`https://github.com/denialwm/denial-plugins.git`. This is provenance checking, not
a second dependency resolver; Pub still resolves the composition.

The source guard rejects changes outside
`sheng/` and `.github/workflows/sheng-arm64.yml` relative to that upstream commit.
It also rejects dirty or untracked build inputs.

The workflow uses a native `ubuntu-24.04-arm` runner, Ubuntu's GLIBC 2.39 build
baseline, and the repository's pinned Rust toolchain. The target is Fedora 44
aarch64. No QEMU cross-build or upstream self-hosted builder is implied.

All build dependencies are listed in the workflow. Initial bootstrap requires
network access to the locked Flutter/Skia/depot_tools sources, Cargo, Pub, and
Flutter artifacts. Only locked Cargo/Pub downloads are cached initially. A cold
engine build still has a real time and storage cost; the job requires 40 GiB
free, has a 360-minute limit, and does not delete runner software to make space.

## Build sequence

1. Validate the source pin and run the adapter's fixture tests.
2. Create a private clone inside a new build workspace. The caller's checkout is
   not modified, including its Git exclude file.
3. Run upstream `denial-pc bootstrap` and native
   `denial-flutter-engine prepare-app-build`.
4. Validate the generated ARM64 release ELF and GN architecture, then record its
   checksum, actual args, source-coupled ABI stamps, and license notices under
   the disposable clone's `prebuilt/flutter-engine/linux-arm64-release/`.
   The expected hash is derived from this exact controlled build, not copied
   from an x64 artifact or described as upstream ARM64 certification.
5. Run upstream `denial-pc build` once. This builds the default shell, Settings,
   Plugin Manager/backend/compiler kit, and native runtime. Native engine
   preparation inside the upstream app steps is incremental and hash-checked;
   the manager kit itself is generated once.
6. Run upstream `sdk-test`, `plugin-check`, and `compositor-test`. These are the
   release path; debug/profile engines and visual test events are not requested.
7. Render external copies of the reviewed upstream packaging scripts with only
   their source-root location, ARM paths, ARM RPM metadata, and no-rebuild staging
   adjusted. Every replacement has an exact occurrence guard. Nothing is written
   over the upstream scripts or spec.
8. Stage once, validate all payload ELFs and their GLIBC requirements, and freeze
   content/type/mode inventories. Build all three RPMs from that staging tree.
   Upstream's extracted-payload verification remains in the chain. The adapted
   metadata verifier checks aarch64 and preserves the upstream package checks.
9. Extract the actual RPMs into an isolated prefix/HOME, with a separate Pub cache
   and no inherited Denial SDK override. Run installed `denial-plugins prepare`,
   then plan/build the built-ins. Fresh manager state selects `denial_top_bar`;
   this is different from the packaged default shell, which already uses taskbar.
   Next inspect/add the exact official taskbar Git package, remove `denial_top_bar`
   in that isolated selection, and plan/build again. Require `TaskbarPlugin` and
   a single `TaskbarWorkArea`, the pinned source identity, and no Sheng window strip.
   Run the three official headless taskbar tests from the source resolved by Pub.
   Validate both ARM64 release bundles and source/engine identities, and require
   the package-managed prefix to remain byte/mode-identical. No `activate`,
   compositor, or connection to a user's display is involved.
10. Verify frozen payloads and extracted RPM contents again using the existing
    upstream payload verifier, export the matching Dart SDK, record provenance,
    and calculate `SHA256SUMS`. Only then create the workflow's verified marker
    and upload candidate artifacts. Failed jobs upload diagnostics, not packages.

The packaging copies avoid the upstream sequence that regenerates a
non-byte-reproducible Flutter-tool snapshot separately for each package format.
All package verification compares against the same frozen compiler kit.

## Artifacts

A successful artifact contains:

- `denial-*.aarch64.rpm`: native runtime, default AOT/assets, settings, session/portal;
- `denial-flutter-engine-*.aarch64.rpm`: matching release engine, ICU, source/ABI
  metadata and notices;
- `denial-plugin-manager-*.aarch64.rpm`: GUI, backend, installation discovery and
  the matching compiler kit;
- `dart-sdk-3.13.4-linux-arm64.tar.xz` and its inventory: the source-coupled SDK
  used for the isolated composition smoke, including its license;
- package inventories, `plugin-smoke.json`, `build-record.json`, and `SHA256SUMS`.

The compiler kit deliberately does **not** embed the Dart SDK. A compatible Dart
must be installed on PATH wherever plugin compositions are compiled. The supplied
SDK archive is separate from RPM installation: an authorized installation can
unpack it into a dedicated user-owned toolchain prefix and add that SDK's `bin`
to PATH. Do not overwrite a distribution-owned Dart or infer that installing the
Plugin Manager alone supplies one. The runtime's precompiled default shell does
not need Dart to start.

The build record distinguishes the fixed upstream commit from the adapter/build
commit and records hashes of every generated ARM metadata file. Generated files
are excluded only in the disposable clone to prevent build output being treated
as source changes; tracked core equality is checked again after building. No
`assume-unchanged`, source-lock rewrite, fake checksum, or verifier bypass is used.

## Local checks

These require only Python 3.11+ and Bash, do not compile an engine, and create
fixtures only in temporary directories under `sheng/`:

```sh
python3 -m unittest discover -s sheng/tests -v
bash -n sheng/build.sh
```

Tests exercise native-target validation, exact template adaptation, immutable
metadata writes, safe inventories, and corruption/missing-component rejection.
The short ELF fixtures test the header parser only; they are not fake successful
package or engine builds.

The real build requires a committed, clean checkout, native aarch64, the workflow's
listed dependencies and network access. On a dedicated build host, invoke:

```sh
bash sheng/build.sh /absolute/path/to/a/new/workspace
```

The workspace must not already exist. The script never deletes an existing
workspace to retry. Workspaces contain source projections, compiler caches,
intermediate files and logs; inspect them before explicit cleanup.

## Verification and rollback

The adapter's local syntax/fixture checks are not evidence that the full ARM64
build or a device install succeeded. Consult the actual Actions run and require
all package and installed-prefix smoke gates to pass. Schema 2 of
`plugin-smoke.json` requires both `builtins` and `taskbar` composition results,
plus the official taskbar source and three headless checks. It proves builds
only, not plugin activation or visual/touch behavior.

Candidates are unsigned development builds, with source-derived versions and no
release tag. Keep the existing installed RPMs/configuration and packaged recovery
shell until a separately authorized deployment passes on sheng. Device activation,
GUI checks, native session changes, and rollback are separate, explicitly
authorized operations. A failed candidate build leaves the existing fork branches
and devices untouched.
