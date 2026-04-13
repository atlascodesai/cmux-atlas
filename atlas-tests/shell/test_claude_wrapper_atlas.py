#!/usr/bin/env python3
"""
Atlas-specific regression tests for Resources/bin/claude wrapper.

Covers features added in the atlas fork: --yolo alias, resume flag detection,
CLAUDECODE unset, session ID generation.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def parse_settings_arg(argv: list[str]) -> dict:
    if "--settings" not in argv:
        return {}
    index = argv.index("--settings")
    if index + 1 >= len(argv):
        return {}
    return json.loads(argv[index + 1])


def run_wrapper(
    *,
    argv: list[str],
    socket_state: str = "live",
) -> tuple[int, list[str], str, str]:
    """Run the claude wrapper in an isolated environment.

    Returns (exit_code, real_claude_args, claudecode_env_value, stderr).
    """
    with tempfile.TemporaryDirectory(prefix="cmux-claude-atlas-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_claudecode_log = tmp / "real-claudecode.log"
        cmux_log = tmp / "cmux.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "claude",
            f"""#!/usr/bin/env bash
set -euo pipefail
: > "{real_args_log}"
printf '%s\\n' "${{CLAUDECODE-__UNSET__}}" > "{real_claudecode_log}"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "{real_args_log}"
done
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{cmux_log}"
if [[ "${{1:-}}" == "--socket" ]]; then shift 2; fi
if [[ "${{1:-}}" == "ping" ]]; then
  [[ "${{FAKE_CMUX_PING_OK:-0}}" == "1" ]] && exit 0
  exit 1
fi
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        env["CLAUDECODE"] = "nested-session-sentinel"

        try:
            proc = subprocess.run(
                ["claude", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        claudecode_lines = read_lines(real_claudecode_log)
        claudecode_value = claudecode_lines[0] if claudecode_lines else ""
        return (
            proc.returncode,
            read_lines(real_args_log),
            claudecode_value,
            proc.stderr.strip(),
        )


class TestClaudeWrapperAtlas(unittest.TestCase):
    def test_yolo_maps_to_dangerously_skip_permissions(self):
        """--yolo is normalized to --dangerously-skip-permissions."""
        rc, args, _, stderr = run_wrapper(argv=["--yolo"])
        self.assertEqual(rc, 0, f"Wrapper failed: {stderr}")
        self.assertIn("--dangerously-skip-permissions", args)
        self.assertNotIn("--yolo", args)

    def test_resume_flag_skips_session_id(self):
        """--resume <id> suppresses --session-id injection."""
        rc, args, _, stderr = run_wrapper(argv=["--resume", "abc-123"])
        self.assertEqual(rc, 0, f"Wrapper failed: {stderr}")
        self.assertIn("--resume", args)
        self.assertIn("abc-123", args)
        self.assertNotIn("--session-id", args)

    def test_continue_flag_skips_session_id(self):
        """--continue and -c suppress --session-id injection."""
        for flag in ["--continue", "-c"]:
            rc, args, _, stderr = run_wrapper(argv=[flag])
            self.assertEqual(rc, 0, f"Wrapper failed for {flag}: {stderr}")
            self.assertNotIn("--session-id", args, f"--session-id injected despite {flag}")

    def test_unsets_claudecode_env(self):
        """CLAUDECODE env var is unset to prevent nested session detection."""
        rc, args, claudecode_value, stderr = run_wrapper(argv=[])
        self.assertEqual(rc, 0, f"Wrapper failed: {stderr}")
        self.assertEqual(claudecode_value, "__UNSET__", "CLAUDECODE was not unset")

    def test_session_id_generated_when_not_resuming(self):
        """A UUID --session-id is injected for fresh sessions."""
        rc, args, _, stderr = run_wrapper(argv=[])
        self.assertEqual(rc, 0, f"Wrapper failed: {stderr}")
        self.assertIn("--session-id", args)
        sid_index = args.index("--session-id")
        self.assertTrue(sid_index + 1 < len(args), "--session-id has no value")
        session_id = args[sid_index + 1]
        # UUID format: 8-4-4-4-12 hex chars
        parts = session_id.split("-")
        self.assertEqual(len(parts), 5, f"Session ID not UUID format: {session_id}")


if __name__ == "__main__":
    unittest.main()
