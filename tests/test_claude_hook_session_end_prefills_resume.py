#!/usr/bin/env python3
"""
Regression test: claude-hook session-end should prefill a resume command into
the mapped terminal surface.

This exercises the real CLI hook path against a fake cmux socket server and
verifies observable runtime behavior:
1) session-start stores the workspace/surface mapping for the session
2) session-end clears state and sends surface.send_text with the resume command
3) the resume prefill still happens when CMUX_CLAUDE_PID points at a live PID,
   which matches the real SessionEnd hook environment
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


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


class FakeHookServerState:
    def __init__(self, workspace_id: str, surface_id: str):
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.lock = threading.Lock()
        self.v1_commands: list[str] = []
        self.v2_requests: list[dict] = []

    def handle(self, method: str, params: dict) -> dict:
        with self.lock:
            self.v2_requests.append({"method": method, "params": dict(params)})

        if method == "surface.list":
            requested_workspace = str(params.get("workspace_id", ""))
            if requested_workspace != self.workspace_id:
                raise RuntimeError(
                    f"surface.list targeted unexpected workspace {requested_workspace!r}"
                )
            return {
                "surfaces": [
                    {
                        "id": self.surface_id,
                        "index": 0,
                        "focused": True,
                    }
                ]
            }

        if method == "surface.send_text":
            return {"ok": True}

        raise RuntimeError(f"Unsupported fake cmux method: {method}")


class FakeHookUnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, socket_path: str, state: FakeHookServerState) -> None:
        self.state = state
        super().__init__(socket_path, FakeHookHandler)


class FakeHookHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return
            decoded = line.decode("utf-8").strip()
            if not decoded:
                continue

            if decoded.startswith("{"):
                request = json.loads(decoded)
                response = {
                    "ok": True,
                    "result": self.server.state.handle(
                        request["method"],
                        request.get("params", {}),
                    ),
                    "id": request.get("id"),
                }
                self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
                self.wfile.flush()
                continue

            with self.server.state.lock:
                self.server.state.v1_commands.append(decoded)
            self.wfile.write(b"OK\n")
            self.wfile.flush()


def run_claude_hook(
    *,
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    with tempfile.TemporaryDirectory(prefix="cmux-claude-session-end-") as td:
        root = Path(td)
        socket_path = str(root / "cmux.sock")
        state_path = root / "claude-hook-state.json"
        lock_path = Path(str(state_path) + ".lock")
        workspace_id = str(uuid.uuid4())
        surface_id = str(uuid.uuid4())
        session_id = f"sess-{uuid.uuid4().hex}"

        state = FakeHookServerState(workspace_id=workspace_id, surface_id=surface_id)
        server = FakeHookUnixServer(socket_path, state)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()

        try:
            env = os.environ.copy()
            env["CMUX_SOCKET_PATH"] = socket_path
            env["CMUX_WORKSPACE_ID"] = workspace_id
            env["CMUX_SURFACE_ID"] = surface_id
            env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
            env["CMUX_CLI_SENTRY_DISABLED"] = "1"
            env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

            start_proc = run_claude_hook(
                cli_path=cli_path,
                socket_path=socket_path,
                subcommand="session-start",
                payload={"session_id": session_id},
                env=env,
            )
            if start_proc.returncode != 0:
                return fail(
                    "claude-hook session-start failed:\n"
                    f"stdout={start_proc.stdout}\nstderr={start_proc.stderr}"
                )
            if start_proc.stdout.strip() != "OK":
                return fail(f"Expected session-start to print OK, got {start_proc.stdout!r}")
            if not state_path.exists():
                return fail(f"Expected session-start to create state file at {state_path}")

            helper = subprocess.Popen(["/bin/sh", "-c", "sleep 10"])
            try:
                end_env = dict(env)
                end_env["CMUX_CLAUDE_PID"] = str(helper.pid)
                end_proc = run_claude_hook(
                    cli_path=cli_path,
                    socket_path=socket_path,
                    subcommand="session-end",
                    payload={
                        "session_id": session_id,
                        "reason": "prompt_input_exit",
                    },
                    env=end_env,
                )
            finally:
                helper.terminate()
                try:
                    helper.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    helper.kill()
                    helper.wait(timeout=2)

            if end_proc.returncode != 0:
                return fail(
                    "claude-hook session-end failed:\n"
                    f"stdout={end_proc.stdout}\nstderr={end_proc.stderr}"
                )
            if end_proc.stdout.strip() != "OK":
                return fail(f"Expected session-end to print OK, got {end_proc.stdout!r}")

            deadline = time.time() + 2.0
            send_text_request: dict | None = None
            while time.time() < deadline and send_text_request is None:
                with state.lock:
                    for request in state.v2_requests:
                        if request.get("method") == "surface.send_text":
                            send_text_request = request
                            break
                if send_text_request is None:
                    time.sleep(0.05)

            if send_text_request is None:
                return fail(
                    "Expected session-end to prefill a resume command via surface.send_text"
                )

            params = send_text_request.get("params", {})
            expected_text = f"claude --resume {session_id}"
            if params.get("text") != expected_text:
                return fail(
                    f"Expected resume text {expected_text!r}, got {params.get('text')!r}"
                )
            if params.get("workspace_id") != workspace_id:
                return fail(
                    "Expected resume prefill to target the mapped workspace, "
                    f"got {params.get('workspace_id')!r}"
                )
            if params.get("surface_id") != surface_id:
                return fail(
                    "Expected resume prefill to target the mapped surface, "
                    f"got {params.get('surface_id')!r}"
                )

            with state_path.open("r", encoding="utf-8") as f:
                post_end_state = json.load(f)
            if session_id in (post_end_state.get("sessions") or {}):
                return fail("Expected session mapping to be consumed on session-end")

            print("PASS: claude-hook session-end prefills mapped resume command")
            return 0
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
            try:
                if state_path.exists():
                    state_path.unlink()
                if lock_path.exists():
                    lock_path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
