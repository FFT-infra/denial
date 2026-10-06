# NixOS

Denial ships its Nix package, overlay, and NixOS module in this repository.
The Nix derivations build the Rust compositor, locked Denial Flutter engine,
embedded shell, and Settings from source. Normal installations reuse a separately
cached engine and adapt it to the host's dependencies; a cache miss builds that
same engine derivation from source. Denial release archives are not build inputs.

Add Denial to the flake that owns the NixOS system:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://denial.cachix.org" ];
    extra-trusted-public-keys = [
      "denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    denial.url = "github:denialwm/denial";
  };

  outputs =
    { nixpkgs, denial, ... }:
    {
      nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          denial.nixosModules.default
          {
            programs.denial.enable = true;
            programs.denial.plugins.enable = true; # Optional Plugin Manager.
          }
        ];
      };
    };
}
```

Rebuild the system normally, then choose **Denial** in the existing display
manager. The module deliberately does not enable a display manager, select a
default session, or configure autologin.

`programs.denial.package` can replace the package without replacing the
module. When enabled, the module adds Denial's overlay and defaults to
`pkgs.denial`, built with the host's Nixpkgs dependencies. This keeps the
compositor's libc and graphics libraries aligned with the system's drivers,
including on NixOS unstable. The overlay also respects the host's package
overrides.

Plugin tooling is a separate `denial-plugin-manager` flake package and
`pkgs.denialPluginManager` overlay attribute. Set
`programs.denial.plugins.enable = true` to install it. Its wrapper puts the
exact locked Dart derivation in `PATH`; the main `pkgs.denial` closure does not
contain the Plugin Manager or compiler kit.

Flutter and Skia source revisions remain pinned by `SOURCE_LOCK.json`.
Denial takes its private Flutter build helper definitions from its locked
Nixpkgs source. The expensive engine/compiler build uses that pinned package set
so its cache identity survives host updates. A small host-specific derivation
verifies the complete artifact manifest and adapts the engine and its matching
Dart SDK to the host's loader and libraries. Compiler snapshots require the exact
SDK hash, so the SDK stays paired with the engine even when another SDK reports
the same Dart version. The compositor, shell and native Flutter apps use the
host's package set. There is no need to make Denial's
Nixpkgs input follow the host's input; doing so also changes the engine cache key.

Hosts below the producer's glibc or GNU compiler-runtime baseline, or using a
different compiler family, build the engine with their own package set. To
deliberately use this path on any host:

```nix
programs.denial.engine.buildFromSource = true;
```

Both paths consume the same exact source locks. The source option rebuilds the
engine and does not affect the compositor's host dependency alignment.

The standalone `denial.packages.x86_64-linux.denial` output still builds with
Denial's own Nixpkgs lock for reproducible CI and direct flake builds. Use the
module or overlay for NixOS integration so native dependencies follow the
host:

```nix
{
  nixpkgs.overlays = [ denial.overlays.default ];
  # pkgs.denial and pkgs.denialFlutter now use this system's package set.
}
```

The module also registers the Wayland session, Denial's Settings portal and
systemd user unit, the wlroots screenshot/screencast portal, Xwayland, polkit,
realtime scheduling, and Denial's CJK fallback font.

The module starts a PolicyKit authentication agent by default and enables I2C
access for DDC monitor controls. Existing desktop integrations can replace or
disable these defaults:

```nix
{ pkgs, ... }:
{
  programs.denial = {
    polkitAgent.enable = false;
    # Or retain the service with another absolute executable:
    # polkitAgent.command = "${pkgs.someAgent}/bin/some-agent";
    ddc.enable = false;
  };
}
```

Screen sharing uses an absolute Zenity executable path. Denial does not yet
implement layer-shell, so the module explicitly supplies this regular
xdg-shell chooser to `xdg-desktop-portal-wlr` instead of relying on its default
Slurp chooser.

Denial resolves its compositor, control client, Settings executable, Flutter
bundle, and packaged defaults from the installed package prefix. A Nix store
path is therefore supported directly; no `/usr/bin` compatibility links are
needed. Machine-specific configuration can still replace the packaged
defaults conventionally:

```nix
{
  environment.etc."denial/session.conf".source = ./session.conf;
  environment.etc."denial/outputs.conf".source = ./outputs.conf;
}
```

An ordinary writable `~/.config/denial/outputs.conf` remains the live display
state for compatibility. A read-only file or symlink there, including a Home
Manager link into the Nix store, is instead treated as declarative input. The
launcher gives Denial a writable copy at
`$XDG_STATE_HOME/denial/outputs.conf`; live changes persist until the
declarative source changes, at which point that source becomes the new state.
When no per-user file exists, `/etc/denial/outputs.conf` is the declarative
source and therefore follows later system rebuilds.

## Build resources and lock maintenance

Trusted `dev` and `main` validation builds publish Denial's Nix outputs to the
public `denial.cachix.org` cache. The top-level example repeats the cache URL
and signing key because Nix does not apply the `nixConfig` of a flake used only
as an input. Direct commands against the Denial flake can accept its identical
checked-in configuration with `--accept-flake-config`.

The separately published `denial-flutter-engine-raw` output contains the locked
release engine, matching Dart SDK and compiler assets, with a complete checksum/mode
inventory, architecture, source-lock and fetch-lock hashes, and the actual GN configuration
hash. Its producer derivation is independent of the consumer's Nixpkgs and
overlays. Nix verifies the signed cache output against that exact derivation;
host adaptation verifies the manifest and every file before modifying copies.
It removes producer library/loader paths and selects the host's dependencies.

A newer compatible host normally downloads that raw output and builds only the
small adaptation step, compositor and Dart applications. Cache misses build the
pinned producer from its locked sources automatically. Older or explicitly
source-selected hosts build the engine with their host package set instead.

A complete package cache hit still does not guarantee compatibility with a
different host graphics stack.
Overriding `programs.denial.package` with
`denial.packages.${system}.denial` retains Denial's pinned native dependencies;
after a host update, drivers loaded from `/run/opengl-driver` can require glibc
symbols that the cached package's libc does not provide. Keep the module's
default package for host dependency alignment.

CI checks stable and the separately locked unstable package set, requiring one
identical raw engine producer, host libc alignment, complete artifact verification
and engine/AOT/Mesa loading. Its negative test models an older process loading a
newer Mesa driver when the libc baselines differ. Actual graphics/session tests
are recorded in [the validation results](VALIDATION.md).

If startup reports GBM backend initialization failure for an already-open DRM
device, the device was opened successfully. A GBM `No such file or directory`
error can refer to loading a driver or its dependencies. Check the preceding
Mesa loader output on stderr or in the display manager's session logs for the
underlying error, including missing `GLIBC_*` symbols.

A cache miss still performs the complete source build and has
required more than 48 GiB of temporary Nix store space on the validation host;
plan a builder with at least 64 GiB of free working space. Subsequent builds
reuse Nix store objects, and source filtering keeps the engine and unrelated
Flutter applications from rebuilding.

The following checked-in locks make source changes explicit:

- `nix/flutter-engine-lock.json` records every fixed-output hash associated
  with `prebuilt/flutter-engine/SOURCE_LOCK.json`;
- the three `nix/*-pubspec-lock.json` files are generated representations of
  their authoritative Dart lock or Flutter tool input.

After advancing the engine source lock, run:

```sh
tools/denial-nix refresh-engine-lock
tools/denial-nix refresh-pub-locks
tools/denial-nix verify-locks
```

The helper obtains its pinned `jq` and `yq` maintenance tools from this flake,
so they do not need to be installed globally.

The regular `tools/denial-flutter-engine refresh-metadata` workflow invokes
the corresponding Nix refresh when its required tools are available. Nix
evaluation rejects a stale engine or Pub lock before a normal package build
can silently use it.

The flake currently exposes `x86_64-linux`; native AArch64 Nix output will be
added after its engine source closure is independently pinned and validated.
