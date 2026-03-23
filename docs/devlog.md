# cmux Dev Log

## 2026-03-14 — AI session restore, editor sync, markdown links, and AI quick launch

### Branch scope

This branch layers together:

1. AI coding-agent detection, persistence, and restore for Claude Code and Codex.
2. Editor sync from terminal context into the configured IDE.
3. Markdown-link interception that opens workspace markdown in a native panel.
4. Follow-up stabilization work to remove restore/autosave regressions.
5. New titlebar shortcuts for launching Claude Code and Codex directly.

### Earlier feature work on the branch

The first set of commits added the core AI-session and editor workflow:

- `ab5c907b` introduced AI coding-agent session detection and session restore plumbing.
- `230710ae` rewrote session ID resolution to correlate process and session identity more reliably.
- `4988250e` fixed target membership/project wiring for the new Swift files.
- `eb0ef310` added editor sync so a workspace directory can be opened in the configured editor.
- `30c408f3` added the editor-sync titlebar UI, scrollback-aware session persistence work, and a dev launch script.
- `0474b8c0` and `b213fab4` added markdown link interception so markdown files in the workspace open in a native markdown panel, with editor-sync aware directory handling.

### Stabilization and regression fixes

The first follow-up pass focused on making the branch safe to dogfood without feature regressions:

- Restored lightweight periodic autosave behavior so the hot autosave path no longer serializes full scrollback on every tick.
- Moved AI-session detection off the autosave path and into cached/background refreshes to avoid repeated `lsof`/`ps` work while typing.
- Fixed markdown link classification so scheme-less web URLs ending in `.md` are not treated as local workspace files.
- Fixed the markdown open path to use the correct current-directory handling.
- Changed the editor-sync titlebar shortcut from `Cmd-E` to `Shift-Cmd-E` to avoid colliding with the app's existing find shortcut.
- Localized the newly added UI strings instead of leaving raw literals in the interface.
- Changed Codex resume behavior so restored sessions restart from the recorded working directory instead of replaying a fragile raw `ps` command line.
- Moved the AI-session resume banner into the terminal portal layer so it stays visually correct during split/workspace churn.

### Restore and VM-test prep

The next pass addressed issues found while reviewing the live worktree and preparing VM coverage:

- Added an explicit `CMUX_FORCE_SESSION_RESTORE=1` override so VM/UI-test relaunches can verify restore behavior even when test mode is enabled.
- Stopped seeding the live AI-session cache from restored banner state; restored snapshots and live detection now stay separate.
- Added an immediate AI-session cache refresh after startup restore and before the first non-scrollback save so restored sessions are repopulated promptly.
- Added a low-frequency background AI-session refresh to catch Claude/Codex processes launched in terminals that were already open before detection kicked in.
- Added DEBUG-only socket seams for inspecting detected AI sessions and triggering resume in tests.
- Added a VM-gated Python restore matrix test that relaunches cmux, verifies restored sessions, and resumes them again across multiple workspaces.

### Quick-launch titlebar buttons

The latest pass added direct AI-agent launch controls in the titlebar:

- Added a Codex quick-launch button and a Claude Code quick-launch button to the left of the editor-sync control.
- Left-click opens a fresh terminal surface in the focused pane and launches the selected tool in the active workspace directory.
- Right-click toggles the permissive launch mode per tool:
  - Codex: `codex --yolo`
  - Claude Code: `claude --dangerously-skip-permissions`
- Added a small visual indicator when permissive mode is enabled.
- Localized the new button labels, help text, and context-menu strings.

### Status

The branch is in a manual-dogfooding state:

- Tagged Debug builds are running successfully.
- The remaining confidence gap is full VM execution with real authenticated `claude` and `codex` installs.
- The intended next validation step is a fresh VM snapshot plus the gated `tests_v2` AI restore flow.

## 2026-03-14 — Debug-only crash in DebugEventLog (bonsplit)

**Crash**: `EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0000000000000000`
**File**: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift:69`
**Queue**: `cmux.debug-event-log`
**Severity**: Debug builds only (`#if DEBUG`), no impact on release.

### What happens

`DebugEventLog.log()` opens a new `FileHandle` on every call, writes, then closes it. If the underlying file (`/tmp/cmux-debug*.log`) is deleted between open and write (e.g., `/tmp` cleanup, another cmux instance), `handle.write(data)` throws an `NSException` (ObjC, not caught by Swift) → `abort()`.

Sentry's crash reporter then also crashes trying to write its own envelope to a nil file writer, producing a double-crash report.

### Root cause

```swift
// Line 67-70 — opens/closes handle per log call, no ObjC exception safety
if let handle = FileHandle(forWritingAtPath: Self.logPath) {
    handle.seekToEndOfFile()
    handle.write(data)   // crashes here
    handle.closeFile()
}
```

### Fix options (not yet applied)

1. **Keep a persistent file handle** instead of open/close per call. Reopen only if write fails.
2. **Wrap in ObjC `@try/@catch`** to handle the `NSException` from `FileHandle.write`.
3. **Use `OutputStream` or POSIX `write()`** instead of `FileHandle` to avoid ObjC exceptions entirely.

Option 1 is simplest and also improves performance (no open/close per log line).
