# Atlas Fork Rebuild Plan

This document defines the strategy for rebuilding the Atlas fork on top of a fresh `upstream/main` base while keeping the current release line intact.

Current state at the time this plan was written:

- stable Atlas release line: `main` at `d7346911` (`v1.38.1-atlas.5`)
- current upstream base: `upstream/main` at `e9afc223`
- fork delta: `49` commits ahead, `0` behind

This plan exists because the fork is now caught up to upstream, but the carried delta is larger and less modular than it needs to be. A selective rebuild should make future upstream syncs cheaper and make it easier to upstream generic improvements.

## Goals

1. Preserve the current shipping Atlas app while we rebuild on a clean upstream base.
2. Reapply Atlas-specific product work in a smaller number of clearer, additive changes.
3. Separate product features from fork plumbing and merge-repair history.
4. Structure the work so each feature can land as its own PR into the fresh branch.
5. End with a full release rehearsal on the rebuilt line before we treat it as the new stable base.

## Non-Goals

- Rewriting the app architecture from scratch.
- Reapplying every historical merge-smoothing commit mechanically.
- Refactoring upstream hotspot files unless that refactor is required for a specific Atlas feature.

## Canonical Documents

These files should stay in the repo and be treated as the durable source of truth.

- `docs/fork-rebuild-plan.md`
  - strategy, phases, branch model, release gates
- `docs/atlas-commit-classification.md`
  - map of fork-only commits by category
- `docs/upstream-merge-guide.md`
  - process for future upstream syncs once the rebuilt fork exists

## Execution Tracking

Keep the day-to-day execution log out of git history.

Recommended local tracking file:

- `tmp/fork-rebuild-worklog.md`

Why:

- `tmp/` is already gitignored
- it keeps iteration notes, checklists, and throwaway findings out of the repo history
- the canonical plan remains committed, while the worklog can change freely during implementation

If we later want shared team tracking, move milestones into Linear or a repo project board, but keep implementation scratch local.

## Branch Model

Use four branch roles.

### 1. Stable release line

- `main`

Rules:

- always shippable
- continues to receive urgent fixes and releases
- no risky rebuild work lands here until the rebuilt line is proven

### 2. Preserved current fork line

- `archive/main-pre-clean-rebuild-20260329`

Purpose:

- frozen reference point for the current fork as shipped
- fallback branch if the rebuild effort needs to inspect or cherry-pick existing behavior

### 3. Fresh rebuild base

- `rebuild/upstream-clean-20260329`

Start point:

- branch directly from `upstream/main`

Purpose:

- clean upstream baseline
- no Atlas changes at branch creation time
- all Atlas behavior gets reapplied intentionally from here

### 4. Feature branches off the rebuild base

Examples:

- `feat/rebuild-branding`
- `feat/rebuild-ai-resume-core`
- `feat/rebuild-editor-sync`
- `feat/rebuild-memory-footer`
- `feat/rebuild-atlas-workflows`
- `feat/rebuild-release-rehearsal`

Each feature branch should be narrowly scoped and merged into `rebuild/upstream-clean-20260329` through PRs.

## Strategy Principles

1. Reapply only what we actually want to keep.
2. Prefer additive files and narrow seams over deep edits in hotspot runtime files.
3. Upstream generic fixes rather than carrying them indefinitely.
4. Treat release plumbing, CI policy, and Atlas product features as separate workstreams.
5. Validate every major feature slice on GitHub Actions before stacking the next one.

## Source Inventory

The input to this rebuild is the current fork delta, classified in `docs/atlas-commit-classification.md`.

Reapply by default:

- section 1: Atlas product features and user-facing fixes

Reapply only if still needed operationally:

- section 2: fork plumbing, release, CI, and signing policy

Do not assume these should survive unchanged:

- section 3: merge-smoothing and migration-only work

Use as historical markers only:

- section 4 and section 5

## Target Architecture For The Rebuilt Fork

The rebuilt fork should prefer these patterns:

### Atlas-only behavior

- additive files
- explicit Atlas-owned commands, services, and extensions
- as little code as possible inside the upstream hotspots:
  - `Sources/TabManager.swift`
  - `Sources/Workspace.swift`
  - `Sources/AppDelegate.swift`
  - `Sources/ContentView.swift`
  - `Sources/GhosttyTerminalView.swift`
  - `CLI/cmux.swift`

### Fork plumbing

- keep release feed, signing, CI policy, and Sentry configuration in scripts, workflows, and config files
- avoid runtime coupling when the change is operational only

### Generic fixes

- if a fix is not Atlas-branded and not tied to our release channel, evaluate it for upstream PR submission

## Rebuild Phases

### Phase 0. Freeze and record the baseline

Outputs:

- archive branch created from current `main`
- fresh rebuild branch created from `upstream/main`
- canonical plan and local worklog in place

Checklist:

- create archive branch from current shipping line
- create clean rebuild branch from upstream
- confirm `git log upstream/main..main` is captured in the classification doc

### Phase 1. App identity and fork shell

Goal:

- make the rebuilt app coexist with upstream without yet reintroducing all Atlas behavior

Expected scope:

- branding
- bundle id and app name changes
- update feed / Sparkle channel configuration
- Sentry project/config if still desired
- release script naming and DMG conventions

