#!/usr/bin/env python3
"""
Regression: quit/session restore should capture agent-style resume hints.

The fixture runs in raw TTY mode and only reacts to literal ETX bytes. This
matches full-screen agent CLIs more closely than a normal shell trap:
`surface.send_key ctrl-c` is not sufficient, but injected ETX text is.

The second case requires three ETX bytes to model Claude Code's staged quit:
1. interrupt active work
2. show "Press Ctrl-C again to exit"
3. print the final resume hint and exit
"""

from __future__ import annotations

import base64
import json
import os
import plistlib
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests_v2"))

from cmux import cmux  # type: ignore


FIXTURE_SOURCE = r"""#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import termios
import tty


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--required-interrupts", type=int, required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    count = 0
    tty.setraw(fd)
    try:
        sys.stdout.write(f"FIXTURE_READY {args.label}\r\n")
        sys.stdout.flush()

        while True:
            chunk = os.read(fd, 1)
            if not chunk:
                return 1
            if chunk != b"\x03":
                continue

            count += 1
            if count < args.required_interrupts:
                if count == 1:
                    sys.stdout.write("FIXTURE_INTERRUPTED What should the agent do instead?\r\n")
                else:
                    sys.stdout.write("FIXTURE_PRESS_CTRL_C_AGAIN\r\n")
                sys.stdout.flush()
                continue

            sys.stdout.write("Resume this session with:\r\n")
            sys.stdout.write(f"{args.label} --resume fixture-{args.required_interrupts}\r\n")
            sys.stdout.flush()
            return 0
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    raise SystemExit(main())
"""


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def _bundle_id(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.exists():
        raise RuntimeError(f"Missing Info.plist at {info_path}")
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    bundle_id = str(info.get("CFBundleIdentifier", "")).strip()
    if not bundle_id:
        raise RuntimeError("Missing CFBundleIdentifier")
    return bundle_id


def _snapshot_path(bundle_id: str) -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe_bundle}.json"


