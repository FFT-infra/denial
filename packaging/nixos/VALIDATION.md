# NixOS source package and module validation

This record covers first-party Nix builds, module integration, cache and package
contracts, and non-visual runtime health. Visual validation remains user-owned
and was not performed. The newest supported-path validation appears first;
earlier sections describe the implementations tested at those dates.

## Supported engine cache (2026-10-03)

The default module was built and booted on `.18` with the production packaging
split: one pure Nix, source-built engine and matching Dart SDK/compiler kit,
followed by host adaptation and host-native compositor and application builds.
Neither configuration overrode `programs.denial.package` or the engine.

| Host package set | Kernel | Runtime glibc | Runtime Mesa | Result |
| --- | --- | --- | --- | --- |
| NixOS 26.05.7443.70cc4559b10a | 7.1.8 | 2.42-67 | 26.1.5 | Fresh boot, session health and GBM/EGL probe passed |
| Nixpkgs unstable `b4fd65b198c599cbe814fcb9f42d25d021595ec9` | 7.2.8 | 2.44-25 | 26.2.3 | Fresh boot, session health and GBM/EGL probe passed |

Both selected the exact same producer derivation and raw output:
`/nix/store/av5b51sxq54vikxgb9s9hjxskg8k0c3r-denial-flutter-engine-raw-af7e796e161ae0bb1ff0758c71a7105418bd9ded`.
The producer compiled the locked Flutter/Skia sources with Denial's pinned
Nixpkgs; the completed release build had 8,904 Ninja steps. It did not repackage
the development workstation's engine. Its source-lock SHA-256 was
`13bd80e89eeec9139c44043cfb1b0f8f0f0b1db7d11e13969838a35e52c7dd3c`,
and its actual GN configuration SHA-256 was
`f9f88ace1cd8b9372b529f28ef64f32d4400eab94e8faefe14917e273d3e23e6`.
The producer baselines were glibc 2.42 and GCC runtime 15.2.

The raw object has zero Nix-store references. Its manifest inventories all 1,383
files, including the source-built Dart SDK, with hashes, sizes and executable
modes. The manifest SHA-256 was
`19fe5d2cee4eb37a116cd9bd16cdcdfff0c72937c8fcb56bff1c99881e90f277`.
An isolated signed file cache transferred this object into a fresh local store;
signature, NAR contents and complete manifest verification passed. The NAR was
687,381,968 bytes, compressed to 165,434,512 bytes, with hash
`sha256-Fh9BIY7xg7Dx4wmbPU/7RX8if9IoKdVgwAYaBvDYAKk=`. This round trip
used a disposable test signing key, not the production Cachix key.

The tested stable and unstable packages were respectively
`/nix/store/6p4szbgdjbfhg9xyhm0h9m5npgwm5fvn-denial-0.0.0+src.15b5b0aed566`
and
`/nix/store/cf4vpqdpjdbrgpm0l0xq9hri5apibhsp-denial-0.0.0+src.15b5b0aed566`.
Each running process mapped its expected package engine and AOT bundle, the
host's exact libc and Mesa, and no producer libc. The host-adapted engine hashes
were `f22e4c958df815b34a2f3875036efe53bcd2f1c66e65571cd678d75441ab2234`
(stable) and
`f7c8d010bb0dfe2108e38fa5bf2c7051476929e9fa4ffebcf1cee2f540bc6dd5`
(unstable); installed copies matched exactly. Greetd, the Denial session target,
portal and PolicyKit agent were active, and system and user failed-unit lists
were empty. The AMD render-node probe loaded the engine and AOT data and
created GBM and surfaceless EGL/GLES 3 contexts without a window or scanout.

The complete 11-output CI build matrix passed, including both full packages,
both module checks, both engine/cache contracts, source locks, manifest tests
and installed paths. All executed release-profile Rust tests passed, including
386 tests in the main suite. The 12 manifest tests cover tampering, omitted or
extra files, executable modes, symlinks and mismatched identity. Module checks
verify the paired Dart SDK, older-libc/compiler and non-GNU fallback selection,
and explicit source selection. A complete forced-source package and its
installed-path check also passed. Final lock verification and flake evaluation
passed.

Using the stable probe against unstable's Mesa reproduced `GLIBC_2.43` not
found followed by GBM's `ENOENT`, while the unstable-adapted probe passed.
The preceding experiment below validated the corrected startup diagnostic in
an actual failing session. Settings, PolicyKit and Plugin Manager were built;
their GUIs were not launched for validation. These results cover x86_64 release
mode on the AMD device, not NVIDIA, other architectures or visual behavior.

