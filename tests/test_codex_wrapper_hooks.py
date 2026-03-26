#!/usr/bin/env python3
"""
Regression tests for Resources/bin/codex wrapper hook injection.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def run_wrapper(*, socket_state: str, argv: list[str]) -> tuple[int, list[str], list[str], str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "codex"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_pid_log = tmp / "real-pid.log"
        cmux_log = tmp / "cmux.log"
        socket_path = str(tmp / "cmux.sock")
        fake_real_codex = real_dir / "codex"

        make_executable(
            fake_real_codex,
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
printf '%s\\n' "${CMUX_CODEX_PID-}" > "$FAKE_REAL_PID_LOG"
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s timeout=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  if [[ "${FAKE_CMUX_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
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
        env["CMUX_CODEX_REAL_BIN"] = str(fake_real_codex)
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_PID_LOG"] = str(real_pid_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"

        try:
            proc = subprocess.run(
                ["codex", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        pid_value = real_pid_log.read_text(encoding="utf-8").strip() if real_pid_log.exists() else ""
        return proc.returncode, read_lines(real_args_log), read_lines(cmux_log), proc.stderr.strip(), pid_value


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_supported_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, pid_value = run_wrapper(socket_state="live", argv=["chat"])
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect("--enable" in real_argv, f"live socket: missing --enable in args: {real_argv}", failures)
    expect("codex_hooks" in real_argv, f"live socket: missing codex_hooks in args: {real_argv}", failures)
    expect(
        "session_start=cmux codex-hook session-start" in real_argv,
        f"live socket: missing session_start hook in args: {real_argv}",
        failures,
    )
    expect(
        "stop=cmux codex-hook stop" in real_argv,
        f"live socket: missing stop hook in args: {real_argv}",
        failures,
    )
    expect(real_argv[-1] == "chat", f"live socket: expected original arg to pass through, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"live socket: expected cmux ping, got {cmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in cmux_log),
        f"live socket: expected bounded ping timeout, got {cmux_log}",
        failures,
    )
    expect(pid_value.isdigit(), f"live socket: expected CMUX_CODEX_PID env, got {pid_value!r}", failures)


def test_review_subcommand_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _ = run_wrapper(socket_state="live", argv=["review", "--help"])
    expect(code == 0, f"review passthrough: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["review", "--help"], f"review passthrough: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"review passthrough: expected cmux ping, got {cmux_log}", failures)


def test_missing_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _ = run_wrapper(socket_state="missing", argv=["chat"])
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["chat"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(cmux_log == [], f"missing socket: expected no cmux calls, got {cmux_log}", failures)


def test_stale_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _ = run_wrapper(socket_state="stale", argv=["chat"])
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["chat"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"stale socket: expected cmux ping probe, got {cmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in cmux_log),
        f"stale socket: expected bounded ping timeout, got {cmux_log}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_supported_hooks(failures)
    test_review_subcommand_skips_hook_injection(failures)
    test_missing_socket_skips_hook_injection(failures)
    test_stale_socket_skips_hook_injection(failures)

    if failures:
        print("FAIL: codex wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: codex wrapper hooks handle missing/stale sockets and inject only supported hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
