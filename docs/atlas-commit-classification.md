# Atlas Commit Classification

This is a retrospective map of the Atlas-only commits that are still unique to this fork relative to `upstream/main`, as of `v1.38.1-atlas.4`.

The goal is to separate:

- real Atlas product work
- fork/release/CI plumbing
- upstream-merge smoothing and migration-only fixes

That distinction matters because the migration-only bucket should not be mistaken for durable product differentiation.

## 1. Real Atlas Product Features And User-Facing Fixes

These are the commits that represent actual fork behavior, user-visible features, or user-visible bug fixes we intentionally want to carry.

| Commit | Type | Summary |
| --- | --- | --- |
| `016a03b6` | feature | Rebrand fork to `cmux Atlas` for side-by-side coexistence |
| `edf338b9` | feature | Add AI session resume, editor sync, memory monitor, and markdown panel |
| `aee78855` | feature | Add `Copy Path` and `Reveal in Finder` to tab/workspace context menus |
| `f4e89870` | fix | Avoid pasteboard recursion in session snapshots |
| `1cf3953f` | fix | Unify AI session resume lifecycle |
| `ca381981` | fix | Show tracked terminal memory in footer instead of app-only memory |
| `52e3ac50` | fix | Restore relaunch session recovery and fix zsh integration regression |
| `08d68979` | fix | Add AI resume refresh diagnostics, Sentry signals, and workspace-scoped refresh action |

Notes:

- This is the bucket we should think of as "the Atlas product."
- If we ever rebuild the fork cleanly from fresh upstream, these are the changes we should evaluate first for reapplication.

## 2. Fork Plumbing, Release, And CI Policy

These commits are important for operating the fork, but they are not product features.

| Commit | Type | Summary |
| --- | --- | --- |
| `37f6ef0b` | plumbing | Point submodules to Atlas forks |
| `998d9984` | test/ci | Add fork-specific tests and CI guard tests |
| `2b40e868` | ci | Use self-hosted runner with Atlas branding |
| `1cf68ffa` | infra | Update GhosttyKit checksum for Atlas fork |
| `bba93070` | test/ci | Remove Ghostty CLI-helper regression tests |
| `b7c701eb` | dev | Launch branded Release app from `reloadp` |
| `8332ffca` | ci | Automate upstream sync PRs |
| `d0c607e8` | release | Align fork release pipeline with Atlas update channel |
| `b606c873` | ops | Update Sentry config for fork and add README fork note |
| `303db231` | signing | Include system keychains in CI signing search list |
| `e7bc2748` | signing | Install Apple intermediate certs in CI signing keychain |
| `f0bfcc34` | ci | Add npm global bin to `PATH` for `create-dmg` |
| `86170d56` | signing | Sign embedded frameworks in inside-out order |
| `8db05501` | docs | Document upstream merge process |
| `bb6b080b` | ci/policy | Gate external PRs and run E2E on internal PRs |
| `94bbc049` | ci | Add targeted merge validation workflow |
| `c8a42c6e` | ci | Duplicate targeted merge validation workflow commit during rollout |
| `6c1bf547` | ci | Fix merge validation watcher |
| `2fbd14a9` | ci | Same merge validation watcher fix cherry-picked onto `main` |
| `609658f6` | ci | Prioritize release workflows |

Notes:

- These commits are durable, but they are operational rather than product-specific.
- When reviewing future release risk, do not mix this bucket into user-facing change summaries.

## 3. Upstream-Merge Smoothing And Migration-Only Work

These commits mostly exist because the upstream merge was incomplete or rough. They helped the migration land, but they are not the Atlas product.

| Commit | Type | Summary |
| --- | --- | --- |
| `95d7fed1` | merge-fix | Restore upstream merge CI compatibility |
| `5187fbfe` | merge-fix | Restore upstream merge compile compatibility |
| `1851b26f` | merge-fix | Restore command palette focus test helper |
| `5c151be4` | merge-fix | Restore workspace creation test seams |
| `fb43b9bf` | merge-fix | Restore Git metadata test helpers |
| `f916d0d9` | merge-fix | Restore remote and snapshot test helpers |
| `ce6e055d` | merge-fix | Restore Ghostty config test helpers |
| `d48ad649` | merge-fix | Restore browser Return/IME seam |
| `fffd73ad` | merge-fix | Restore stale surface ownership guards |
| `21e8a1ae` | merge-fix | Quarantine stale inherited surfaces |

Notes:

- Some of these commits now protect real runtime behavior.
- Even so, they were introduced as merge repair, not as intentional Atlas differentiation.
- This is the bucket we should treat as evidence that the merge process itself needs to improve.

## 4. Release Markers

These commits are versioning markers, not feature work.

| Commit | Tag |
| --- | --- |
| `b0a69243` | `v0.62.2-atlas.2` |
| `b952c9be` | `v0.62.2-atlas.3` |
| `f7e89047` | `v0.62.2-atlas.4` |
| `a53d3f9f` | `v0.62.2-atlas.5` |
| `266aca27` | `v1.38.1-atlas.3` |
| `0b74eed2` | `v1.38.1-atlas.4` |

## 5. Merge Landmarks

These are important for history, but they are not feature commits.

| Commit | Summary |
| --- | --- |
| `00e58d58` | Merge upstream into Atlas fork on the older line |
| `b1d3b0dc` | Merge `upstream/main` into `review/upstream-sync-20260328` |
| `facbec05` | Merge review branch back into `main` |

## 6. How To Label Future Commits

Going forward, we should make the distinction explicit in commit messages.

Recommended prefixes:

- `feat(atlas): ...`
  - new Atlas-only product features
- `fix(atlas): ...`
  - user-facing Atlas bug fixes
- `ci(atlas): ...`
  - fork CI and release pipeline changes
- `fix(merge): ...`
  - merge-repair or migration-smoothing work only
- `docs(merge): ...`
  - merge-process documentation
- `release: ...`
  - version bumps and release markers only

Examples:

- `feat(atlas): add AI resume refresh command`
- `fix(atlas): restore relaunch session recovery`
- `fix(merge): restore stale surface ownership guards`
- `ci(atlas): add targeted merge validation workflow`

## 7. Practical Rule

When deciding whether a change should survive a fresh fork rebuild:

1. Carry all of section 1 by default.
2. Carry section 2 only if it is still operationally needed.
3. Re-evaluate section 3 from scratch rather than assuming it is intrinsically valuable.
