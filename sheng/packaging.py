#!/usr/bin/env python3
"""ARM64 build metadata and packaging adapter; never edits upstream sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import struct
import subprocess
import tarfile

PACKAGES = ("denial", "denial-flutter-engine", "denial-plugin-manager")
ARM_RELEASE = "prebuilt/flutter-engine/linux-arm64-release"
X64_RELEASE = "prebuilt/flutter-engine/linux-x64-release"
WORKFLOW = ".github/workflows/sheng-arm64.yml"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def permitted_changes(paths):
    return all(
        not path.startswith("/") and ".." not in Path(path).parts
        and (path.startswith("sheng/") or path == WORKFLOW)
        for path in paths
    )


def verify_taskbar_pin(root, pin):
    """Check our provenance record against the pinned upstream Pub lock format."""
    if (pin.get("repository") != "https://github.com/denialwm/denial-plugins.git"
            or pin.get("path") != "plugins/denial_taskbar"
            or not re.fullmatch(r"[0-9a-f]{40}", pin.get("revision", ""))):
        raise ValueError("invalid official taskbar source pin")
    text = (Path(root) / "dart_shell/pubspec.lock").read_text()
    blocks = re.findall(r"^  denial_taskbar:\n((?:    [^\n]*\n)+)", text, re.M)
    if len(blocks) != 1:
        raise ValueError("upstream taskbar lock entry is missing or changed format")
    expected = {"path": pin["path"], "ref": pin["revision"],
                "resolved-ref": pin["revision"], "url": pin["repository"]}
    for field, value in expected.items():
        if re.findall(r"^      " + field + r': "([^"\n]+)"$', blocks[0], re.M) != [value]:
            raise ValueError(f"upstream taskbar lock differs: {field}")
    if "    source: git\n" not in blocks[0]:
        raise ValueError("upstream taskbar must use a Git source")


def verify_taskbar_plan(plan, pin):
    root = plan.get("roots", {}).get("denial_taskbar", {})
    expected_source = {"kind": "git", "location": pin["repository"],
                       "path": pin["path"], "ref": pin["revision"]}
    if (root.get("name") != "denial_taskbar" or root.get("revision") != pin["revision"]
            or root.get("source") != expected_source):
        raise ValueError("taskbar plan did not resolve the exact official Git package")
    discovery = plan.get("discovery", {})
    plugins = discovery.get("plugins", [])
    if ("denial_taskbar" not in plugins
            or set(plugins) & {"denial_top_bar", "sheng_desktop", "sheng_mobile"}):
        raise ValueError("taskbar composition is missing the taskbar or includes another panel")
    contributions = discovery.get("contributions", [])
    library = "package:denial_taskbar/denial_taskbar.dart"
    for name, contract in (("TaskbarPlugin", "ShellSurface"), ("TaskbarWorkArea", "ShellWorkArea")):
        matches = [c for c in contributions if c.get("package") == "denial_taskbar"
                   and c.get("type") == {"library": library, "name": name}
                   and {"library": "package:denial_flutter_sdk/surfaces.dart", "name": contract}
                   in c.get("contracts", [])]
        if len(matches) != 1:
            raise ValueError(f"taskbar composition must provide exactly one {name}")
    owners = [c for c in contributions
              if {"library": "package:denial_flutter_sdk/surfaces.dart", "name": "ShellWorkArea"}
              in c.get("contracts", [])]
    if len(owners) != 1:
        raise ValueError("taskbar composition has conflicting work-area providers")


def guard_source(root, pin):
    """Permit only the external adapter on top of the pinned upstream tree."""
    root = Path(root).resolve()
    if (pin.get("schema") != 1 or pin.get("architecture") != "aarch64"
            or pin.get("glibc_baseline") != "2.39"):
        raise ValueError("unsupported sheng build pin schema, architecture, or GLIBC baseline")
    revision = pin["upstream_revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("upstream_revision must be a full Git SHA")
    run("git", "-C", str(root), "merge-base", "--is-ancestor", revision, "HEAD")
    changed = output("git", "-C", str(root), "diff", "--name-only", revision, "HEAD").splitlines()
    if not permitted_changes(changed):
        raise ValueError("checkout contains downstream changes outside sheng/ and its workflow")
    run("git", "-C", str(root), "diff", "--exit-code", "HEAD", "--")
    if output("git", "-C", str(root), "ls-files", "--others", "--exclude-standard"):
        raise ValueError("checkout contains untracked build inputs")
    source_lock = root / "prebuilt/flutter-engine/SOURCE_LOCK.json"
    if digest(source_lock) != pin["engine_source_lock_sha256"]:
        raise ValueError("SOURCE_LOCK.json does not match the reviewed sheng pin")
    verify_taskbar_pin(root, pin["taskbar"])
    return output("git", "-C", str(root), "rev-parse", "HEAD")


def elf_machine(path):
    with Path(path).open("rb") as stream:
        header = stream.read(20)
    if not header.startswith(b"\x7fELF"):
        return None
    if len(header) < 20 or header[4] != 2 or header[5] != 1:
        raise ValueError(f"not a 64-bit little-endian ELF: {path}")
    return struct.unpack_from("<H", header, 18)[0]


def require_arm_elf(path):
    if elf_machine(path) != 183:
        raise ValueError(f"expected an AArch64 ELF: {path}")


def check_gn_args(text):
    expected = {
        "host_os": '"linux"', "target_os": '"linux"',
        "host_cpu": '"arm64"', "target_cpu": '"arm64"',
        "dart_target_arch": '"arm64"', "flutter_runtime_mode": '"release"',
        "slimpeller": "true", "flutter_use_fontconfig": "true",
    }
    for key, value in expected.items():
        values = re.findall(r"^" + re.escape(key) + r"\s*=\s*(.*?)\s*$", text, re.M)
        if values != [value]:
            raise ValueError(f"generated engine args do not contain exactly {key} = {value}")


def publish_generated(path, data):
    """Never replace a conflicting or symlinked metadata input."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f"refusing generated metadata symlink: {path}")
    if path.exists():
        if not path.is_file() or path.read_bytes() != data:
            raise ValueError(f"existing metadata differs from this build: {path}")
        return
    with path.open("xb") as stream:
        stream.write(data)
    path.chmod(0o644)


