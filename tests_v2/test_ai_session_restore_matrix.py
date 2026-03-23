#!/usr/bin/env python3
"""VM-gated integration test for live AI session detection and restore.

This test is intentionally skipped unless the VM has real Claude Code and Codex
CLIs installed and the operator opts in via environment variables.

Coverage target:
  - launch real Claude/Codex sessions in split panels and separate workspaces
  - confirm live cached detection while the processes are running
  - quit cmux cleanly so the session snapshot is persisted
  - relaunch cmux and confirm restored AI sessions are surfaced back to the UI model
"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
RUN_ENABLED = os.environ.get("CMUX_RUN_AI_CLI_TESTS", "").strip() == "1"
CLAUDE_COMMAND = os.environ.get("CMUX_TEST_CLAUDE_CMD", "claude").strip()
CODEX_COMMAND = os.environ.get("CMUX_TEST_CODEX_CMD", "codex").strip()
APP_BUNDLE = os.environ.get("CMUX_TEST_APP_BUNDLE", "").strip()
APP_BINARY = os.environ.get("CMUX_TEST_APP_BINARY", "").strip()
RUN_TAG = os.environ.get("CMUX_TEST_RUN_TAG", "tests-v2").strip() or "tests-v2"
DETECTION_TIMEOUT_S = float(os.environ.get("CMUX_TEST_AI_TIMEOUT", "45"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _maybe_skip() -> bool:
    if not RUN_ENABLED:
        print("SKIP: set CMUX_RUN_AI_CLI_TESTS=1 after installing Claude Code and Codex on the VM")
        return True

    required = [
        ("CMUX_TEST_CLAUDE_CMD", CLAUDE_COMMAND),
        ("CMUX_TEST_CODEX_CMD", CODEX_COMMAND),
    ]
    for label, command in required:
        argv = shlex.split(command)
        if not argv:
            print(f"SKIP: {label} is empty")
            return True
        if shutil.which(argv[0]) is None:
            print(f"SKIP: executable not found for {label}: {argv[0]}")
            return True

    if not APP_BUNDLE or not Path(APP_BUNDLE).is_dir():
        raise cmuxError("Missing CMUX_TEST_APP_BUNDLE; run via scripts/run-tests-v2.sh on the VM")
    if not APP_BINARY or not Path(APP_BINARY).is_file():
        raise cmuxError("Missing CMUX_TEST_APP_BINARY; run via scripts/run-tests-v2.sh on the VM")
    return False


def _create_git_repo(root: Path, name: str) -> Path:
    repo = root / name
    repo.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "init"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "config", "user.name", "cmux-test"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "config", "user.email", "cmux-test@example.com"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    (repo / "README.md").write_text(f"{name}\n", encoding="utf-8")
    subprocess.run(
        ["git", "add", "README.md"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "-c", "commit.gpgsign=false", "commit", "-m", "init"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return repo


def _terminal_surface_id(c: cmux, workspace_id: str) -> str:
    surfaces = c.list_surfaces(workspace_id)
    _must(bool(surfaces), f"Expected at least one surface in workspace {workspace_id}")
    return next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])


def _launch_agent(c: cmux, workspace_id: str, surface_id: str, directory: Path, command: str) -> None:
    c.select_workspace(workspace_id)
    c.focus_surface(surface_id)
    c.activate_app()
    time.sleep(0.25)
    c.simulate_type(f"cd {shlex.quote(str(directory))}\n")
    time.sleep(0.35)
    c.simulate_type(command + "\n")
    time.sleep(0.8)


def _flatten_panels(payload: dict) -> list[dict]:
    rows: list[dict] = []
    for workspace in payload.get("workspaces") or []:
        for panel in workspace.get("panels") or []:
            merged = dict(panel)
            merged["workspace_id"] = workspace.get("workspace_id")
            merged["workspace_ref"] = workspace.get("workspace_ref")
            merged["workspace_title"] = workspace.get("title")
            merged["workspace_selected"] = workspace.get("selected")
            rows.append(merged)
    return rows


def _wait_for_session_rows(
    c: cmux,
    *,
    session_key: str,
    expectations: list[dict],
    refresh: bool,
    timeout_s: float,
) -> list[dict]:
    deadline = time.time() + timeout_s
    last_rows: list[dict] = []

    while time.time() < deadline:
        payload = c.ai_sessions(refresh=refresh)
        rows = _flatten_panels(payload)
        last_rows = rows

        matched = 0
        for expectation in expectations:
            expected_dir = str(expectation["directory"])
            expected_agent = expectation["agent_type"]
            for row in rows:
                if str(row.get("directory") or "") != expected_dir:
                    continue
                session = row.get(session_key) or {}
                if not isinstance(session, dict):
                    continue
                if str(session.get("agent_type") or "") != expected_agent:
                    continue
                matched += 1
                break

        if matched == len(expectations):
            return rows
        time.sleep(0.5)

    raise cmuxError(
        f"Timed out waiting for {session_key} coverage. "
        f"Expected={expectations!r} LastRows={last_rows!r}"
    )


def _matching_rows(rows: list[dict], expectations: list[dict]) -> list[dict]:
    matches: list[dict] = []
    for expectation in expectations:
        expected_dir = str(expectation["directory"])
        expected_agent = expectation["agent_type"]

        def _matches(candidate: dict) -> bool:
            if str(candidate.get("directory") or "") != expected_dir:
                return False
            session = candidate.get("cached_session") or {}
            if not isinstance(session, dict):
                return False
            return str(session.get("agent_type") or "") == expected_agent

        row = next(
            (candidate for candidate in rows if _matches(candidate)),
            None,
        )
        if row is not None:
            matches.append(row)
    return matches


def _quit_and_relaunch() -> None:
    launch_env = dict(os.environ)
    launch_env["CMUX_UI_TEST_MODE"] = "1"
    launch_env["CMUX_FORCE_SESSION_RESTORE"] = "1"
    launch_env["CMUX_TAG"] = RUN_TAG

    with cmux(SOCKET_PATH) as c:
        c.quit_app()

    quit_deadline = time.time() + 20.0
    while time.time() < quit_deadline:
        if not Path(SOCKET_PATH).exists():
            break
        time.sleep(0.1)

    subprocess.Popen(
        [APP_BINARY],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=launch_env,
        start_new_session=True,
    )
    subprocess.run(["open", APP_BUNDLE], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=launch_env)

    deadline = time.time() + 30.0
    last_error: Exception | None = None
    while time.time() < deadline:
        probe = None
        try:
            probe = cmux(SOCKET_PATH)
            probe.connect()
            if probe.ping():
                return
        except Exception as exc:
            last_error = exc
            time.sleep(0.2)
        finally:
            if probe is not None:
                try:
                    probe.close()
                except Exception:
                    pass

    raise cmuxError(f"Timed out reconnecting after relaunch: {last_error}")


def main() -> int:
    if _maybe_skip():
        return 0

    temp_root = Path(tempfile.mkdtemp(prefix="cmux_ai_restore_"))
    try:
        repo_matrix = {
            "ws1_claude": _create_git_repo(temp_root, "ws1-claude"),
            "ws1_codex": _create_git_repo(temp_root, "ws1-codex"),
            "ws2_claude": _create_git_repo(temp_root, "ws2-claude"),
            "ws2_codex": _create_git_repo(temp_root, "ws2-codex"),
        }

        with cmux(SOCKET_PATH) as c:
            c.activate_app()
            time.sleep(0.25)

            ws1 = c.new_workspace()
            c.select_workspace(ws1)
            ws1_surface_claude = _terminal_surface_id(c, ws1)
            ws1_surface_codex = c.new_split("right")

            ws2 = c.new_workspace()
            c.select_workspace(ws2)
            ws2_surface_claude = _terminal_surface_id(c, ws2)
            ws2_surface_codex = c.new_split("right")

            _launch_agent(c, ws1, ws1_surface_claude, repo_matrix["ws1_claude"], CLAUDE_COMMAND)
            _launch_agent(c, ws1, ws1_surface_codex, repo_matrix["ws1_codex"], CODEX_COMMAND)
            _launch_agent(c, ws2, ws2_surface_claude, repo_matrix["ws2_claude"], CLAUDE_COMMAND)
            _launch_agent(c, ws2, ws2_surface_codex, repo_matrix["ws2_codex"], CODEX_COMMAND)

            live_rows = _wait_for_session_rows(
                c,
                session_key="cached_session",
                expectations=[
                    {"directory": repo_matrix["ws1_claude"], "agent_type": "claude_code"},
                    {"directory": repo_matrix["ws1_codex"], "agent_type": "codex"},
                    {"directory": repo_matrix["ws2_claude"], "agent_type": "claude_code"},
                    {"directory": repo_matrix["ws2_codex"], "agent_type": "codex"},
                ],
                refresh=True,
                timeout_s=DETECTION_TIMEOUT_S,
            )

            claude_sessions = [
                row["cached_session"]
                for row in live_rows
                if isinstance(row.get("cached_session"), dict)
                and str((row.get("cached_session") or {}).get("agent_type") or "") == "claude_code"
            ]
            _must(
                all(str(session.get("session_id") or "") for session in claude_sessions),
                f"Expected live Claude sessions to carry session IDs: {claude_sessions!r}",
            )

        _quit_and_relaunch()

        with cmux(SOCKET_PATH) as c:
            restored_rows = _wait_for_session_rows(
                c,
                session_key="restored_session",
                expectations=[
                    {"directory": repo_matrix["ws1_claude"], "agent_type": "claude_code"},
                    {"directory": repo_matrix["ws1_codex"], "agent_type": "codex"},
                    {"directory": repo_matrix["ws2_claude"], "agent_type": "claude_code"},
                    {"directory": repo_matrix["ws2_codex"], "agent_type": "codex"},
                ],
                refresh=False,
                timeout_s=20.0,
            )

            restored_codex = [
                row["restored_session"]
                for row in restored_rows
                if isinstance(row.get("restored_session"), dict)
                and str((row.get("restored_session") or {}).get("agent_type") or "") == "codex"
            ]
            expected_codex_commands = {
                f"cd {shlex.quote(str(repo_matrix['ws1_codex']))} && codex",
                f"cd {shlex.quote(str(repo_matrix['ws2_codex']))} && codex",
            }
            observed_codex_commands = {
                str((session or {}).get("resume_command") or "")
                for session in restored_codex
            }
            _must(
                expected_codex_commands.issubset(observed_codex_commands),
                f"Expected restored Codex resume commands {expected_codex_commands!r}, got {observed_codex_commands!r}",
            )

            restored_expectations = [
                {"directory": repo_matrix["ws1_claude"], "agent_type": "claude_code"},
                {"directory": repo_matrix["ws1_codex"], "agent_type": "codex"},
                {"directory": repo_matrix["ws2_claude"], "agent_type": "claude_code"},
                {"directory": repo_matrix["ws2_codex"], "agent_type": "codex"},
            ]
            restored_row_map = {
                str(row.get("directory") or ""): row
                for row in restored_rows
                if isinstance(row.get("restored_session"), dict)
            }
            for expectation in restored_expectations:
                row = restored_row_map.get(str(expectation["directory"]))
                _must(row is not None, f"Missing restored row for {expectation!r}")
                c.resume_ai_session(str(row.get("surface_id") or ""))
                time.sleep(0.35)

            resumed_rows = _wait_for_session_rows(
                c,
                session_key="cached_session",
                expectations=restored_expectations,
                refresh=True,
                timeout_s=DETECTION_TIMEOUT_S,
            )
            resumed_matches = _matching_rows(resumed_rows, restored_expectations)
            _must(
                len(resumed_matches) == len(restored_expectations),
                f"Expected resumed matches for every restored session, got {resumed_matches!r}",
            )

            restored_claude_sessions = {
                str((row.get("restored_session") or {}).get("session_id") or "")
                for row in restored_rows
                if isinstance(row.get("restored_session"), dict)
                and str((row.get("restored_session") or {}).get("agent_type") or "") == "claude_code"
            }
            resumed_claude_sessions = {
                str((row.get("cached_session") or {}).get("session_id") or "")
                for row in resumed_matches
                if isinstance(row.get("cached_session"), dict)
                and str((row.get("cached_session") or {}).get("agent_type") or "") == "claude_code"
            }
            _must(
                restored_claude_sessions.issubset(resumed_claude_sessions),
                f"Expected resumed Claude session IDs {restored_claude_sessions!r}, got {resumed_claude_sessions!r}",
            )

            lingering_restored = [
                row
                for row in resumed_matches
                if isinstance(row.get("restored_session"), dict)
            ]
            _must(
                not lingering_restored,
                f"Expected restored-session banner state to clear after resume, got {lingering_restored!r}",
            )

        print("PASS: AI session detection + restore works across split panels and workspaces")
        return 0
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
