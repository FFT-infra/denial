# Flutter tool snapshot — 3.47.5

The source authority is `prebuilt/flutter-engine/SOURCE_LOCK.json`. This
snapshot uses that exact Flutter fork, its Flutter tool dependencies, and the
coupled Dart 3.13.4 SDK at `b530c21f7de367b94fb04787bfed9d8e989d75e8`.

The Rust `xtask` compiles Flutter's tool entrypoint to an AOT kernel and then
an `app-aot-elf` snapshot for the pinned `dartaotruntime`. Both stages run in
an unprivileged Bubblewrap namespace with fixed paths, environment, timestamps,
and generic x86-64 CPU targeting. The tool entrypoint does not execute during
compilation. The generated snapshot is a build artifact; only its expected
SHA-256 is tracked here.

Build and verify it from the repository root:

```sh
cargo xtask flutter-tool-snapshot
```

Refresh this metadata only as part of a deliberate, coupled engine and SDK
generation update. A routine build must match the expected checksum. The
engine-mode checksums and both package manifests must identify the same lock.

Building the snapshot and engines does not validate a complete UI-development
package or a live editor attach. Those checks remain separate release gates.