def prepare_engine_metadata(root, engine_out, pin):
    root, engine_out = Path(root), Path(engine_out)
    lock = json.loads((root / "prebuilt/flutter-engine/SOURCE_LOCK.json").read_text())
    engine = engine_out / "libflutter_engine.so"
    require_arm_elf(engine)
    args = (engine_out / "args.gn").read_text()
    check_gn_args(args)
    release = root / ARM_RELEASE
    if not release.is_dir() or release.is_symlink():
        raise ValueError("native prepare-app-build must create the ARM release directory first")
    if digest(release / "libflutter_engine.so") != digest(engine):
        raise ValueError("staged native engine differs from the built engine")
    reference = root / X64_RELEASE
    if (reference / "FLUTTER_REVISION").read_text().strip() != lock["flutter"]["upstream_revision"]:
        raise ValueError("architecture-independent Flutter ABI stamp differs from SOURCE_LOCK")
    # These notices and upstream ABI revision stamps describe the same locked
    # source, not an assertion that an x64 binary qualifies the ARM64 build.
    for name in ("LICENSE.flutter", "LICENSE.third_party", "ENGINE_REVISION", "FLUTTER_REVISION"):
        publish_generated(release / name, (reference / name).read_bytes())
    publish_generated(release / "args.gn", args.encode())
    sha = digest(engine)
    publish_generated(release / "libflutter_engine.so.sha256", f"{sha}  libflutter_engine.so\n".encode())
    info = ("# Community ARM64 release build\n\n"
            f"Upstream Denial: `{pin['upstream_revision']}`\n\n"
            f"Flutter fork: `{lock['flutter']['revision']}`\n\n"
            f"Engine SHA-256: `{sha}`\n\n"
            "Built from the locked source using native ARM64 prepare-app-build. "
            "This checksum records this build; it is not an upstream hardware certification.\n")
    publish_generated(release / "BUILD_INFO.md", info.encode())
    manifest = json.loads((root / "packaging/arch/flutter-engine/manifest.json").read_text())
    manifest["package"]["architecture"] = "aarch64"
    manifest["package"]["version_source"] = "development-source-commit"
    manifest["source_lock"]["sha256"] = digest(root / "prebuilt/flutter-engine/SOURCE_LOCK.json")
    manifest["artifacts"] = {
        "gn_args_sha256": digest(engine_out / "args.gn"),
        "libflutter_engine_sha256": sha,
    }
    manifest["assurances"] = {
        "source_build_verified": True, "arm64_hardware_verified": False,
        "reproducible_package": False, "signed_generation_tags": False,
    }
    publish_generated(release / "manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())
    print(f"Recorded native ARM64 engine metadata: {sha}")


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("upstream packaging template changed; review the adapter before building")
    return text.replace(old, new, 1)


def render_adapters(root, destination):
    """Render reviewed packaging-only adaptations outside the upstream tree."""
    root, destination = Path(root).resolve(), Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    stage = (root / "tools/stage-denial-runtime").read_text()
    rpm = (root / "tools/package-denial-rpm").read_text()
    verifier = (root / "tools/verify-denial-native-package-metadata").read_text()
    spec = (root / "packaging/fedora/denial.spec").read_text()
    root_line = 'ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"'
    stage = replace_once(stage, root_line, "ROOT=" + shlex.quote(str(root)))
    rpm = replace_once(rpm, root_line, "ROOT=" + shlex.quote(str(root)))
    build_block = ('DENIAL_BUILD_VERSION="$build_identity" \\\n'
                   'DENIAL_PC_BUNDLE="$BUNDLE" \\\n'
                   'DENIAL_PC_BUNDLE_ASSEMBLY="$BUNDLE_ASSEMBLY" \\\n'
                   '  "$ROOT/tools/denial-pc" build')
    stage = replace_once(stage, build_block,
                         "printf '%s\\n' 'Staging the single completed sheng build; no rebuild.'")
    stage = replace_once(stage, 'engine_source_root="$ROOT/' + X64_RELEASE + '"',
                         'engine_source_root="$ROOT/' + ARM_RELEASE + '"')
    stage = replace_once(stage, '"$ROOT/packaging/arch/flutter-engine/manifest.json"',
                         '"$ROOT/' + ARM_RELEASE + '/manifest.json"')
    spec = replace_once(spec, "ExclusiveArch:  x86_64", "ExclusiveArch:  aarch64")
    rpm = replace_once(rpm, 'RPM_SPEC="$ROOT/packaging/fedora/denial.spec"',
                       "RPM_SPEC=" + shlex.quote(str(destination / "denial.spec")))
    if rpm.count(".x86_64.rpm") != 3:
        raise ValueError("upstream RPM collector changed")
    rpm = rpm.replace(".x86_64.rpm", ".aarch64.rpm")
    verifier = replace_once(verifier, '[[ "$package_arch" == x86_64 ]]',
                            '[[ "$package_arch" == aarch64 ]]')
    verifier = replace_once(verifier, 'targets $package_arch, expected x86_64',
                            'targets $package_arch, expected aarch64')
    metadata_verifier = shlex.quote(str(destination / "verify-native-metadata"))
    if rpm.count('"$ROOT/tools/verify-denial-native-package-metadata"') != 3:
        raise ValueError("upstream RPM verification chain changed")
    rpm = rpm.replace('"$ROOT/tools/verify-denial-native-package-metadata"', metadata_verifier)
    for name, text in (("stage", stage), ("package-rpm", rpm), ("verify-native-metadata", verifier)):
        path = destination / name
        path.write_text(text)
        path.chmod(0o755)
        run("bash", "-n", str(path))
    (destination / "denial.spec").write_text(spec)
    return destination


def inventory(root):
    result = {}
    root = Path(root).resolve()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve(strict=True).is_relative_to(root):
                raise ValueError(f"payload symlink escapes its package: {relative}")
            result[relative] = {"type": "symlink", "mode": mode, "target": target}
        elif stat.S_ISDIR(info.st_mode):
            result[relative] = {"type": "directory", "mode": mode}
        elif stat.S_ISREG(info.st_mode):
            if mode & 0o6000:
                raise ValueError(f"unexpected setuid/setgid payload: {relative}")
            result[relative] = {"type": "file", "mode": mode, "size": info.st_size, "sha256": digest(path)}
        else:
            raise ValueError(f"special file in payload: {relative}")
    return result


def check_elf_tree(root, baseline):
    limit = tuple(map(int, baseline.split(".")))
    count = 0
    for path in Path(root).rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        machine = elf_machine(path)
        if machine is None:
            continue
        if machine != 183:
            raise ValueError(f"non-AArch64 ELF in payload: {path}")
        versions = output("readelf", "--version-info", "--wide", str(path))
        for version in re.findall(r"GLIBC_([0-9]+(?:\.[0-9]+)+)", versions):
            if tuple(map(int, version.split("."))) > limit:
                raise ValueError(f"{path.name} requires GLIBC_{version}, above {baseline}")
        count += 1
    if count == 0:
        raise ValueError(f"no ELF files were checked under {root}")
    return count


def freeze_stage(stage, root):
    stage, root = Path(stage), Path(root)
    metadata = json.loads((stage / "metadata.json").read_text())
    run(str(root / "tools/read-denial-native-metadata"), str(stage / "metadata.json"), stdout=subprocess.DEVNULL)
    for package in PACKAGES:
        payload = stage / package
        files = inventory(payload)
        if not files:
            raise ValueError(f"empty payload: {package}")
        count = check_elf_tree(payload, metadata["glibc_baseline"])
        write_json(stage / (package + ".frozen.json"), files)
        print(f"Frozen {package}: {len(files)} entries, {count} ARM64 ELF files")
    kit = stage / "denial-plugin-manager/usr/lib/denial/plugin-build-kit"
    kit_data = json.loads((kit / "kit.json").read_text())
    if not kit_data:
        raise ValueError("empty compiler kit metadata")
    official = stage / "denial/usr/lib/denial/flutter/.denial-ui-source.json"
    if official.read_bytes() != (kit / "runtime/.denial-ui-source.json").read_bytes():
        raise ValueError("runtime and compiler kit source identities differ")
    if (kit / "flutter/bin/cache/dart-sdk").exists():
        raise ValueError("compiler kit unexpectedly contains a Dart SDK")


def verify_frozen(stage):
    stage = Path(stage)
    for package in PACKAGES:
        expected = json.loads((stage / (package + ".frozen.json")).read_text())
        if not expected or inventory(stage / package) != expected:
            raise ValueError(f"frozen staging payload changed: {package}")


def verify_rpms(stage, package_root):
    stage, package_root = Path(stage), Path(package_root)
    verify_frozen(stage)
    expected = json.loads((stage / "metadata.json").read_text())
    paths = sorted(package_root.glob("*.rpm"))
    if len(paths) != len(PACKAGES):
        raise ValueError("expected exactly runtime, engine, and manager RPMs")
    names = set()
    for path in paths:
        values = output("rpm", "-qp", "--qf", "%{NAME}\n%{ARCH}\n%{VERSION}\n%{RELEASE}", str(path)).splitlines()
        if len(values) != 4:
            raise ValueError("invalid RPM identity response")
        name, arch, version, release = values
        if name not in PACKAGES or name in names or arch != "aarch64":
            raise ValueError(f"unexpected or duplicate RPM: {values}")
        if version != expected["package_version"] or release != str(expected["package_release"]):
            raise ValueError(f"package identity differs from frozen staging: {path}")
        names.add(name)
        run(str(Path(__file__).resolve().parents[1] / "tools/verify-denial-package-payload"),
            "rpm", str(path), str(stage / name))
    if names != set(PACKAGES):
        raise ValueError("missing RPM component")


def build_smoke_candidate(command, plan, state, prefix):
    candidate = plan.get("id")
    if not isinstance(candidate, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", candidate):
        raise ValueError("plugin plan did not return a valid candidate")
    built = command("build", candidate)
    bundle = Path(built["bundle"]).resolve()
    if not bundle.is_relative_to(state.resolve()):
        raise ValueError("plugin build escaped the isolated manager state")
    manifest = json.loads((bundle / "denial-plugin-bundle.json").read_text())
    require_arm_elf(bundle / "lib/libapp.so")
    if (manifest["id"] != candidate or manifest["platform"] != "linux-arm64"
            or manifest["mode"] != "release"
            or manifest["source_identity"] != json.loads((prefix / "usr/lib/denial/flutter/.denial-ui-source.json").read_text())
            or manifest["app_sha256"] != digest(bundle / "lib/libapp.so")
            or manifest["engine_sha256"] != digest(prefix / "usr/lib/denial/flutter/lib/libflutter_engine.so")):
        raise ValueError("composition smoke returned mismatched artifacts")
    return {"candidate": candidate, "plan": "passed", "build": "passed",
            "app_sha256": manifest["app_sha256"], "engine_sha256": manifest["engine_sha256"]}


def smoke_plugins(work, sdk, pin):
    """Build built-ins and the official Git taskbar from packages, never activate."""
    work, sdk = Path(work), Path(sdk).resolve()
    prefix = work / "smoke/prefix"
    prefix.mkdir(parents=True, exist_ok=False)
    for rpm in sorted((work / "artifacts").glob("*.rpm")):
        producer = subprocess.Popen(["rpm2cpio", str(rpm)], stdout=subprocess.PIPE)
        try:
            consumer = subprocess.run(["bsdtar", "-xpf", "-", "-C", str(prefix)], stdin=producer.stdout)
            producer.stdout.close()
            if producer.wait() or consumer.returncode:
                raise ValueError(f"cannot extract package for smoke: {rpm.name}")
        finally:
            if producer.poll() is None:
                producer.kill()
                producer.wait()
    installed_inventory = inventory(prefix)
    home = work / "smoke/home"
    home.mkdir(mode=0o700)
    env = {name: value for name, value in os.environ.items() if not name.startswith("DENIAL_")}
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "DBUS_STARTER_ADDRESS"):
        env.pop(name, None)
    env["HOME"] = str(home)
    for name, child in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                        ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                        ("XDG_RUNTIME_DIR", "runtime")):
        directory = home / child
        directory.mkdir(mode=0o700)
        env[name] = str(directory)
    env["PATH"] = str(prefix / "usr/bin") + os.pathsep + str(sdk / "bin") + os.pathsep + env["PATH"]
    env["PUB_CACHE"] = str(home / "cache/pub")
    env["TMPDIR"] = str(home / "cache")
    state = home / "manager"
    backend = prefix / "usr/bin/denial-plugins"

    def command(*arguments):
        result = subprocess.run([str(backend), "--state", str(state), *arguments],
                                env=env, text=True, stdout=subprocess.PIPE, timeout=1800, check=True)
        return json.loads(result.stdout)

    command("prepare")
    builtin_plan = command("plan")
    if "denial_top_bar" not in builtin_plan.get("discovery", {}).get("plugins", []):
        raise ValueError("fresh built-in composition is missing its default top bar")
    builtin = build_smoke_candidate(command, builtin_plan, state, prefix)
    taskbar_pin = pin["taskbar"]
    source_options = ("--ref", taskbar_pin["revision"], "--path", taskbar_pin["path"])
    inspected = command(*source_options, "inspect", taskbar_pin["repository"])
    if not any(entry.get("name") == "denial_taskbar" for entry in inspected):
        raise ValueError("official plugin repository did not expose denial_taskbar")
    command(*source_options, "add", taskbar_pin["repository"])
    command("remove", "denial_top_bar")
    plan = command("plan")
    verify_taskbar_plan(plan, taskbar_pin)
    taskbar = build_smoke_candidate(command, plan, state, prefix)
    # Test the exact package Pub used, not a separately fetched moving checkout.
    source = Path(plan["resolvedInputs"]["denial_taskbar"]["root"]).resolve()
    repository = Path(output("git", "-C", str(source), "rev-parse", "--show-toplevel")).resolve()
    if (source != repository / taskbar_pin["path"]
            or output("git", "-C", str(source), "rev-parse", "HEAD") != taskbar_pin["revision"]):
        raise ValueError("Pub's taskbar test source differs from the pinned repository")
    config = state / "candidates" / taskbar["candidate"] / "app/.dart_tool/package_config.json"
    checks = {}
    for name in ("window_groups", "preview_emphasis", "taskbar_preferences"):
        run(str(sdk / "bin/dart"), f"--packages={config}", str(source / f"test/{name}_test.dart"),
            env=env, cwd=source, timeout=120)
        checks[name] = "passed"
    taskbar.update({"source": taskbar_pin, "headless_checks": checks,
                   "pub_lock_sha256": digest(config.parent.parent / "pubspec.lock")})
    if inventory(prefix) != installed_inventory:
        raise ValueError("plugin preparation or build modified package-managed files")
    write_json(work / "artifacts/plugin-smoke.json", {
        "schema": 2, "platform": "linux-arm64", "prepare": "passed",
        "compositions": {"builtins": builtin, "taskbar": taskbar},
        "activated": False, "visual_validation": False,
    })
    print("Isolated built-in and official taskbar composition smokes passed; nothing activated.")


