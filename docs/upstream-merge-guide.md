# Upstream Merge Guide

How to merge `upstream/main` (manaflow-ai/cmux) into our fork (atlascodesai/cmux-atlas).

## Quick Reference

```bash
git fetch upstream main
git merge --no-commit --no-ff upstream/main
# resolve conflicts per the rules below
git add -A && git commit -m "merge: sync with upstream ($(git rev-parse --short upstream/main))"
```

---

## Conflict Categories

### Category A: "Always Keep Ours" — Mechanical Overrides

These files have fork-specific naming/branding that **always** takes our version.
Resolution: `git checkout --ours <file>` then re-apply any new upstream additions manually.

| File | What differs | Rule |
|------|-------------|------|
| `tests/test_ci_self_hosted_guard.sh` | Runner label (`atlas-macos-arm64` vs `warp-macos-15-arm64-6x`), job name (`ui-display-resolution-regression` vs `ui-regressions`), error messages | **Keep ours.** If upstream adds new guard checks, add them with our runner label. |
| `.github/workflows/ci.yml` — runner labels | `runs-on: [self-hosted, atlas-macos-arm64]` vs `runs-on: warp-macos-15-arm64-6x` | **Keep ours** for all `runs-on` lines. |
| `.github/workflows/ci.yml` — timeout | `timeout-minutes: 45` vs `timeout-minutes: 30` | **Keep ours** (45min needed for self-hosted runner). |

**How to resolve Category A files:**

```bash
# For guard test scripts: keep ours entirely, then diff upstream for new checks
git checkout --ours tests/test_ci_self_hosted_guard.sh
git checkout --ours tests/test_ci_unit_test_spm_retry.sh

# For ci.yml: more nuanced — see Category B below for new upstream steps
```

### Category B: "Keep Ours + Cherry-Pick Upstream Additions" — CI Workflow

The CI workflow (`ci.yml`) needs both our fork overrides AND any new upstream steps/jobs.

| Conflict area | Rule |
|--------------|------|
| Runner labels (`runs-on`) | Keep ours (`[self-hosted, atlas-macos-arm64]`) |
| Timeout values | Keep ours (45min for tests, 60min for build-and-lag) |
| Test invocation | **Take upstream's tee pattern**, then layer our watchdog wrapper on top (see below) |
| `workflow_dispatch` trigger | Keep ours (not in upstream) |
| New upstream jobs/steps | **Take from upstream**, adapt runner labels |
| New upstream skip-testing entries | **Take from upstream**, update guard test to match |
| Concurrency groups | Take upstream's if present |

**How to resolve ci.yml:**

1. Start from our version: `git checkout --ours .github/workflows/ci.yml`
2. Diff upstream's version to find new jobs/steps: `git diff upstream/main~55..upstream/main -- .github/workflows/ci.yml`
3. Manually add new upstream jobs/steps, replacing runner labels with ours
4. Run guard tests: `bash tests/test_ci_test_skips_match_upstream.sh`

### Category C: "Accept Both Sides" — Additive Content

These files have additions from both sides that don't actually conflict semantically — they just happen to be inserted at adjacent lines.

| File | What differs | Rule |
|------|-------------|------|
| `GhosttyTabs.xcodeproj/project.pbxproj` | Fork adds `Branding.swift`, `AISessionDetector.swift`, etc. Upstream adds `RemoteRelayZshBootstrap.swift`. | **Accept both.** Keep our fork files AND upstream's new files. Both entries go in the same list. |
| `Resources/Localizable.xcstrings` | Fork adds memory-related strings (`memory.footer.*`). Upstream adds new feature strings (`menu.openInIntelliJ`, `error.remoteDrop.*`, etc.). | **Accept both.** This is a JSON-like file — both sets of strings belong. |

**How to resolve Category C files:**

```bash
# For pbxproj: manually merge — include both sides' file references
# For Localizable.xcstrings: include all string entries from both sides
# Tip: resolve in an editor, ensure valid JSON/plist structure
```

### Category D: "Careful Manual Merge" — Source Code

These files have real code changes on both sides that need understanding.

| File | Ours | Upstream | Rule |
|------|------|----------|------|
| `Sources/ContentView.swift` | Memory usage badge in tab view (`workspaceMemorySummary`) | Upstream UI changes (pinned workspace, close tab dialog, etc.) | **Merge both.** Our memory badge is additive. Keep it alongside upstream changes. |
| `Sources/GhosttyTerminalView.swift` | `restoredTerminalActionBannerHostingView` property | SSH image transfer UI (`imageTransferIndicatorContainerView`, spinner, cancel button) | **Merge both.** Our restored-terminal banner and upstream's image transfer indicator are independent features. Keep both property declarations. |

**How to resolve Category D files:**

1. Open the conflicted file
2. For each conflict block, understand what each side added
3. Include both additions — they're typically independent features
4. Build to verify: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build`

---

## Post-Merge Checklist

After resolving all conflicts:

- [ ] `bash tests/test_ci_test_skips_match_upstream.sh` — guard test passes
- [ ] `bash tests/test_ci_self_hosted_guard.sh` — runner guard passes
- [ ] `bash tests/test_ci_unit_test_spm_retry.sh` — SPM retry guard passes
- [ ] Build compiles: `xcodebuild ... build` (use tagged derivedDataPath)
- [ ] Commit and push to trigger CI
- [ ] All CI jobs pass (except known `ui-display-resolution-regression` issue)

---

## Fork-Specific Files (Never in Upstream)

These files only exist in our fork and won't conflict, but be aware they exist:

| File | Purpose |
|------|---------|
| `Sources/Branding.swift` | Centralized brand constants (bundle IDs, socket paths) |
| `Sources/AISessionDetector.swift` | AI session detection and resume |
| `Sources/AISessionResumeView.swift` | AI session resume UI |
| `Sources/EditorSyncController.swift` | Editor sync feature |
| `Sources/EditorSyncTitlebarButton.swift` | Editor sync titlebar button |
| `tests/test_ci_test_skips_match_upstream.sh` | Guard: skip list matches upstream |

---

## Upstream Remote Setup

```bash
# One-time setup (already done)
git remote add upstream https://github.com/manaflow-ai/cmux.git

# Check how far behind we are
git fetch upstream main
git log --oneline $(git merge-base HEAD upstream/main)..upstream/main | wc -l
```
