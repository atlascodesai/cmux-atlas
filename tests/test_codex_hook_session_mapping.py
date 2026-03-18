#!/usr/bin/env python3
"""
E2E regression test for Codex hook session mapping.

Validates:
1) session-start records session_id -> workspace/surface mapping on disk
2) stop updates the mapped session state without failing
3) hook responses stay valid JSON for Codex's silent hook contract
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))

    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run_codex_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict,
    env: dict[str, str],
) -> dict:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "codex-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux codex-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"cmux codex-hook {subcommand} returned invalid JSON: {proc.stdout!r}") from exc


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    state_path = Path(tempfile.gettempdir()) / f"cmux_codex_hook_state_{os.getpid()}.json"
    lock_path = Path(str(state_path) + ".lock")
    try:
        if state_path.exists():
            state_path.unlink()
        if lock_path.exists():
            lock_path.unlink()
    except OSError:
        pass

    project_dir = Path(tempfile.gettempdir()) / f"cmux_codex_map_project_{os.getpid()}"
    project_dir.mkdir(parents=True, exist_ok=True)
    session_id = f"codex-{uuid.uuid4().hex}"
    first_transcript = str(project_dir / "first.jsonl")
    second_transcript = str(project_dir / "second.jsonl")

    try:
        with cmux() as client:
            client.set_app_focus(False)

            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces()
            if not surfaces:
                return fail("Expected at least one surface in new workspace")

            focused = next((s for s in surfaces if s[2]), surfaces[0])
            surface_id = focused[1]

            hook_env = os.environ.copy()
            hook_env["CMUX_SOCKET_PATH"] = client.socket_path
            hook_env["CMUX_WORKSPACE_ID"] = workspace_id
            hook_env["CMUX_SURFACE_ID"] = surface_id
            hook_env["CMUX_CODEX_HOOK_STATE_PATH"] = str(state_path)

            response = run_codex_hook(
                cli_path,
                client.socket_path,
                "session-start",
                {
                    "session_id": session_id,
                    "cwd": str(project_dir),
                    "transcript_path": first_transcript,
                    "permission_mode": "default",
                    "source": "startup",
                },
                hook_env,
            )
            if response != {"continue": True}:
                return fail(f"Expected silent success JSON from session-start, got {response!r}")

            if not state_path.exists():
                return fail(f"Expected state file at {state_path}")

            with state_path.open("r", encoding="utf-8") as f:
                state_data = json.load(f)
            session_row = (state_data.get("sessions") or {}).get(session_id)
            if not session_row:
                return fail("Expected mapped Codex session row after session-start")
            if session_row.get("workspaceId") != workspace_id:
                return fail("Mapped workspaceId did not match active workspace")
            if session_row.get("surfaceId") != surface_id:
                return fail("Mapped surfaceId did not match active surface")
            if session_row.get("transcriptPath") != first_transcript:
                return fail("Mapped transcriptPath did not match session-start payload")
            if session_row.get("permissionMode") != "default":
                return fail("Mapped permissionMode did not match session-start payload")
            if session_row.get("source") != "startup":
                return fail("Mapped source did not match session-start payload")

            stop_response = run_codex_hook(
                cli_path,
                client.socket_path,
                "stop",
                {
                    "session_id": session_id,
                    "cwd": str(project_dir),
                    "transcript_path": second_transcript,
                    "permission_mode": "danger-full-access",
                    "source": "resume",
                },
                hook_env,
            )
            if stop_response != {"continue": True}:
                return fail(f"Expected silent success JSON from stop, got {stop_response!r}")

            with state_path.open("r", encoding="utf-8") as f:
                post_stop_state = json.load(f)
            session_row = (post_stop_state.get("sessions") or {}).get(session_id)
            if not session_row:
                return fail("Expected Codex session row to remain after stop")
            if session_row.get("transcriptPath") != second_transcript:
                return fail("Expected stop to refresh transcriptPath")
            if session_row.get("permissionMode") != "danger-full-access":
                return fail("Expected stop to refresh permissionMode")
            if session_row.get("source") != "resume":
                return fail("Expected stop to refresh source")

            empty_stop_response = run_codex_hook(
                cli_path,
                client.socket_path,
                "stop",
                {},
                hook_env,
            )
            if empty_stop_response != {"continue": True}:
                return fail(f"Expected silent success JSON from stop without session_id, got {empty_stop_response!r}")

            print("PASS: Codex hook session mapping and silent hook JSON responses")
            return 0

    except (cmuxError, RuntimeError) as exc:
        return fail(str(exc))
    finally:
        try:
            if state_path.exists():
                state_path.unlink()
            if lock_path.exists():
                lock_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
