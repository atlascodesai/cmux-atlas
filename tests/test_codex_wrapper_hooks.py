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


def write_fake_codex(path: Path, name: str) -> None:
    make_executable(
        path,
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "{name}" > "$FAKE_REAL_NAME_LOG"
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
printf '%s\\n' "${{CMUX_CODEX_PID-}}" > "$FAKE_REAL_PID_LOG"
""",
    )


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    resolution_mode: str,
    install_config_hooks: bool = False,
) -> tuple[int, list[str], list[str], str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        ovm_cmd_dir = tmp / "ovm-cmd-bin"
        real_dir = tmp / "real-bin"
        ovm_dir = tmp / "ovm-bin"
        path_dir = tmp / "path-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        ovm_cmd_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)
        ovm_dir.mkdir(parents=True, exist_ok=True)
        path_dir.mkdir(parents=True, exist_ok=True)
        codex_home = tmp / "codex-home"
        codex_home.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "codex"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_pid_log = tmp / "real-pid.log"
        real_name_log = tmp / "real-name.log"
        cmux_log = tmp / "cmux.log"
        socket_path = str(tmp / "cmux.sock")
        override_codex = real_dir / "codex"
        ovm_codex = ovm_dir / "codex"
        path_codex = path_dir / "codex"

        write_fake_codex(override_codex, "override")
        write_fake_codex(ovm_codex, "ovm")
        write_fake_codex(path_codex, "path")

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

        make_executable(
            ovm_cmd_dir / "ovm",
            f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == "which" && "${{2:-}}" == "codex" ]]; then
  printf '%s\\n' "{ovm_codex}"
  exit 0
fi
exit 1
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        if resolution_mode == "ovm":
            path_parts = [str(wrapper_dir), str(ovm_cmd_dir), str(path_dir)]
        elif resolution_mode in {"path", "override"}:
            path_parts = [str(path_dir), str(wrapper_dir)]
        else:
            raise ValueError(f"Unknown resolution_mode: {resolution_mode}")

        path_parts.extend(["/usr/bin", "/bin"])
        env["PATH"] = ":".join(path_parts)
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_PID_LOG"] = str(real_pid_log)
        env["FAKE_REAL_NAME_LOG"] = str(real_name_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        env["CODEX_HOME"] = str(codex_home)
        if resolution_mode == "override":
            env["CMUX_CODEX_REAL_BIN"] = str(override_codex)
        else:
            env.pop("CMUX_CODEX_REAL_BIN", None)
        if install_config_hooks:
            (codex_home / "hooks.json").write_text(
                '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cmux codex-hook session-start","timeout":5000}]}]}}',
                encoding="utf-8",
            )

        try:
            proc = subprocess.run(
                [str(wrapper), *argv],
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
        selected_name = real_name_log.read_text(encoding="utf-8").strip() if real_name_log.exists() else ""
        return proc.returncode, read_lines(real_args_log), read_lines(cmux_log), proc.stderr.strip(), pid_value, selected_name


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def expect_selected_binary(
    *,
    failures: list[str],
    resolution_mode: str,
    expected_name: str,
) -> tuple[list[str], list[str], str]:
    code, real_argv, cmux_log, stderr, pid_value, selected_name = run_wrapper(
        socket_state="live",
        argv=["chat"],
        resolution_mode=resolution_mode,
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect(
        selected_name == expected_name,
        f"{resolution_mode}: expected selected binary {expected_name!r}, got {selected_name!r}",
        failures,
    )
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
    expect(
        "session_end=cmux codex-hook session-end" in real_argv,
        f"live socket: missing session_end hook in args: {real_argv}",
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
    return real_argv, cmux_log, stderr


def test_override_resolution_injects_supported_hooks(failures: list[str]) -> None:
    expect_selected_binary(failures=failures, resolution_mode="override", expected_name="override")


def test_ovm_resolution_injects_supported_hooks(failures: list[str]) -> None:
    expect_selected_binary(failures=failures, resolution_mode="ovm", expected_name="ovm")


def test_path_resolution_injects_supported_hooks(failures: list[str]) -> None:
    expect_selected_binary(failures=failures, resolution_mode="path", expected_name="path")


def test_config_installed_hooks_skip_wrapper_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _, selected_name = run_wrapper(
        socket_state="live",
        argv=["chat"],
        resolution_mode="ovm",
        install_config_hooks=True,
    )
    expect(code == 0, f"config-installed hooks: wrapper exited {code}: {stderr}", failures)
    expect(selected_name == "ovm", f"config-installed hooks: expected ovm selection, got {selected_name!r}", failures)
    expect(real_argv == ["chat"], f"config-installed hooks: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"config-installed hooks: expected cmux ping, got {cmux_log}", failures)


def test_review_subcommand_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _, selected_name = run_wrapper(
        socket_state="live",
        argv=["review", "--help"],
        resolution_mode="ovm",
    )
    expect(code == 0, f"review passthrough: wrapper exited {code}: {stderr}", failures)
    expect(selected_name == "ovm", f"review passthrough: expected ovm selection, got {selected_name!r}", failures)
    expect(real_argv == ["review", "--help"], f"review passthrough: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"review passthrough: expected cmux ping, got {cmux_log}", failures)


def test_missing_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _, selected_name = run_wrapper(
        socket_state="missing",
        argv=["chat"],
        resolution_mode="ovm",
    )
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(selected_name == "ovm", f"missing socket: expected ovm selection, got {selected_name!r}", failures)
    expect(real_argv == ["chat"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(cmux_log == [], f"missing socket: expected no cmux calls, got {cmux_log}", failures)


def test_stale_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, _, selected_name = run_wrapper(
        socket_state="stale",
        argv=["chat"],
        resolution_mode="ovm",
    )
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(selected_name == "ovm", f"stale socket: expected ovm selection, got {selected_name!r}", failures)
    expect(real_argv == ["chat"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"stale socket: expected cmux ping probe, got {cmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in cmux_log),
        f"stale socket: expected bounded ping timeout, got {cmux_log}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    test_override_resolution_injects_supported_hooks(failures)
    test_ovm_resolution_injects_supported_hooks(failures)
    test_path_resolution_injects_supported_hooks(failures)
    test_config_installed_hooks_skip_wrapper_injection(failures)
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
