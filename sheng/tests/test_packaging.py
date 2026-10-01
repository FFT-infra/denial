import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sheng_packaging", ROOT / "sheng/packaging.py")
packaging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packaging)

ARM_ARGS = '''host_os = "linux"
target_os = "linux"
host_cpu = "arm64"
target_cpu = "arm64"
dart_target_arch = "arm64"
flutter_runtime_mode = "release"
slimpeller = true
flutter_use_fontconfig = true
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix=".test-", dir=ROOT / "sheng")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def test_scope_allows_only_adapter_and_its_workflow(self):
        self.assertTrue(packaging.permitted_changes(["sheng/build.sh", packaging.WORKFLOW]))
        for path in ("compositor/src/lib.rs", "packages/denial_sdk/lib/denial_sdk.dart",
                     "tools/denial-pc", ".github/workflows/release.yml", "AGENTS.md",
                     "sheng/../../compositor/lib.rs", "/sheng/adapter.py"):
            self.assertFalse(packaging.permitted_changes([path]), path)

    def test_source_lock_digest_matches_reviewed_input(self):
        pin = json.loads((ROOT / "sheng/source.lock.json").read_text())
        self.assertEqual(packaging.digest(ROOT / "prebuilt/flutter-engine/SOURCE_LOCK.json"),
                         pin["engine_source_lock_sha256"])
        self.assertEqual(pin["architecture"], "aarch64")
        self.assertEqual(pin["dart_version"], "3.13.4")
        packaging.verify_taskbar_pin(ROOT, pin["taskbar"])

    def test_gn_args_require_arm_release_and_slimpeller(self):
        packaging.check_gn_args(ARM_ARGS)
        for invalid in (ARM_ARGS.replace('"arm64"', '"x64"'),
                        ARM_ARGS.replace('"release"', '"debug"'),
                        ARM_ARGS.replace("slimpeller = true\n", ""),
                        ARM_ARGS + 'target_cpu = "arm64"\n'):
            with self.assertRaises(ValueError):
                packaging.check_gn_args(invalid)

    def test_generated_metadata_is_write_once(self):
        path = self.root / "engine.sha256"
        packaging.publish_generated(path, b"one\n")
        packaging.publish_generated(path, b"one\n")
        with self.assertRaises(ValueError):
            packaging.publish_generated(path, b"two\n")
        self.assertEqual(path.read_bytes(), b"one\n")

    def test_generated_metadata_refuses_symlinks(self):
        target = self.root / "target"
        target.write_bytes(b"one")
        link = self.root / "link"
        link.symlink_to(target)
        with self.assertRaises(ValueError):
            packaging.publish_generated(link, b"one")
        self.assertEqual(target.read_bytes(), b"one")

    def test_elf_header_rejects_wrong_class_endian_and_machine(self):
        # Header parser fixture only, not a valid package or executable fixture.
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 183)
        path = self.root / "header"
        path.write_bytes(header)
        self.assertEqual(packaging.elf_machine(path), 183)
        for index, value in ((4, 1), (5, 2)):
            invalid = header.copy()
            invalid[index] = value
            path.write_bytes(invalid)
            with self.assertRaises(ValueError):
                packaging.elf_machine(path)
        struct.pack_into("<H", header, 18, 62)
        path.write_bytes(header)
        with self.assertRaises(ValueError):
            packaging.require_arm_elf(path)

    def test_non_elf_is_not_misreported_as_an_arm_binary(self):
        path = self.root / "text"
        path.write_text("not an ELF\n")
        self.assertIsNone(packaging.elf_machine(path))
        with self.assertRaises(ValueError):
            packaging.require_arm_elf(path)

    def test_template_drift_or_multiple_matches_fail(self):
        self.assertEqual(packaging.replace_once("a b", "a", "c"), "c b")
        for text in ("b", "a a"):
            with self.assertRaises(ValueError):
                packaging.replace_once(text, "a", "c")

    def test_rendering_preserves_upstream_and_removes_rebuild(self):
        files = [ROOT / "tools/stage-denial-runtime", ROOT / "tools/package-denial-rpm",
                 ROOT / "tools/verify-denial-native-package-metadata",
                 ROOT / "packaging/fedora/denial.spec"]
        before = {str(p): packaging.digest(p) for p in files}
        result = packaging.render_adapters(ROOT, self.root / "adapters")
        stage = (result / "stage").read_text()
        rpm = (result / "package-rpm").read_text()
        verifier = (result / "verify-native-metadata").read_text()
        self.assertNotIn('"$ROOT/tools/denial-pc" build', stage)
        self.assertIn('engine_source_root="$ROOT/' + packaging.ARM_RELEASE + '"', stage)
        self.assertIn('"$ROOT/' + packaging.ARM_RELEASE + '/manifest.json"', stage)
        self.assertEqual(rpm.count(".aarch64.rpm"), 3)
        self.assertNotIn(".x86_64.rpm", rpm)
        self.assertIn('[[ "$package_arch" == aarch64 ]]', verifier)
        self.assertIn("ExclusiveArch:  aarch64", (result / "denial.spec").read_text())
        self.assertIn('"$ROOT/tools/verify-denial-package-payload"', rpm)
        self.assertEqual(before, {str(p): packaging.digest(p) for p in files})

    def test_rendering_refuses_existing_destination(self):
        destination = self.root / "adapters"
        destination.mkdir()
        marker = destination / "keep"
        marker.write_text("user data")
        with self.assertRaises(FileExistsError):
            packaging.render_adapters(ROOT, destination)
        self.assertEqual(marker.read_text(), "user data")

    def test_inventory_captures_content_mode_and_safe_links(self):
        data = self.root / "data"
        data.mkdir()
        file = data / "file"
        file.write_text("hello")
        file.chmod(0o644)
        (data / "alias").symlink_to("file")
        result = packaging.inventory(data)
        self.assertEqual(result["file"]["sha256"], packaging.digest(file))
        self.assertEqual(result["file"]["mode"], 0o644)
        self.assertEqual(result["alias"]["target"], "file")

    def test_inventory_rejects_escape_and_broken_links(self):
        data = self.root / "data"
        data.mkdir()
        outside = self.root / "outside"
        outside.write_text("must not read")
        link = data / "alias"
        link.symlink_to("../outside")
        with self.assertRaises(ValueError):
            packaging.inventory(data)
        link.unlink()
        link.symlink_to("missing")
        with self.assertRaises(FileNotFoundError):
            packaging.inventory(data)

    def test_inventory_rejects_privileged_modes(self):
        data = self.root / "data"
        data.mkdir()
        file = data / "file"
        file.write_text("not privileged")
        file.chmod(stat.S_ISUID | 0o755)
        with self.assertRaises(ValueError):
            packaging.inventory(data)

    def frozen_stage(self):
        stage = self.root / "stage"
        stage.mkdir()
        for name in packaging.PACKAGES:
            payload = stage / name
            payload.mkdir()
            (payload / "data").write_text(name)
            packaging.write_json(stage / (name + ".frozen.json"), packaging.inventory(payload))
        return stage

    def test_frozen_payload_detects_content_changes(self):
        stage = self.frozen_stage()
        packaging.verify_frozen(stage)
        (stage / "denial/data").write_text("changed")
        with self.assertRaises(ValueError):
            packaging.verify_frozen(stage)

    def test_frozen_payload_detects_mode_or_inventory_changes(self):
        stage = self.frozen_stage()
        (stage / "denial/data").chmod(0o600)
        with self.assertRaises(ValueError):
            packaging.verify_frozen(stage)
        (stage / "denial/data").chmod(0o644)
        (stage / "denial/extra").write_text("extra")
        with self.assertRaises(ValueError):
            packaging.verify_frozen(stage)

    def test_empty_frozen_payload_does_not_pass(self):
        stage = self.frozen_stage()
        packaging.write_json(stage / "denial.frozen.json", {})
        with self.assertRaises(ValueError):
            packaging.verify_frozen(stage)

    def test_elf_verification_rejects_empty_tree(self):
        with self.assertRaises(ValueError):
            packaging.check_elf_tree(self.root, "2.39")

    def test_rpm_set_requires_all_three_components(self):
        stage = self.frozen_stage()
        packaging.write_json(stage / "metadata.json", {"package_version": "0.0.0.r1.gabc", "package_release": 0})
        packages = self.root / "packages"
        packages.mkdir()
        with self.assertRaises(ValueError):
            packaging.verify_rpms(stage, packages)

    def test_rpm_identity_rejects_wrong_architecture(self):
        stage = self.frozen_stage()
        packaging.write_json(stage / "metadata.json", {"package_version": "0.0.0.r1.gabc", "package_release": 0})
        packages = self.root / "packages"
        packages.mkdir()
        for name in packaging.PACKAGES:
            (packages / (name + ".rpm")).write_text("identity fixture, not an RPM")
        with mock.patch.object(packaging, "output", return_value="denial\nx86_64\n0.0.0.r1.gabc\n0"):
            with self.assertRaises(ValueError):
                packaging.verify_rpms(stage, packages)

    def taskbar_pin(self):
        return {
            "repository": "https://github.com/denialwm/denial-plugins.git",
            "path": "plugins/denial_taskbar",
            "revision": "4b7adf998852b09b9a91c1cfab48be58debf2e80",
        }

    def taskbar_plan(self):
        pin = self.taskbar_pin()
        library = "package:denial_taskbar/denial_taskbar.dart"
        return {
            "roots": {"denial_taskbar": {
                "name": "denial_taskbar", "revision": pin["revision"],
                "source": {"kind": "git", "location": pin["repository"],
                           "path": pin["path"], "ref": pin["revision"]},
            }},
            "discovery": {
                "plugins": ["denial_desktop", "denial_taskbar"],
                "contributions": [
                    {"package": "denial_taskbar", "type": {"library": library, "name": name},
                     "contracts": [{"library": "package:denial_flutter_sdk/surfaces.dart", "name": contract}]}
                    for name, contract in (("TaskbarPlugin", "ShellSurface"),
                                           ("TaskbarWorkArea", "ShellWorkArea"))
                ],
            },
        }

    def test_taskbar_pin_matches_upstream_lock(self):
        packaging.verify_taskbar_pin(ROOT, self.taskbar_pin())
        for field, bad in (("revision", "0" * 40), ("path", "plugins/other"),
                           ("repository", "https://example.com/other.git")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                packaging.verify_taskbar_pin(ROOT, {**self.taskbar_pin(), field: bad})

    def test_taskbar_plan_requires_exact_git_source(self):
        packaging.verify_taskbar_plan(self.taskbar_plan(), self.taskbar_pin())
        for field, bad in (("kind", "local"), ("ref", "main"), ("path", "."),
                           ("location", "https://example.com/other.git")):
            plan = self.taskbar_plan()
            plan["roots"]["denial_taskbar"]["source"][field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                packaging.verify_taskbar_plan(plan, self.taskbar_pin())
        plan = self.taskbar_plan()
        plan["roots"]["denial_taskbar"]["revision"] = "0" * 40
        with self.assertRaises(ValueError):
            packaging.verify_taskbar_plan(plan, self.taskbar_pin())

    def test_taskbar_plan_rejects_missing_or_conflicting_contributions(self):
        for kind in ("root", "plugin", "surface", "workarea", "duplicate", "other-workarea", "strip", "topbar"):
            plan = self.taskbar_plan()
            if kind == "root":
                plan["roots"].clear()
            elif kind == "plugin":
                plan["discovery"]["plugins"].remove("denial_taskbar")
            elif kind in ("surface", "workarea"):
                plan["discovery"]["contributions"].pop(0 if kind == "surface" else 1)
            elif kind in ("duplicate", "other-workarea"):
                contribution = json.loads(json.dumps(plan["discovery"]["contributions"][1]))
                if kind == "other-workarea":
                    contribution["type"]["name"] = "OtherWorkArea"
                plan["discovery"]["contributions"].append(contribution)
            else:
                plan["discovery"]["plugins"].append("sheng_desktop" if kind == "strip" else "denial_top_bar")
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                packaging.verify_taskbar_plan(plan, self.taskbar_pin())

    def smoke_report(self):
        result = {"plan": "passed", "build": "passed", "app_sha256": "a" * 64, "engine_sha256": "b" * 64}
        return {"schema": 2, "platform": "linux-arm64", "prepare": "passed", "activated": False,
                "compositions": {"builtins": dict(result), "taskbar": {
                    **result, "source": self.taskbar_pin(),
                    "headless_checks": {name: "passed" for name in
                                        ("window_groups", "preview_emphasis", "taskbar_preferences")},
                }}}

    def test_finish_requires_both_smokes_and_official_headless_checks(self):
        pin = {"taskbar": self.taskbar_pin()}
        packaging.verify_smoke_report(self.smoke_report(), pin)
        for missing in ("builtins", "taskbar"):
            report = self.smoke_report()
            del report["compositions"][missing]
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                packaging.verify_smoke_report(report, pin)
        for field in ("source", "headless_checks", "app_sha256"):
            report = self.smoke_report()
            del report["compositions"]["taskbar"][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                packaging.verify_smoke_report(report, pin)
        report = self.smoke_report()
        report["activated"] = True
        with self.assertRaises(ValueError):
            packaging.verify_smoke_report(report, pin)
        with self.assertRaises(ValueError):
            packaging.verify_smoke_report({"schema": 1, "prepare": "passed", "plan": "passed", "build": "passed"}, pin)

    def test_candidate_smoke_rejects_invalid_id_before_build(self):
        command = mock.Mock()
        for invalid in (None, "../other", "", "/tmp/candidate"):
            with self.subTest(candidate=invalid), self.assertRaises(ValueError):
                packaging.build_smoke_candidate(command, {"id": invalid}, self.root, self.root)
        command.assert_not_called()

    def test_candidate_smoke_propagates_build_failure_and_rejects_escape(self):
        command = mock.Mock(side_effect=subprocess.CalledProcessError(1, "build"))
        with self.assertRaises(subprocess.CalledProcessError):
            packaging.build_smoke_candidate(command, {"id": "candidate"}, self.root, self.root)
        command = mock.Mock(return_value={"bundle": str(self.root.parent)})
        with self.assertRaisesRegex(ValueError, "escaped"):
            packaging.build_smoke_candidate(command, {"id": "candidate"}, self.root, self.root)

    def test_rpm_verification_runs_existing_payload_checker(self):
        stage = self.frozen_stage()
        packaging.write_json(stage / "metadata.json", {"package_version": "0.0.0.r1.gabc", "package_release": 0})
        packages = self.root / "packages"
        packages.mkdir()
        for name in packaging.PACKAGES:
            (packages / (name + ".rpm")).write_text("identity fixture, not an RPM")
        def identity(*args):
            return f"{Path(args[-1]).stem}\naarch64\n0.0.0.r1.gabc\n0"
        with mock.patch.object(packaging, "output", side_effect=identity), mock.patch.object(packaging, "run") as run:
            packaging.verify_rpms(stage, packages)
            self.assertEqual(run.call_count, 3)
            for call in run.call_args_list:
                self.assertEqual(Path(call.args[0]).name, "verify-denial-package-payload")
                self.assertEqual(call.args[1], "rpm")
            run.side_effect = subprocess.CalledProcessError(1, "payload-verifier")
            with self.assertRaises(subprocess.CalledProcessError):
                packaging.verify_rpms(stage, packages)

    def test_portal_test_receives_explicit_descriptor_and_routing_directory(self):
        source = self.root / "source with spaces"
        descriptors = source / "packaging/arch"
        descriptors.mkdir(parents=True)
        for name in ("denial.portal", "denial-portals.conf"):
            (descriptors / name).write_bytes((ROOT / "packaging/arch" / name).read_bytes())
        tools = source / "tools"
        tools.mkdir()
        command = tools / "denial-pc"
        command.write_text('''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == compositor-test ]]
