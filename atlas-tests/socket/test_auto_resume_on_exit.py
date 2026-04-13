#!/usr/bin/env python3
"""
Atlas regression tests for auto-resume on session exit.

Tests that the session-end hook prefills `claude --resume <id>` into the
terminal when the session ends normally (reason != clear/resume) and the
setting is enabled.

Requires a built cmux CLI binary (set CMUX_CLI_BIN or use --tag with test-atlas.sh).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

# Reuse fake server infrastructure from the main test suite
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))

try:
    from test_claude_hook_session_end_prefills_resume import (
        FakeHookUnixServer,
        FakeHookServerState,
    )
except ImportError:
    FakeHookUnixServer = None
    FakeHookServerState = None


def resolve_cli() -> str | None:
    for env_key in ("CMUX_CLI_BIN", "CMUX_CLI"):
        path = os.environ.get(env_key, "")
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    marker = Path("/tmp/cmux-last-cli-path")
    if marker.is_file():
        path = marker.read_text().strip()
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
SURFACE_ID = "22222222-2222-2222-2222-222222222222"


@unittest.skipIf(FakeHookUnixServer is None, "Upstream test fixtures not importable")
class TestAutoResumeOnExit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = resolve_cli()
        if cls.cli is None:
            raise unittest.SkipTest("No cmux CLI binary found (set CMUX_CLI_BIN)")

    def _run_hook(self, socket_path: str, state_path: str, state: FakeHookServerState, subcommand: str, payload: dict, extra_env: dict | None = None):
        """Run a hook against an already-running fake server.

        The caller manages the server lifecycle and temp directory so that
        state (session mapping file) persists across multiple hook invocations.
        """
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_WORKSPACE_ID"] = WORKSPACE_ID
        env["CMUX_SURFACE_ID"] = SURFACE_ID
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = state_path
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        if extra_env:
            env.update(extra_env)

        return subprocess.run(
            [self.cli, "--socket", socket_path, "claude-hook", subcommand],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=10,
            check=False,
        )

    def test_session_end_prefills_resume_on_normal_exit(self):
        """Normal session-end (no reason field) prefills the resume command."""
        with tempfile.TemporaryDirectory(prefix="atlas-resume-test-") as td:
            socket_path = os.path.join(td, "cmux.sock")
            state_path = os.path.join(td, "claude-hook-sessions.json")
            state = FakeHookServerState(workspace_id=WORKSPACE_ID, surface_id=SURFACE_ID)

            server = FakeHookUnixServer(socket_path, state)
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()

            try:
                session_id = "test-resume-abc-123"

                # Register the session — state file persists in td
                proc = self._run_hook(socket_path, state_path, state, "session-start", {"session_id": session_id})
                self.assertEqual(proc.returncode, 0, f"session-start failed: {proc.stderr}")

                # Trigger session-end with no reason (normal exit)
                proc = self._run_hook(socket_path, state_path, state, "session-end", {"session_id": session_id})
                self.assertEqual(proc.returncode, 0, f"session-end failed: {proc.stderr}")

                # Check that surface.send_text was called with resume command
                with state.lock:
                    resume_calls = [
                        r for r in state.v2_requests
                        if r.get("method") == "surface.send_text"
                        and "resume" in json.dumps(r.get("params", {}))
                    ]
                self.assertTrue(
                    len(resume_calls) > 0,
                    f"Expected surface.send_text with resume command, got: {[r['method'] for r in state.v2_requests]}"
                )
            finally:
                server.shutdown()

    def test_session_end_skips_resume_on_clear_reason(self):
        """Session-end with reason=clear (from /clear) should NOT prefill resume."""
        with tempfile.TemporaryDirectory(prefix="atlas-resume-test-") as td:
            socket_path = os.path.join(td, "cmux.sock")
            state_path = os.path.join(td, "claude-hook-sessions.json")
            state = FakeHookServerState(workspace_id=WORKSPACE_ID, surface_id=SURFACE_ID)

            server = FakeHookUnixServer(socket_path, state)
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()

            try:
                session_id = "test-no-resume-clear-456"

                proc = self._run_hook(socket_path, state_path, state, "session-start", {"session_id": session_id})
                self.assertEqual(proc.returncode, 0, f"session-start failed: {proc.stderr}")

                # Trigger session-end with reason=clear
                proc = self._run_hook(socket_path, state_path, state, "session-end", {"session_id": session_id, "reason": "clear"})
                self.assertEqual(proc.returncode, 0, f"session-end failed: {proc.stderr}")

                with state.lock:
                    resume_calls = [
                        r for r in state.v2_requests
                        if r.get("method") == "surface.send_text"
                        and "resume" in json.dumps(r.get("params", {}))
                    ]
                self.assertEqual(
                    len(resume_calls), 0,
                    f"Resume should NOT be sent for reason=clear, got: {resume_calls}"
                )
            finally:
                server.shutdown()


if __name__ == "__main__":
    unittest.main()