def _sanitize_tag_slug(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", (raw or "").strip().lower())
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned or "agent"


def _socket_candidates(app_path: Path, preferred: Path) -> list[Path]:
    candidates = [preferred]
    app_name = app_path.stem
    prefix = "cmux DEV "
    if app_name.startswith(prefix):
        tag = app_name[len(prefix):]
        slug = _sanitize_tag_slug(tag)
        candidates.append(Path(f"/tmp/cmux-debug-{slug}.sock"))
    deduped: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(candidate)
    return deduped


def _socket_reachable(socket_path: Path) -> bool:
    if not socket_path.exists():
        return False
    try:
        client = cmux(socket_path=str(socket_path))
        client.connect()
        return bool(client.ping())
    except Exception:
        return False


def _wait_for_socket(candidates: list[Path], timeout: float = 20.0) -> Path:
    deadline = time.time() + timeout
    while time.time() < deadline:
        for candidate in candidates:
            if _socket_reachable(candidate):
                return candidate
        time.sleep(0.2)
    joined = ", ".join(str(path) for path in candidates)
    raise RuntimeError(f"Socket did not become reachable: {joined}")


def _wait_for_socket_closed(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket still reachable after quit: {socket_path}")


def _kill_existing(app_path: Path) -> None:
    exe = app_path / "Contents" / "MacOS" / "cmux DEV"
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    time.sleep(1.0)


def _launch(app_path: Path, preferred_socket_path: Path) -> Path:
    preferred_socket_path.unlink(missing_ok=True)
    exe = app_path / "Contents" / "MacOS" / "cmux DEV"
    _must(exe.exists(), f"Missing app binary at {exe}")

    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(preferred_socket_path)
    env["CMUX_SOCKET_MODE"] = "allowAll"
    env["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
    subprocess.Popen(
        [str(exe)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    resolved_socket_path = _wait_for_socket(_socket_candidates(app_path, preferred_socket_path))
    time.sleep(1.5)
    return resolved_socket_path


def _quit(bundle_id: str, socket_path: Path) -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True,
        text=True,
        check=True,
    )
    _wait_for_socket_closed(socket_path)
    socket_path.unlink(missing_ok=True)
    time.sleep(0.8)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    _must(client.ping(), "ping failed")
    return client


def _read_scrollback(client: cmux, surface_id: str, lines: int = 320) -> str:
    result = client._call(
        "surface.read_text",
        {"surface_id": surface_id, "scrollback": True, "lines": lines},
    ) or {}
    if "text" in result:
        return str(result.get("text") or "")
    raw = base64.b64decode(str(result.get("base64") or ""))
    return raw.decode("utf-8", errors="replace")


def _current_surface_id(client: cmux, workspace_id: str) -> str:
    surfaces = client.list_surfaces(workspace_id)
    _must(bool(surfaces), f"workspace {workspace_id} has no surfaces")
    return str(surfaces[0][1])


def _wait_for_marker(client: cmux, workspace_id: str, surface_id: str, marker: str, timeout: float = 8.0) -> str:
    client.select_workspace(workspace_id)
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = _read_scrollback(client, surface_id)
        if marker in last:
            return last
        time.sleep(0.25)
    raise RuntimeError(f"Marker {marker!r} missing from scrollback. Tail:\n{last[-1200:]}")


def _session_json_contains(snapshot: Path, marker: str) -> bool:
    if not snapshot.exists():
        return False
    return marker in snapshot.read_text(encoding="utf-8", errors="replace")


def _restored_scrollback_contains(client: cmux, marker: str, timeout: float = 10.0) -> str | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        for _index, workspace_id, _title, _selected in client.list_workspaces():
            client.select_workspace(workspace_id)
            time.sleep(0.2)
            for _surface_index, surface_id, _focused in client.list_surfaces(workspace_id):
                text = _read_scrollback(client, surface_id)
                if marker in text:
                    return text
        time.sleep(0.3)
    return None


def _fixture_script_path() -> Path:
    path = Path("/tmp") / f"cmux-quit-resume-fixture-{os.getpid()}.py"
    path.write_text(FIXTURE_SOURCE, encoding="utf-8")
    path.chmod(0o755)
    return path


def _run_case(app_path: Path, bundle_id: str, snapshot: Path, fixture_path: Path, label: str, required_interrupts: int) -> None:
    socket_path = Path(f"/tmp/cmux-quit-restore-{label}-{os.getpid()}.sock")
    expected = f"{label} --resume fixture-{required_interrupts}"
    ready_marker = f"FIXTURE_READY {label}"

    snapshot.unlink(missing_ok=True)
    _kill_existing(app_path)

    try:
        socket_path = _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surface_id = _current_surface_id(client, workspace_id)
            command = (
                f"python3 {fixture_path} "
                f"--required-interrupts {required_interrupts} "
                f"--label {label}"
            )
            client.send_surface(surface_id, command + "\n")
            _wait_for_marker(client, workspace_id, surface_id, ready_marker)
        finally:
            client.close()

        _quit(bundle_id, socket_path)
        _must(snapshot.exists(), f"snapshot missing after quit for {label}")
        _must(
            _session_json_contains(snapshot, expected),
            f"snapshot missing resume marker for {label}",
        )

        socket_path = _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            restored = _restored_scrollback_contains(client, expected, timeout=12.0)
            _must(restored is not None, f"restored scrollback missing resume marker for {label}")
        finally:
            client.close()

        _quit(bundle_id, socket_path)
    finally:
        _kill_existing(app_path)
        socket_path.unlink(missing_ok=True)
        snapshot.unlink(missing_ok=True)


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str:
        print("SKIP: set CMUX_APP_PATH to a built cmux DEV .app path")
        return 0

    app_path = Path(app_path_str)
    if not app_path.exists():
        print(f"SKIP: CMUX_APP_PATH does not exist: {app_path}")
        return 0

    bundle_id = _bundle_id(app_path)
    snapshot = _snapshot_path(bundle_id)
    fixture_path = _fixture_script_path()
    failures: list[str] = []

    cases = [
        ("fixture-codex", 1),
        ("fixture-claude", 3),
    ]

    try:
        for label, required_interrupts in cases:
            try:
                _run_case(app_path, bundle_id, snapshot, fixture_path, label, required_interrupts)
                print(f"PASS: {label}")
            except Exception as exc:
                failures.append(f"{label}: {exc}")
    finally:
        fixture_path.unlink(missing_ok=True)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: quit/session restore captures raw-control resume hints")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