PR target:

- `rebuild/upstream-clean-20260329`

Release gate:

- tagged debug build compiles
- release workflow compiles on GitHub

### Phase 2. AI resume core

Goal:

- restore the essential Claude/Codex resume behavior with a cleaner modular shape

Expected scope:

- `SessionPersistence` Atlas additions
- hook stores and registry
- terminal resume payload model
- refresh action
- resume telemetry

Design rule:

- keep lookup logic in dedicated resume services where possible
- avoid spreading Atlas-specific matching logic across unrelated runtime code

Potential split:

- PR 2A: resume core data model and registry
- PR 2B: UI affordances and refresh action
- PR 2C: observability and diagnostics

### Phase 3. Editor sync, markdown panel, and related AI UX

Goal:

- add the Atlas-specific experience layers that sit on top of resume support

Expected scope:

- editor sync
- markdown panel
- any AI-specific panel affordances not already covered by resume core

Design rule:

- prefer additive panel/service files
- keep upstream panel/runtime containers as untouched as possible

### Phase 4. Memory footer and process tracking

Goal:

- carry the Atlas memory monitor in a form that minimizes drift from upstream

Expected scope:

- global memory aggregation
- panel/TTY linkage
- footer and popover presentation

Design rule:

- isolate the store and triggering hooks
- keep hot paths lightweight

### Phase 5. Small user-facing Atlas deltas

Goal:

- reapply the small but worthwhile UX additions

Likely items:

- `Copy Path`
- `Reveal in Finder`
- pasteboard recursion fix if still needed
- any narrow shell integration fixes

These should land as one or more small PRs, and many may also be good upstream PR candidates.

### Phase 6. Fork CI and release policy

Goal:

- rebuild only the fork-specific workflow behavior we actually need

Likely items:

- self-hosted runner policy
- internal-only PR behavior
- merge-validation workflow
- release prioritization
- nightly behavior

Design rule:

- keep this workstream independent from runtime feature work
- validate workflows separately from app behavior where possible

### Phase 7. End-to-end release rehearsal

Goal:

- prove that the rebuilt line can go from source to shipped update without relying on the historical branch

Required flow:

1. merge all desired feature PRs into `rebuild/upstream-clean-20260329`
2. run a full tagged debug build:
   - `./scripts/reload.sh --tag rebuild-release-rehearsal`
3. bump the build number using the existing fork release structure
4. update `CHANGELOG.md`
5. tag a rehearsal release
6. run the full GitHub release workflow
7. verify:
   - GitHub release assets
   - `appcast.xml`
   - Sparkle sees the new version
   - session restore and AI resume still behave correctly after update

Only after this passes should we consider replacing `main` with the rebuilt line.

## PR Structure

The rebuilt branch should be assembled through a small stack of focused PRs. A suggested order:

1. `chore(rebuild): establish Atlas app identity on fresh upstream`
2. `feat(atlas): reintroduce AI resume core`
3. `feat(atlas): reintroduce resume telemetry and refresh action`
4. `feat(atlas): reintroduce editor sync and markdown panel`
5. `feat(atlas): reintroduce memory footer and process tracking`
6. `feat(atlas): reintroduce small UX additions`
7. `ci(atlas): restore fork workflow and release policy`
8. `release: rehearsal build on rebuilt fork`

For each PR:

- describe whether the change is:
  - Atlas product
  - fork plumbing
  - upstream candidate
- list the upstream hotspot files touched
- explain why that shape is the minimum needed

## Upstream PR Candidates

While rebuilding, actively collect generic fixes that should be proposed upstream.

Good candidates:

- generic crash guards
- restore guards
- context menu improvements that are not Atlas-specific
- shell integration bug fixes
- generic workflow fixes where they are not tied to our fork identity

Keep a section in the local worklog for:

- `upstream-candidate`
- `fork-only`
- `defer`

## Validation Rules

Local:

- after code changes, use:
  - `./scripts/reload.sh --tag <tag>`
- do not run tests locally

GitHub:

- use PR checks for:
  - `CI`
  - `macOS Compatibility`
  - `Build GhosttyKit`
  - `E2E` for internal PRs where appropriate
- use targeted merge validation workflows for faster loops while stabilizing a feature PR

## Exit Criteria

The rebuild is complete only when all of these are true:

1. the rebuilt branch is functionally equivalent to the Atlas features we still want
2. the rebuilt line is cleaner than the current fork in the hotspot files
3. a full release rehearsal succeeds
4. we can explain the remaining fork delta against upstream in a small, intentional set of features and policies
5. we have a shortlist of generic changes worth submitting upstream

## After The Rebuild

Once the rebuilt line is proven:

1. decide whether to fast-forward or replace `main`
2. preserve the old line on an archive branch
3. keep using the merge guide in `docs/upstream-merge-guide.md`
4. upstream generic fixes in smaller PRs instead of carrying them indefinitely

## Practical Rule

If a change on the rebuilt branch does not clearly fit one of these labels, stop and classify it before coding:

- `feat(atlas)`
- `fix(atlas)`
- `ci(atlas)`
- `fix(merge)`
- `docs(merge)`
- `release`

That discipline is the main guard against drifting back into another hard-to-merge fork.
