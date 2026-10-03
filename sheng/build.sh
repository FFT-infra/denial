#!/usr/bin/env bash
# Build only into a fresh workspace; never installs, activates, or publishes.
set -euo pipefail
umask 022
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 1 && "$1" == /* && ! -e "$1" ]] || {
  printf 'Usage: sheng/build.sh ABSOLUTE_NEW_WORKSPACE\n' >&2
  exit 2
}
[[ "$(uname -m)" == aarch64 ]] || {
  printf 'This is a native ARM64 build, not an x86 cross build.\n' >&2
  exit 1
}
WORK="$1"
for tool in git python3 jq rustup cargo cmake ninja clang pkg-config rsync rpm rpmbuild rpm2cpio bsdtar readelf; do
  command -v "$tool" >/dev/null || { printf 'Missing build prerequisite: %s\n' "$tool" >&2; exit 1; }
done
python3 "$ROOT/sheng/packaging.py" guard --root "$ROOT"
# The caller's checkout remains untouched, including generated ARM metadata.
mkdir -- "$WORK"
mkdir -- "$WORK/logs"
git clone --no-hardlinks --no-local --quiet "$ROOT" "$WORK/source"
SOURCE="$WORK/source"
BUILD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$BUILD_SHA" ]]
# This is our disposable clone, not the caller's shared Git metadata. Only
# architecture metadata produced by this exact build is excluded.
printf '\n/prebuilt/flutter-engine/linux-arm64-release/\n' >> "$SOURCE/.git/info/exclude"

export DENIAL_PC_BUILD_ROOT="$WORK/build"
export DENIAL_PC_RUST_TARGET="$WORK/build/rust"
export DENIAL_PC_BINARY="$DENIAL_PC_RUST_TARGET/release/deniald"
export DENIAL_PC_CONTROL_BINARY="$DENIAL_PC_RUST_TARGET/release/denialctl"
export DENIAL_PC_PORTAL_BINARY="$DENIAL_PC_RUST_TARGET/release/denial-portal"
export DENIAL_PC_DEPENDENCY_ROOT="$WORK/dependencies"
export DENIAL_FLUTTER_ENGINE_CACHE_ROOT="$WORK/engine"
export DENIAL_PC_BUNDLE="$WORK/bundle"
export DENIAL_PC_ENGINE="$DENIAL_PC_BUNDLE/lib/libflutter_engine.so"
export DENIAL_PC_ENGINE_SOURCE="$SOURCE/prebuilt/flutter-engine/linux-arm64-release/libflutter_engine.so"
export DENIAL_PC_BUNDLE_ASSEMBLY="$WORK/assembly"
export DENIAL_PC_SETTINGS_BUNDLE="$SOURCE/settings_app/build/linux/arm64/release/bundle"
export DENIAL_PC_PLUGIN_MANAGER_BUNDLE="$SOURCE/plugin_manager_app/build/linux/arm64/release/bundle"
export DENIAL_PC_PLUGIN_MANAGER_BACKEND="$DENIAL_PC_BUILD_ROOT/plugin-manager/denial-plugins"
export DENIAL_PC_PLUGIN_BUILD_KIT="$DENIAL_PC_BUILD_ROOT/plugin-manager/build-kit"
export DENIAL_PC_POLKIT_BACKEND="$DENIAL_PC_RUST_TARGET/release/denial-polkit-agent"
export DENIAL_PC_POLKIT_BUNDLE="$SOURCE/polkit_app/build/linux/arm64/release/bundle"
export DENIAL_RPM_DISTRIBUTION=fedora
export DENIAL_PC_PACKAGE_INPUT_ROOT="$WORK/package-input"
export DENIAL_PACKAGE_STAGE_ROOT="$WORK/package-input/native"
export DENIAL_PC_PACKAGE_ROOT="$WORK/artifacts"
export DENIAL_BUILD_VERSION="sheng.$BUILD_SHA"
export DENIAL_BUILD_IDENTITY="$DENIAL_BUILD_VERSION"
export DENIAL_PACKAGE_RELEASE=0
export DENIAL_PACKAGE_GLIBC_BASELINE=2.39
export DENIAL_PC_XWAYLAND=1
export DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=0
export DENIAL_BUILD_JOBS=2
export DENIAL_FLUTTER_ENGINE_JOBS=4
export SOURCE_DATE_EPOCH="$(git -C "$SOURCE" show -s --format=%ct HEAD)"
# CI uses the managed source path. Inherited source/SDK overrides would select
# another input or bypass the checkout synchronization contract.
unset DENIAL_FLUTTER_SOURCE_ROOT DENIAL_SKIA_SOURCE_ROOT DENIAL_FLUTTER_SDK_ROOT DENIAL_FLUTTER
unset DENIAL_RELEASE_TAG DENIAL_PACKAGE_VERSION DENIAL_PACKAGE_RUNTIME_VERSION_FILE
export CI=true

step() {
  local label="$1"
  shift
  printf '\n=== %s ===\n' "$label"
  "$@" 2>&1 | tee "$WORK/logs/$label.log"
}
cd -- "$SOURCE"
channel="$(python3 -c 'import tomllib; print(tomllib.load(open("rust-toolchain.toml", "rb"))["toolchain"]["channel"])')"
step rust-toolchain rustup toolchain install "$channel" --profile minimal
step bootstrap tools/denial-pc bootstrap
step native-engine tools/denial-flutter-engine prepare-app-build
ENGINE_OUT="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/build/out/denial_host_release_arm64"
step arm-metadata python3 sheng/packaging.py engine-metadata --root "$SOURCE" --engine-out "$ENGINE_OUT"
# build_all creates the default bundle, settings, manager+kit, then compositor.
# Packaging below never invokes build_all again.
step build tools/denial-pc build
step sdk-test tools/denial-pc sdk-test
step plugin-check tools/denial-pc plugin-check
# Portal 1.18 ignores XDG_DATA_HOME for descriptors; this directory also
# supplies denial-portals.conf for its explicit-directory configuration lookup.
step compositor-test env XDG_DESKTOP_PORTAL_DIR="$SOURCE/packaging/arch" tools/denial-pc compositor-test
step source-guard python3 sheng/packaging.py guard --root "$SOURCE"
step adapters python3 sheng/packaging.py render --root "$SOURCE" --work "$WORK"
step stage "$WORK/adapters/stage"
step freeze python3 sheng/packaging.py freeze --root "$SOURCE" --work "$WORK"
export DENIAL_PACKAGE_SKIP_STAGE=1
step rpm "$WORK/adapters/package-rpm"
step frozen-after-packaging python3 sheng/packaging.py verify-frozen --root "$SOURCE" --work "$WORK"
DART_SDK="$DENIAL_PC_DEPENDENCY_ROOT/flutter/bin/cache/dart-sdk"
step installed-plugin-smoke python3 sheng/packaging.py smoke --root "$SOURCE" --work "$WORK" --sdk "$DART_SDK"
step finish python3 sheng/packaging.py finish --root "$SOURCE" --work "$WORK" --sdk "$DART_SDK"
step final-source-guard python3 sheng/packaging.py guard --root "$SOURCE"
# Only a completely verified workspace receives this marker. The workflow
# never uploads partial RPMs on failure.
printf '%s\n' "$BUILD_SHA" > "$WORK/verified"
printf '\nVerified candidates are in %s/artifacts. No installation was performed.\n' "$WORK"