def export_dart(sdk, destination, expected_version):
    sdk, destination = Path(sdk).resolve(), Path(destination)
    actual = (sdk / "version").read_text().strip().split()[0]
    if actual != expected_version:
        raise ValueError(f"Dart version {actual} differs from {expected_version}")
    require_arm_elf(sdk / "bin/dart")
    if not (sdk / "LICENSE").is_file():
        raise ValueError("Dart SDK license is missing")
    files = inventory(sdk)
    check_elf_tree(sdk, "2.39")
    archive = destination / f"dart-sdk-{actual}-linux-arm64.tar.xz"
    with tarfile.open(archive, "x:xz") as tar:
        tar.add(sdk, arcname="dart-sdk")
    write_json(destination / "dart-sdk.inventory.json", files)
    return archive


def verify_smoke_report(smoke, pin):
    if (smoke.get("schema") != 2 or smoke.get("platform") != "linux-arm64"
            or smoke.get("prepare") != "passed" or smoke.get("activated") is not False):
        raise ValueError("installed-package composition smoke has not passed")
    compositions = smoke.get("compositions", {})
    for name in ("builtins", "taskbar"):
        result = compositions.get(name, {})
        if any(result.get(step) != "passed" for step in ("plan", "build")):
            raise ValueError(f"{name} installed-package composition smoke has not passed")
        for key in ("app_sha256", "engine_sha256"):
            if not re.fullmatch(r"[0-9a-f]{64}", result.get(key, "")):
                raise ValueError(f"{name} smoke is missing its {key}")
    taskbar = compositions["taskbar"]
    if (taskbar.get("source") != pin["taskbar"]
            or any(taskbar.get("headless_checks", {}).get(test) != "passed"
                   for test in ("window_groups", "preview_emphasis", "taskbar_preferences"))):
        raise ValueError("official taskbar pin or headless checks differ")