[[ -f "$XDG_DESKTOP_PORTAL_DIR/denial.portal" ]]
[[ -f "$XDG_DESKTOP_PORTAL_DIR/denial-portals.conf" ]]
printf '%s\\n' "$XDG_DESKTOP_PORTAL_DIR"
''')
        command.chmod(0o755)
        lines = [line for line in (ROOT / "sheng/build.sh").read_text().splitlines()
                 if line.startswith("step compositor-test ")]
        self.assertEqual(len(lines), 1)
        env = {**os.environ, "SOURCE": str(source), "XDG_DESKTOP_PORTAL_DIR": str(self.root / "wrong")}
        prefix = 'step() { shift; "$@"; }; '
        result = subprocess.run(["bash", "-c", prefix + lines[0]], cwd=source, env=env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(descriptors))
        # The fixture must fail when the old invocation inherits an unrelated directory.
        old = subprocess.run(["bash", "-c", prefix + "step compositor-test tools/denial-pc compositor-test"],
                             cwd=source, env=env, text=True, capture_output=True)
        self.assertNotEqual(old.returncode, 0)

    def test_build_script_has_no_install_or_activation_command(self):
        script = (ROOT / "sheng/build.sh").read_text()
        self.assertNotIn(" activate ", script)
        self.assertNotIn("dnf install", script)
        self.assertNotIn("rpm -i", script)
        self.assertIn('step frozen-after-packaging', script)
        self.assertIn('step installed-plugin-smoke', script)
        subprocess.run(["bash", "-n", str(ROOT / "sheng/build.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