Both system boots used separate additive Limine entries, with kernel and
initramfs BLAKE2b-512 hashes independently checked immediately before reboot.
The original NixOS system profile, configuration and Limine default were
preserved. Evidence is retained under
`/home/logix/denial-engine-cache-20261002/`, including frozen sources, all build
logs, the signed cache, manifest and host identity records, process maps,
service checks, render probes and boot hash checks. This local validation
precedes production cache publication by the `dev` workflow.

## Portable engine experiment (2026-10-02)

The Firefox/Electron-style split was tested on `.18` with one verified release
engine/compiler artifact and two host-native package sets. At that point the
split was experimental and normal packages still built the engine from source.
The adapter and reproduction
instructions are in [`nix/experiments`](../../nix/experiments/README.md).

| Host package set | Kernel | Runtime glibc | Runtime Mesa | Result |
| --- | --- | --- | --- | --- |
| NixOS 26.05.7443.70cc4559b10a | 7.1.8 | 2.42-67 | 26.1.5 | Fresh boot, Denial session and render-node probe passed |
| Nixpkgs unstable `b4fd65b198c599cbe814fcb9f42d25d021595ec9` | 7.2.8 | 2.44-25 | 26.2.3 | Fresh boot, Denial session and render-node probe passed |

The engine came from the release artifact cache verified against Flutter commit
`ca061606416467424b546da68a662e897f9e19a2`, coupled to Flutter 3.47.5 and Dart
3.13.4. The source-lock SHA-256 was
`13bd80e89eeec9139c44043cfb1b0f8f0f0b1db7d11e13969838a35e52c7dd3c`;
the unmodified engine SHA-256 was
`dea4ca4b6d2fabcab57c91dc61b3214f0517fc659d214a70ae8d663f11811de8`.
Preparing the required compiler and GTK artifacts reused the existing release
Ninja output with no work to do; neither host package build compiled the engine.
The compositor and Dart applications were rebuilt against each host package set.

Both selected the same raw store object:
`/nix/store/7nj0sv3ahpaj0b7aaajq86ic85s1gn1c-denial-portable-engine-raw`
(83,318,304 bytes including compiler assets). It was uploaded to an isolated file
binary cache and downloaded into a separate local store; the fetched engine was
byte-identical to the verified input. No artifact was published to Cachix.
Host adaptation removed old ELF search paths on copies and used each host's
`autoPatchelfHook`. Adapted engine SHA-256 values were
`9e947c5a3a4e64da473ba6432fd6b4cb73a359ace165e353d7439d4812f93c74`
(stable) and
`d51d81e32c4188b79a643494cb849d02a2375c5acc1bdeb1a7b6b7626af26754`
(unstable). Each installed engine matched its adapted artifact exactly. Each
complete runtime package closure contained only its host's glibc version.

The tested packages were:

- Stable: `/nix/store/fyl4z8b9nqr6mfldwcmak7md1vl7hc99-denial-0.0.0+src.d7d0b29ad165`.
- Unstable: `/nix/store/h4m43lmvh6jniiyz21rkb6jygkal1fs9-denial-0.0.0+src.a541ee4e4b49`.

The source was frozen before concurrent compositor edits in the development
checkout. The package identities differ because the unstable build includes the
subsequent pinned Flutter-wrapper correction. A standalone copy of the corrected
NixOS module was used for both system tests without rebuilding their packages.
This does not validate later unrelated checkout edits.

Both full package builds passed their executed release-profile Rust checks and
installed-path checks. The default source-package module regression checks also
passed on both package sets, including host libc alignment and enabled/disabled
PolicyKit integration. The experiment rejected an override stamped with a wrong
source-lock hash. The render-node probe checked the Denial extension symbols,
Flutter procedure table, AOT data loading, GBM and surfaceless EGL/GLES 3; it
created no window or scanout. The actual sessions exercised engine initialization
and Dart execution. Process maps confirmed the expected package's engine and
`libapp.so`, the host libc, and the host Mesa driver. The display manager, Denial
session target, portal and PolicyKit agent were active; final system and user
failed-unit lists were empty. Settings was built and checked, but its GUI was
not launched. No visual validation or interactive test event was performed.

The negative test reproduced the report exactly: the stable-built probe on the
unstable graphics stack failed because Mesa required `GLIBC_2.43`, followed by
GBM's `ENOENT`. A brief session with the stable package reproduced the same
failure and verified the new fatal diagnostic identifies an **already-open** DRM
device and directs the user to Mesa loader output and host dependency alignment.
Session stderr was captured explicitly because greetd normally sends it to the
terminal. The working unstable session was restored and verified afterward.

A second adaptation check used the lab's previously source-built Nix Flutter
3.44.7 engine, retaining its original glibc 2.42 paths in the raw input. Removing
those paths on the copy and adapting it to unstable allowed `dlopen(RTLD_NOW)`
and Flutter symbol lookup under glibc 2.44. This was a library-loading check;
that old engine was not run with the newer AOT bundle.

