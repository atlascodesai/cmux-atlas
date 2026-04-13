# cvm / cmux / codex Interplay

How the three systems interact when launching and managing AI agent sessions.

## Architecture

```
User types "claude" or "codex" in cmux terminal
  │
  ▼
cmux wrapper (Resources/bin/claude or codex)    ← first on PATH
  │ detects CMUX_SURFACE_ID env var
  │ verifies cmux socket is alive
  │ injects hooks + session tracking flags
  │ scans PATH (skipping itself) to find real binary
  │
  ▼
cvm symlink (~/.cvm/bin/claude or codex)        ← if cvm installed
  │ points to active version
  │
  ▼
Real binary (e.g. ~/.cvm/versions/2.1.91/native/claude)
```

## Components

### cvm (Claude Version Manager)

Manages multiple installed versions of Claude Code and Codex.

- **Location:** `~/.cvm/`
- **Versions:** `~/.cvm/versions/<version>/native/claude` (365+ Claude versions)
- **Products:** `~/.cvm/products/codex/versions/<branch>/dev/bin/codex` (Codex dev builds)
- **Active symlinks:** `~/.cvm/bin/claude` and `~/.cvm/bin/codex` point to selected versions
- **Config:** `~/.cvm/config.json`

cvm is optional. Without it, the wrappers fall through to whatever `claude`/`codex` is on PATH.

### cmux Wrappers (Resources/bin/)

Three shim scripts bundled inside the cmux app, added to PATH first via shell integration:

| Wrapper | What it does |
|---------|-------------|
| `claude` | Injects `--settings` JSON with lifecycle hooks (session-start, stop, notification, prompt-submit, pre-tool-use) + generates `--session-id` |
| `codex` | Injects `--enable codex_hooks` + hook commands (session-start, stop) |
| `open` | Routes `open https://...` to cmux's embedded browser instead of system browser |

All three use the same pattern:
1. Detect if running inside cmux (`CMUX_SURFACE_ID` env var)
2. Verify cmux socket is alive (0.75s timeout ping)
3. Find the real binary by walking PATH, skipping own directory
4. Inject cmux integration flags
5. `exec` the real binary (wrapper PID becomes the real process PID)

When outside cmux (no `CMUX_SURFACE_ID`), wrappers pass through directly — no hooks injected.

### Hook Communication

When Claude/Codex runs with injected hooks:

```
Claude Code fires lifecycle event (e.g. SessionStart)
  │
  ▼
Calls: cmux claude-hook session-start (via shell)
  │
  ▼
cmux CLI receives hook, sends to cmux app via Unix socket
  │
  ▼
cmux app updates sidebar status, notifications, session tracking
```

Hook data is stored in:
- `~/.cmuxterm/claude-hook-sessions.json`
- `~/.cmuxterm/codex-hook-sessions.json`

### Binary Resolution Order

**For `claude`:**
1. cmux wrapper (`/Applications/cmux Atlas.app/Contents/Resources/bin/claude`)
2. PATH scan finds: `~/.cvm/bin/claude` → `~/.cvm/versions/<ver>/native/claude`
3. Or without cvm: `~/.local/bin/claude`, homebrew, etc.

**For `codex`:**
1. cmux wrapper (`/Applications/cmux Atlas.app/Contents/Resources/bin/codex`)
2. PATH scan finds: `~/.cvm/bin/codex` → `~/.cvm/products/codex/versions/<branch>/dev/bin/codex`
3. Or without cvm: any `codex` on PATH

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `CMUX_SURFACE_ID` | Set by cmux on each terminal panel — signals "inside cmux" |
| `CMUX_SOCKET_PATH` | Path to cmux's Unix domain socket for CLI communication |
| `CMUX_CLAUDE_PID` | Wrapper's PID (becomes claude PID after exec) for stale detection |
| `CMUX_CODEX_PID` | Same for codex |
| `CMUX_CLAUDE_HOOKS_DISABLED` | Set to `1` to skip hook injection |
| `CMUX_CODEX_HOOKS_DISABLED` | Set to `1` to skip hook injection |
| `CMUX_BUNDLE_ID` | Bundle ID for the `open` wrapper's settings domain |

### Session Detection

`AISessionDetector.swift` identifies running agent sessions by:
1. Inspecting child processes of each terminal panel's shell via PID
2. Matching executable names (`claude`, `codex`)
3. For Claude: resolving session ID by scanning `~/.claude/projects/` JSONL files
4. Storing snapshots for crash recovery / session resume