def finish(root, work, sdk, pin):
    root, work = Path(root), Path(work)
    stage = work / "package-input/native"
    packages = work / "artifacts"
    verify_rpms(stage, packages)
    smoke = json.loads((packages / "plugin-smoke.json").read_text())
    verify_smoke_report(smoke, pin)
    dart = export_dart(sdk, packages, pin["dart_version"])
    generated = root / ARM_RELEASE
    expected_metadata = {"libflutter_engine.so", "libflutter_engine.so.sha256", "args.gn",
                         "ENGINE_REVISION", "FLUTTER_REVISION", "LICENSE.flutter",
                         "LICENSE.third_party", "BUILD_INFO.md", "manifest.json"}
    if {p.name for p in generated.iterdir()} != expected_metadata:
        raise ValueError("unexpected files in generated ARM64 metadata directory")
    if any(p.is_symlink() or not p.is_file() for p in generated.iterdir()):
        raise ValueError("generated ARM64 metadata is not regular files")
    record = {
        "schema": 1, "target": "aarch64-unknown-linux-gnu", "distribution": "Fedora 44",
        "upstream_revision": pin["upstream_revision"],
        "build_revision": output("git", "-C", str(root), "rev-parse", "HEAD"),
        "engine_source_lock_sha256": digest(root / "prebuilt/flutter-engine/SOURCE_LOCK.json"),
        "engine_source_lock": json.loads((root / "prebuilt/flutter-engine/SOURCE_LOCK.json").read_text()),
        "generated_arm_metadata": {p.name: digest(p) for p in sorted(generated.iterdir())},
        "package_metadata": json.loads((stage / "metadata.json").read_text()),
        "compiler_kit_sha256": digest(stage / "denial-plugin-manager/usr/lib/denial/plugin-build-kit/kit.json"),
        "dart_archive": dart.name, "dart_version": pin["dart_version"],
        "taskbar": pin["taskbar"], "plugin_smoke_sha256": digest(packages / "plugin-smoke.json"),
        "rustc": output("rustc", "--version"), "hardware_validated": False,
        "signed_release": False, "upstream_core_modified": False,
    }
    for package in PACKAGES:
        shutil.copyfile(stage / (package + ".frozen.json"), packages / (package + ".inventory.json"))
    write_json(packages / "build-record.json", record)
    with (packages / "SHA256SUMS").open("x") as stream:
        for path in sorted(packages.iterdir()):
            if path.is_file() and path.name != "SHA256SUMS":
                stream.write(f"{digest(path)}  {path.name}\n")
    print(f"Verified candidate artifacts: {packages}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("guard", "engine-metadata", "render", "freeze", "verify-frozen", "smoke", "finish"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--engine-out", type=Path)
    parser.add_argument("--sdk", type=Path)
    args = parser.parse_args()
    pin = json.loads((args.root / "sheng/source.lock.json").read_text())
    if args.command == "guard":
        print(guard_source(args.root, pin))
    elif args.command == "engine-metadata":
        if args.engine_out is None:
            parser.error("engine-metadata requires --engine-out")
        prepare_engine_metadata(args.root, args.engine_out, pin)
    else:
        if args.work is None:
            parser.error("this command requires --work")
        if args.command == "render":
            render_adapters(args.root, args.work / "adapters")
        elif args.command == "freeze":
            freeze_stage(args.work / "package-input/native", args.root)
        elif args.command == "verify-frozen":
            verify_frozen(args.work / "package-input/native")
        elif args.command in ("smoke", "finish"):
            if args.sdk is None:
                parser.error("smoke/finish require --sdk")
            if args.command == "smoke":
                smoke_plugins(args.work, args.sdk, pin)
            else:
                finish(args.root, args.work, args.sdk, pin)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"sheng packaging: {error}") from error
