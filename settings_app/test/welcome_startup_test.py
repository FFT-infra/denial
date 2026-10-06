"""Exercise the native startup gate with no access to a graphical session."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())


def invoke(root, *, config=None, manual=False):
    env = dict(os.environ)
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET"):
        env.pop(name, None)
    env.update(
        HOME=str(root),
        XDG_CONFIG_HOME=str(root / "config") if config is None else config,
        XDG_STATE_HOME=str(root / "state"),
        XDG_RUNTIME_DIR=str(root),
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={root}/absent-bus",
        GDK_BACKEND="wayland",
    )
    command = [binary, "--welcome"]
    if not manual:
        command.append("--autostart")
    return subprocess.run(command, env=env, capture_output=True, timeout=10)


with tempfile.TemporaryDirectory(prefix="denial-welcome-startup-") as directory:
    root = Path(directory)
    marker = root / "config/denial/welcome"
    marker.parent.mkdir(parents=True)
    # No sentinel: startup proceeds to native activation and fails only because
    # this fixture has neither a session bus nor a display.
    assert invoke(root).returncode != 0
    marker.touch()
    assert invoke(root).returncode == 0
    assert invoke(root, manual=True).returncode != 0
    marker.unlink()
    assert invoke(root).returncode != 0

    legacy = root / "state/denial/welcome-completed"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("1\n")
    assert invoke(root).returncode == 0
    assert marker.read_text() == "1\n"
    assert not legacy.exists()
    marker.unlink()
    assert invoke(root).returncode != 0

    fallback = root / ".config/denial/welcome"
    fallback.parent.mkdir(parents=True)
    fallback.touch()
    assert invoke(root, config="").returncode == 0
    assert invoke(root, config="relative").returncode == 0

print("PASS: incomplete startup, completion, manual reopening, reset, migration, and XDG fallback")
