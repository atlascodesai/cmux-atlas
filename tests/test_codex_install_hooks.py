#!/usr/bin/env python3
"""
Behavioral regression test for `cmux codex install-hooks` / `uninstall-hooks`.
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import tempfile
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


def run_cli(cli_path: str, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli_path, *args],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def hook_commands(hooks_json: dict) -> dict[str, str]:
    hooks = hooks_json.get("hooks") or {}
    extracted: dict[str, str] = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list) or not groups:
            continue
        first_group = groups[0]
        if not isinstance(first_group, dict):
            continue
        inner = first_group.get("hooks")
        if not isinstance(inner, list) or not inner:
            continue
        first_hook = inner[0]
        if isinstance(first_hook, dict) and isinstance(first_hook.get("command"), str):
            extracted[event] = first_hook["command"]
    return extracted


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    with tempfile.TemporaryDirectory(prefix="cmux-codex-install-hooks-") as td:
        codex_home = Path(td)
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)

        hooks_path = codex_home / "hooks.json"
        config_path = codex_home / "config.toml"
        config_path.write_text("[features]\ncodex_hooks = false\n", encoding="utf-8")

        proc = run_cli(cli_path, "codex", "install-hooks", "--yes", env=env)
        if proc.returncode != 0:
            return fail(f"default install-hooks failed:\nstdout={proc.stdout}\nstderr={proc.stderr}")
        if not hooks_path.exists():
            return fail("Expected hooks.json after default install-hooks")

        hooks_json = json.loads(hooks_path.read_text(encoding="utf-8"))
        commands = hook_commands(hooks_json)
        expected_events = {"SessionStart", "UserPromptSubmit", "Stop"}
        if set(commands) != expected_events:
            return fail(f"default install-hooks events mismatch: got {set(commands)!r}")
        if "SessionEnd" in commands:
            return fail("default install-hooks unexpectedly installed SessionEnd")
        if not all("cmux codex-hook" in command for command in commands.values()):
            return fail(f"default install-hooks wrote unexpected commands: {commands!r}")

        config_text = config_path.read_text(encoding="utf-8")
        if "codex_hooks = true" not in config_text:
            return fail("default install-hooks did not enable codex_hooks = true")

        proc = run_cli(cli_path, "codex", "install-hooks", "--yes", "--atlas-extended", env=env)
        if proc.returncode != 0:
            return fail(f"atlas-extended install-hooks failed:\nstdout={proc.stdout}\nstderr={proc.stderr}")

        hooks_json = json.loads(hooks_path.read_text(encoding="utf-8"))
        commands = hook_commands(hooks_json)
        if "SessionEnd" not in commands:
            return fail("atlas-extended install-hooks did not add SessionEnd")
        if "cmux codex-hook session-end" not in commands["SessionEnd"]:
            return fail(f"atlas-extended SessionEnd command mismatch: {commands['SessionEnd']!r}")

        proc = run_cli(cli_path, "codex", "uninstall-hooks", env=env)
        if proc.returncode != 0:
            return fail(f"uninstall-hooks failed:\nstdout={proc.stdout}\nstderr={proc.stderr}")

        hooks_json = json.loads(hooks_path.read_text(encoding="utf-8"))
        if any("cmux codex-hook" in command for command in hook_commands(hooks_json).values()):
            return fail("uninstall-hooks left cmux Codex hook commands behind")

        config_text = config_path.read_text(encoding="utf-8")
        if "codex_hooks" in config_text:
            return fail("uninstall-hooks did not remove codex_hooks from config.toml")

        print("PASS: codex install-hooks/uninstall-hooks manage default and Atlas-extended hooks")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
