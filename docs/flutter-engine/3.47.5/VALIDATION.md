# Flutter 3.47.5 engine validation

The initial Flutter 3.47.5 upgrade covered the release engine. Debug and
profile engines were explicitly refreshed on 2026-09-30; that refresh is
recorded below. Routine release builds still use only the release engine.

## Source identity

- Flutter upstream: `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`
- Flutter fork: `718ccf2c2314f6cac9808e5eb37d0117407eb4e4`
- Flutter branch: `denial/3.47.5-r1`
- Dart: 3.13.4 at `b530c21f7de367b94fb04787bfed9d8e989d75e8`
- Engine artifact revision: `af7e796e161ae0bb1ff0758c71a7105418bd9ded`
- Skia upstream: `8df24be66531469e576a806749a0202ae26b8d08`
- Skia fork: `5b495e3e15a59ee76af882d83316d351654c1e88`
- Skia branch: `denial/3.47.5-r1`

The Flutter fork contains 128 Denial commits directly on the 3.47.5 upstream
commit, with no merge commits. The Skia fork contains three Denial commits
directly on its coupled upstream commit, also with no merge commits. Both exact
fork tips were pushed and verified on their `denialwm` remotes before the
Denial source lock advanced.

## Generated ABI and release artifact

The official Flutter embedder bindings were regenerated and checked from the
3.47.5 upstream header. Denial's private embedder extension remains typed
separately in `compositor/flutter-engine/src/lib.rs`.

- Official embedder header SHA-256:
  `94122469b254a932394bb5bb5c625317426eefd6e23d4366e32372c70ac5be37`
- Denial fork embedder header SHA-256:
  `1c6b72beb8d1ded1c0c111974210efd1ae4b7c09ac595a0865158ef6f76a54ed`
- Generated Rust bindings SHA-256:
  `9a41a4c9032bac3a77afe0cac7e47eebff72cfa28a38c7ae5537fab75f625f81`
- Release `args.gn` SHA-256:
  `86190a142bf1d4283716e5c254bf9054db38430b8e089692760374bea6f75af3`
- Release engine SHA-256:
  `c11ed3e76dd771ceeee0b2104f5a5210c3cdd180db1d5ce5a79afdff833c765a`
- Release engine GNU build ID:
  `1e1b253d46bbb503264b4e198404e5870e969755`

The generated binding check passed, the native engine compiled, the Dart 3.13.4
AOT shell compiled, and the isolated ABI/AOT loader check passed. The complete
local release shell and Rust compositor also built successfully. Nix engine and
Pub locks were regenerated and verified against the same source lock. The
release-path suite passed 281 compositor tests, four Rust embedder tests, and
two portal tests without building a debug or profile engine.

## Hardware activation

The release engine and rebuilt Denial bundle were deployed to the agent-managed
host `192.168.1.188` as artifact
`718ccf2c2314f6ca-73c0cff61fba766a`. After restarting `greetd.service`, the new
`deniald` and portal processes were active. Independent process-map and file
hash checks confirmed that `deniald` mapped the deployed engine above and that
the compositor, shell, engine, and portal bytes matched the local artifacts.

Visual inspection remains user-owned. On 2026-09-22 the user confirmed that the
upgraded session works. No screenshot or agent-triggered visible test event was
used.

## Engine and development-tool refresh — 2026-09-30

The source lock now identifies Flutter fork
`f8489afa8ca81e9b91d494ffa0a30bdb6bd076d5` and the unchanged Skia fork
`5b495e3e15a59ee76af882d83316d351654c1e88`. Both exact commits were verified
on their public remotes. The Flutter advance from `43d1647` contains two
formatting commits. The upstream ABI and coupled Dart 3.13.4 revision are
unchanged. The source-lock SHA-256 is
`d383e16d0338f2953c2545ad8ff5919a25e4f874442952770c08bd526484b2a2`.

All three modes were built in one metadata refresh with
`DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1`. The checked-in arguments and
checksums identify these artifacts:

| Mode | Engine SHA-256 |
| --- | --- |
| Release | `33633607438bee6eb40eea76ca3cbfb6f58ee18dba239cf6f46dd2f7ef881580` |
| Debug | `0103c4b53ddb75538a20008914ae442d66aa688fd0db10435c1aa918bf17024b` |
| Profile | `82569727237b13b6f2db06fc98db1cdb8f17fd6c30681c87d18652b23b7573fd` |

Isolated Rust loader checks passed for every mode without starting a Flutter
engine or opening a display. They verified the complete Flutter and Denial
embedder ABI, the debug engine's JIT flag, and the release/profile engines'
AOT flags and AOT-data loading. The four Rust embedder unit tests passed.
These checks do not establish engine initialization or rendering behavior.

The coupled Flutter tool AOT snapshot was built twice in its canonical
Bubblewrap environment and matched SHA-256
`fa78ec1909a5f17ea24fdf02bea3768397871dcd49415092d1997df0e2f56840`.
It ran with the pinned Dart runtime and reported the locked Flutter revision,
Flutter 3.47.5, and Dart 3.13.4. This is repeated-build evidence on one host.
The lock-matched debug SDK, platform dill, shader tools, and profile AOT
compiler/GTK build artifacts were prepared successfully. Both the routine
release cache and the three-mode artifact cache passed verification.

The authoritative Nix engine-source and Pub lock refreshes passed on the
managed `.18` host. The complete engine source closure was fetched and verified
against the refreshed fixed-output hash, and the Nix lock-consistency
derivation built successfully. The Nix engine derivation evaluated correctly.
Full flake evaluation remains blocked by the default composition's missing
external taskbar source; it requires a pinned source from the plugin repository.

The refreshed artifacts have not been activated in a graphical session.
Engine C++ unit suites, hardware acceptance, complete UI-development packaging,
offline workspace preparation, and live editor attach remain separate gates.
The package manifests clear the corresponding historical validation claims
where they have not been repeated for this source lock.

The strict `source-audit --branch dev` passed with zero failures and warnings
in a clean temporary snapshot of the checkout. Both package source hashes
passed. The working checkout was left uncommitted; ignored profiling notes
were excluded from the snapshot.
