#!/usr/bin/env python3
"""Regression test for browser surface.move focus=true visibility semantics.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_browser_visibility(
    client: cmux,
    panel_id: str,
    workspace_id: str,
    timeout_s: float = 8.0,
) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = client.panel_lifecycle()
        last_snapshot = snapshot
        row = next(
            (
                row
                for row in list(snapshot.get("records") or [])
                if row.get("panelId") == panel_id and row.get("workspaceId") == workspace_id
            ),
            None,
        )
        if row and row.get("selectedWorkspace") is True:
            anchor = dict(row.get("anchor") or {})
            if (
                row.get("activeWindowMembership") is True
                and row.get("residency") == "visibleInActiveWindow"
                and int(anchor.get("windowNumber") or 0) != 0
            ):
                return dict(row)
        time.sleep(0.05)
    raise cmuxError(f"timed out waiting for visible moved browser: {last_snapshot}")


def _open_browser_from_current_terminal(
    client: cmux,
    url: str,
) -> tuple[str, str, str]:
    workspace_id = client.current_workspace()
    source_window_id = client.current_window()
    snapshot = client.panel_lifecycle()
    terminal = next(
        (
            row
            for row in list(snapshot.get("records") or [])
            if row.get("workspaceId") == workspace_id
            and row.get("panelType") == "terminal"
            and row.get("selectedWorkspace") is True
        ),
        None,
    )
    if not terminal:
        raise cmuxError(f"missing current terminal anchor for browser.open_split: {snapshot}")
    opened = client._call(
        "browser.open_split",
        {
            "url": url,
            "workspace_id": workspace_id,
            "surface_id": terminal["panelId"],
        },
    ) or {}
    browser_panel_id = opened.get("surface_id")
    if not isinstance(browser_panel_id, str) or not browser_panel_id:
        raise cmuxError(f"browser.open_split returned no surface_id: {opened}")
    client.focus_surface(browser_panel_id)
    return workspace_id, source_window_id, browser_panel_id


def _prepare_fresh_source_workspace(client: cmux) -> tuple[str, str]:
    current_workspace_id = client.current_workspace()
    source_window_id = client.current_window()
    created = client._call(
        "workspace.create",
        {
            "window_id": source_window_id,
            "workspace_id": current_workspace_id,
            "focus": True,
        },
    ) or {}
    source_workspace_id = created.get("workspace_id")
    _must(
        isinstance(source_workspace_id, str) and source_workspace_id,
        f"workspace.create returned no workspace_id: {created}",
    )
    _wait_for_current_workspace(client, source_workspace_id)
    return source_workspace_id, source_window_id


def _wait_for_current_workspace(
    client: cmux,
    expected_workspace_id: str,
    timeout_s: float = 8.0,
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if client.current_workspace() == expected_workspace_id:
            return
        time.sleep(0.05)
    raise cmuxError(
        f"surface.move focus=true should select destination workspace, got {client.current_workspace()} expected {expected_workspace_id}"
    )


def _wait_for_current_window(
    client: cmux,
    expected_window_id: str,
    timeout_s: float = 8.0,
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if client.current_window() == expected_window_id:
            return
        time.sleep(0.05)
    raise cmuxError(
        f"surface.move within a window should preserve current window, got {client.current_window()} expected {expected_window_id}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        source_workspace_id, source_window_id = _prepare_fresh_source_workspace(client)
        opened_workspace_id, opened_window_id, browser_panel_id = _open_browser_from_current_terminal(
            client,
            "https://example.com/browser-surface-move-focus",
        )
        _must(
            opened_workspace_id == source_workspace_id,
            f"browser should open in the fresh source workspace, got {opened_workspace_id} expected {source_workspace_id}",
        )
        _must(
            opened_window_id == source_window_id,
            f"browser should open in the source window, got {opened_window_id} expected {source_window_id}",
        )
        _wait_for_browser_visibility(client, browser_panel_id, source_workspace_id)

        created = client._call(
            "workspace.create",
            {
                "window_id": source_window_id,
                "workspace_id": source_workspace_id,
                "focus": False,
            },
        ) or {}
        destination_workspace_id = created.get("workspace_id")
        _must(
            isinstance(destination_workspace_id, str) and destination_workspace_id,
            f"workspace.create returned no workspace_id: {created}",
        )
        _must(
            client.current_workspace() == source_workspace_id,
            f"workspace.create focus=false should preserve current workspace, got {client.current_workspace()} expected {source_workspace_id}",
        )

        client.move_surface(browser_panel_id, workspace=destination_workspace_id, focus=True)
        _wait_for_current_workspace(client, destination_workspace_id)
        _wait_for_current_window(client, source_window_id)

        browser = _wait_for_browser_visibility(client, browser_panel_id, destination_workspace_id)
        _must(browser.get("selectedWorkspace") is True, f"browser not selected after move: {browser}")
        _must(browser.get("activeWindowMembership") is True, f"browser not active-window member after move: {browser}")
        _must(browser.get("residency") == "visibleInActiveWindow", f"browser wrong residency after move: {browser}")

    print("PASS: browser surface.move focus=true preserves visible residency")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