Full builds uncovered three integration defects, corrected in this checkout:
the host's newer Flutter wrapper no longer honored the pinned helper's local
engine interface; the package source fileset omitted the installed PolicyKit
unit; and the module's PolicyKit drop-in appended a second `ExecStart` instead
of clearing the packaged command first. The wrapper now comes from the pinned
helper definitions while resolving native dependencies from the host. The
module check was updated for Denial's bundled authentication agent and verifies
that disabling it disables the generated unit.

The existing NixOS root LV was extended online from 64 to 96 GiB after the two
system closures filled its remaining space. Stable and unstable test systems
share that root and have separate Limine entries with explicit immutable system
paths; no second partition was needed. Both kernel and initramfs URI hashes
were independently checked with BLAKE2b-512 immediately before each reboot.
The disposable test configurations mount the existing main EFI partition at
`/boot`, as required by unstable's boot-seed service. The original NixOS
configuration, original system profile and Limine default remain unchanged.
`.18` was left running the unstable test session.

Evidence is retained under
`/home/logix/denial-portable-engine-test-20261002/`, including the frozen source,
artifact inputs, system expressions, complete build logs, module-check results,
cache round-trip logs, process maps, runtime status, boot hash checks,
`stable-probe-on-unstable.log` and `mismatched-package-stderr.log`.

The experiment identified these requirements before a supported cache path:
a complete verified artifact manifest tied to the source lock, configuration
and architecture, immutable publication, a source-build fallback and a supported
host compatibility matrix. The harness-supplied source-lock stamp was not
independently authenticated provenance. These results cover x86_64 release mode
on one AMD graphics device; they do not establish universal glibc, NVIDIA,
other-architecture or visual compatibility.

## Host dependency validation (2026-09-30)

The host-native overlay and module change was source-built and activated on
`192.168.1.18`, using its NixOS 26.05.7443.70cc4559b10a package set. Both the
Rust compositor and rebuilt Flutter engine selected the host's exact
`avld9cdn23zab2ssl30h2r6444rqh6ms-glibc-2.42-67` store path rather than
Denial's locked Nixpkgs libc. The full source package, compositor release
tests, source-lock check, module check, and installed-path check passed.

This test applied only the packaging change to the host's known-good
2026-09-18 source snapshot, retaining Flutter 3.44.7 and its existing source
locks. The current checkout's locked Flutter commit
`43d164738f1b1540bf4d5601968f2ae50a4be2de` returned HTTP 404 from GitHub,
preventing a build of that newer engine. No source locks were changed to
work around that failure. This validates the packaging integration, not the
newer engine or the other pending checkout changes.

The resulting package was
`/nix/store/hwksv05q8i39ciqnnm13880wa8k4m31s-denial-0.0.0+src.3b07b016aea7`.
After a temporary NixOS activation and GDM restart, `deniald` PID 56425
mapped that package's `libflutter_engine.so` and `libapp.so`, the host libc
above, and the host's Mesa 26.1.5 EGL driver. Store integrity verification,
`denial-session --check`, and the display manager, Denial session target,
portal, and PolicyKit-agent health checks passed; neither system nor user
systemd had failed units. The existing `MissingAuthorization` backing-store
startup messages also appeared in the preceding session and were not changed
by this packaging work. Visual validation was not performed.

The module regression check also passed against Nixpkgs unstable revision
`b4fd65b198c599cbe814fcb9f42d25d021595ec9` on this host. Evaluation selected
glibc 2.44 for the host, compositor, and Flutter engine. The unstable engine
and compositor were not built or run.

The test configuration was activated with `switch-to-configuration test`.
The permanent `/etc/nixos/configuration.nix` and boot system profile remained
unchanged. Evidence is retained on the test host under
`/home/logix/denial-nix-host-test-20260930/`, including `smoke-build.log`,
`system-build.log`, `runtime-check.log`, and both libc identity JSON files.
No pipeline jobs were added; the host-dependency assertions extend the
existing module check.

## Test system

- Host: dedicated unattended validation machine `192.168.1.18`
- Distribution: NixOS 26.05.7443.70cc4559b10a
- Kernel: Linux 7.1.8
- Architecture: `x86_64-linux`
- Session: GDM Wayland session with systemd/logind autologin
- Display hardware: AMD-driven internal eDP panel; NVIDIA PRIME/offload device

The host imports `denial.nixosModules.default` and uses the package from
Denial's locked flake input. GDM selection and autologin remain explicit host
policy rather than module policy.

## Source build and checks

The following completed successfully from the repository staging tree:

```sh
nix flake check --no-build --print-build-logs
nix flake check --print-build-logs --cores 10
tools/denial-nix verify-locks
sudo nixos-rebuild switch --cores 10
```

The initial source build compiled Denial's locked Flutter engine in 7,221
Ninja steps, then built the Dart shell, Settings, and Rust workspace. No Denial
release binary was downloaded or repackaged. Later validation reused those
content-addressed engine and Flutter outputs.

The Rust package runs its release-profile checks instead of disabling them.
All 241 runnable workspace tests passed. The one ignored test is the existing
isolated-bundle ABI test, whose own diagnostic directs maintainers to
`tools/denial-pc engine-test-check`.

The Nix checks additionally covered:

- exact agreement between both application `pubspec.lock` files and their
  generated Nix JSON, plus the locked Flutter tool input;
- agreement between `SOURCE_LOCK.json`, the engine revision, and every
  non-placeholder fixed-output hash in `nix/flutter-engine-lock.json`;
- enabled and disabled PolicyKit-agent and DDC/I2C module configurations;
- the absolute Zenity wlr-portal chooser command;
- installed launcher, desktop, D-Bus, portal, and systemd path contracts;
- Home Manager-style output-config symlinks, persistence of live writable
  state, and reset when declarative input changes;
- preservation of the Settings GTK launcher environment;
- absence of `/usr/bin/denial*` integration paths and
  `flutter-engine-toolchain` from the complete runtime closure;
- preservation of Denial's runtime EGL, PAM, PulseAudio, and DDC library
  search paths after Nix ELF fixup.

Branch validation now evaluates all flake outputs and builds the lock and
module checks on a GitHub-hosted Nix runner. The full source package remains a
deliberate local/self-hosted build because it includes the custom Flutter
engine.

## Resource and closure measurements

This 2026-09-18 validation predated the public Denial Cachix integration, so
its first system build exhausted the test host's 48 GiB thin root volume while
materializing the engine source, build, and system closures. Its existing
NixOS logical volume was extended online to 64 GiB. This is why the
installation guide still recommends at least 64 GiB of free builder working
space for a cache miss instead of describing the build only as “substantial.”

The composed package occupies approximately 105 MiB itself. Replacing the
Settings engine library's synthetic toolchain RUNPATH with direct runtime
library paths reduced the installed runtime closure from approximately
1.08 GiB to 596.0 MiB. The standalone Settings closure is 346.9 MiB, and
neither it nor the composed closure retains `flutter-engine-toolchain`.

## Installed-path and configuration contracts

`denial-session` resolves its own installed prefix and exports exact
package-relative compositor, control-client, Settings, Flutter-bundle, and
packaged-default paths. No `/usr/bin` compatibility links are required.

The final Settings launcher is the original Nix GTK wrapper retargeted to the
composed package. It retains `GIO_EXTRA_MODULES`,
`GDK_PIXBUF_MODULE_FILE`, and GSettings schema paths through
`XDG_DATA_DIRS`.

An ordinary writable `$XDG_CONFIG_HOME/denial/outputs.conf` remains direct
mutable state for backward compatibility. A symlink or read-only file is a
declarative source copied to `$XDG_STATE_HOME/denial/outputs.conf`; Denial may
write the state without mutating the source. State survives launches while
the source is unchanged and is refreshed when that source changes. When no
per-user source exists, `/etc/denial/outputs.conf` follows the same model, so
later NixOS rebuilds propagate.

Unreleased packages use a source-derived `0.0.0+git.*` or `0.0.0+src.*`
package version and compile the corresponding `nix.git.*` or `nix.src.*`
build identity into the binaries. `deniald --version` therefore identifies
the exact candidate instead of reporting only `development`; no semver
release file is synthesized, preserving the tag-only release-version policy.

## Runtime activation

After `nixos-rebuild switch`, the Denial session was restarted through GDM as
required for the agent-managed `.18` host. A new `deniald` process ran from
the activated source package, and its mapped Flutter engine came from that
same package prefix.

Post-activation checks confirmed:

- GDM, `deniald`, `denial-session.target`, `denial-portal.service`, and the
  default `denial-polkit-agent.service` were active;
- no system or user units were failed;
- `hardware.i2c.enable` was active and the session user had the resulting
  I2C device-access integration;
- the generated wlr portal configuration contained the absolute Nix-store
  Zenity chooser rather than an empty or packaged-but-bypassed config;
- the portal and control sockets were listening;
- `denial-session --check` resolved package-local binaries and Flutter assets;
- transient `MissingAuthorization` backing-store retries occurred during the
  GDM KMS handoff; they stopped immediately after startup, and the delayed log
  contained no panic or further compositor error.

Rendered output and interactive screen sharing were not triggered or judged
by the agent.
