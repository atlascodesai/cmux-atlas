# Upstream Merge Guide

How to merge `upstream/main` (manaflow-ai/cmux) into our fork (atlascodesai/cmux-atlas) after the Atlas seam refactor.

## Quick Start

Use the dry-run helper first:

```bash
./scripts/upstream-merge-dry-run.sh --fetch
```

For the mechanical Atlas policy files during a real merge:

```bash
./scripts/upstream-merge-apply-atlas-overrides.sh
```

When the dry run looks reasonable:

```bash
git fetch upstream main
git switch -c merge/upstream-$(date +%Y%m%d)
git merge --no-commit --no-ff upstream/main
# resolve conflicts
git add -A && git commit -m "merge: sync with upstream ($(git rev-parse --short upstream/main))"
```

## Atlas Seams

These fork-owned files are intentionally additive. They should usually merge cleanly and should not be re-inlined into upstream-heavy files.

| File | Purpose |
|------|---------|
| `CLI/CMUXCLI+AgentHooks.swift` | Claude/Codex hook handling |
| `Sources/AtlasAIQuickLaunch.swift` | Fork-owned AI quick-launch UI |
| `Sources/AtlasAppCommands.swift` | Fork-owned app/menu commands |
| `Sources/CMUXCoreNewItemCommands.swift` | Base File > New item replacement kept out of `cmuxApp.swift` |
| `Sources/TabManager+AtlasAISessions.swift` | Agent PID sweep and AI resume prefill |
| `Sources/TabManager+AtlasOrganizations.swift` | Organization save/switch logic |
| `Sources/AppDelegate+AtlasAISessions.swift` | Global AI-session refresh orchestration |
| `Sources/AppDelegate+AtlasOrganizations.swift` | Open organization in new window |
| `Sources/WorkspaceAtlasAISessions.swift` | Workspace AI-session store and refresh logic |

If a future merge conflict starts pulling this logic back into `TabManager.swift`, `Workspace.swift`, `AppDelegate.swift`, or `cmux.swift`, treat that as a regression in mergeability.

## Current Conflict Classes

After the seam refactor, the remaining conflict surface falls into three buckets.

### 1. Mechanical Fork Overrides

These are mostly policy files. They are good candidates for scripted resolution or generated overlays.

| File(s) | Rule |
|--------|------|
| `.github/workflows/ci.yml` | Keep Atlas runner labels/timeouts, then reapply new upstream jobs/steps |
| `.github/workflows/ci-macos-compat.yml` | Same as above |
| `.github/workflows/build-ghosttykit.yml` | Keep Atlas build assumptions, then reapply upstream job changes |
| `scripts/reload.sh` | Keep tagged Atlas launch/socket behavior, then reapply upstream improvements |
| `tests/test_ci_self_hosted_guard.sh` | Keep Atlas runner/guard expectations |

Recommended automation:

- Add a small merge helper that starts from `--ours` for these files and then diffs upstream for new jobs/steps.
- Consider generating CI workflow fragments from a fork overlay so runner labels and timeout policies are not hand-merged in YAML.

### 2. Registration Hotspots

These files still conflict because both sides register commands, files, or menus in one central place.

| File | Why it still conflicts | Better future seam |
|------|------------------------|--------------------|
| `CLI/cmux.swift` | Central command/help registry still lives here | Move to a command registry so Atlas and upstream commands register separately |
| `Sources/cmuxApp.swift` | Command composition still happens in the app entrypoint | Keep base and Atlas command groups in separate command files and make `cmuxApp.swift` a thin mount point |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Every new source file touches the same lists | Move Atlas-only code into a local Swift package/product |

Recommended automation:

- Make a local `AtlasFeatures` Swift package so most future fork files stop touching `project.pbxproj`.
- Move CLI help/dispatch into a table-driven registry to keep new Atlas commands out of `cmux.swift`.

### 3. Shared Runtime Contracts

These files still conflict because upstream and fork code both modify the same UI/runtime boundary.

| File | Typical overlap |
|------|------------------|
| `Sources/TabManager.swift` | Workspace creation, focus/history, lifecycle snapshots |
| `Sources/Workspace.swift` | Panel lifecycle and terminal inheritance |
| `Sources/AppDelegate.swift` | Main-window orchestration |
| `Sources/ContentView.swift` | Sidebar/resize/tab-row composition |
| `Sources/WorkspaceContentView.swift` | Workspace-level view feature flags/experiments |
| `Sources/GhosttyTerminalView.swift` | Terminal runtime safety and overlays |
| `Sources/Panels/TerminalPanel.swift` | Surface input/resume/send semantics |
| `Sources/Update/UpdateController.swift` | Update UI/policy |

Recommended refactor direction:

- Prefer upstream-owned base types with Atlas adapters or view slots.
- When upstream adds a new capability, attach Atlas behavior through one hook point instead of editing the same branch-heavy method.
- Avoid adding new stored state directly to these files unless it is genuinely core behavior.

## Latest Dry-Run Result

Dry merge against `upstream/main` after the seam refactor still produced conflicts, but the new Atlas-only files stayed clean and several former conflict regions moved out of upstream-owned files.

Current conflicted files:

```text
.github/workflows/build-ghosttykit.yml
.github/workflows/ci-macos-compat.yml
.github/workflows/ci.yml
CLI/cmux.swift
GhosttyTabs.xcodeproj/project.pbxproj
Resources/bin/claude
Resources/shell-integration/cmux-zsh-integration.zsh
Sources/AppDelegate.swift
Sources/ContentView.swift
Sources/GhosttyTerminalView.swift
Sources/Panels/TerminalPanel.swift
Sources/TabManager.swift
Sources/Update/UpdateController.swift
Sources/Workspace.swift
Sources/WorkspaceContentView.swift
Sources/cmuxApp.swift
cmuxTests/WorkspaceRemoteConnectionTests.swift
scripts/reload.sh
tests/test_ci_self_hosted_guard.sh
```

That means the next high-value reductions are:

1. `project.pbxproj` via local package extraction.
2. `CLI/cmux.swift` via command registry split.
3. `cmuxApp.swift` via stricter menu injection boundaries.

## Post-Merge Checklist

- [ ] Dry run first: `./scripts/upstream-merge-dry-run.sh --fetch`
- [ ] Resolve conflicts and build with a tagged reload
- [ ] Verify CI guard scripts still reflect Atlas runner policy
- [ ] Push the merge branch and let GitHub Actions run tests
