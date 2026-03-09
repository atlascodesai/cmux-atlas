#!/usr/bin/env python3
"""Regression test for workspace.create focus=true semantics."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        original_workspace_id = client.current_workspace()
        original_window_id = client.current_window()

        created = client._call(
            "workspace.create",
            {
                "window_id": original_window_id,
                "workspace_id": original_workspace_id,
                "focus": True,
            },
        ) or {}
        focused_workspace_id = created.get("workspace_id")
        _must(
            isinstance(focused_workspace_id, str) and focused_workspace_id,
            f"workspace.create returned no workspace_id: {created}",
        )

        _must(
            client.current_workspace() == focused_workspace_id,
            f"workspace.create focus=true should select new workspace, got {client.current_workspace()} expected {focused_workspace_id}",
        )
        _must(
            client.current_window() == original_window_id,
            f"workspace.create focus=true should keep current window, got {client.current_window()} expected {original_window_id}",
        )

    print("PASS: workspace.create focus=true selects new workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
