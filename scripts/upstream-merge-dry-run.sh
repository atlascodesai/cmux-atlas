#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/upstream-merge-dry-run.sh [--upstream-ref <ref>] [--fetch] [--keep-worktree]

Creates a temporary worktree from HEAD, attempts a no-commit merge from the
given upstream ref, and prints the conflicted files if the merge does not apply
cleanly.

Options:
  --upstream-ref <ref>  Upstream ref to merge. Default: upstream/main
  --fetch               Run `git fetch upstream main` before the dry run
  --keep-worktree       Keep the temporary worktree on disk for inspection
  -h, --help            Show this help

Notes:
  - This script requires a clean working tree in the main repo.
  - The merge happens only inside a temporary worktree.
EOF
}

upstream_ref="upstream/main"
should_fetch=0
keep_worktree=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-ref)
      upstream_ref="${2:?missing value for --upstream-ref}"
      shift 2
      ;;
    --fetch)
      should_fetch=1
      shift
      ;;
    --keep-worktree)
      keep_worktree=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree is dirty. Commit or stash changes before running this script." >&2
  exit 1
fi

if [[ "$should_fetch" -eq 1 ]]; then
  git fetch upstream main
fi

git rev-parse --verify "$upstream_ref" >/dev/null

worktree_path="$(mktemp -d "${TMPDIR:-/tmp}/cmux-upstream-merge-check.XXXXXX")"

cleanup() {
  if [[ "$keep_worktree" -eq 1 ]]; then
    echo
    echo "Kept merge-check worktree:"
    echo "  $worktree_path"
    return
  fi
  git worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "$worktree_path" HEAD >/dev/null

echo "Merge-check worktree: $worktree_path"
echo "Merging $upstream_ref into detached HEAD at $(git rev-parse --short HEAD) ..."

set +e
merge_output="$(git -C "$worktree_path" merge --no-commit --no-ff "$upstream_ref" 2>&1)"
merge_status=$?
set -e

if [[ "$merge_status" -eq 0 ]]; then
  echo "Dry merge applied cleanly."
  exit 0
fi

echo "$merge_output"
echo
echo "Conflicted files:"
conflicted_files="$(git -C "$worktree_path" diff --name-only --diff-filter=U)"
printf '%s\n' "$conflicted_files" | sed 's/^/  /'

conflict_count="$(printf '%s\n' "$conflicted_files" | wc -l | tr -d ' ')"
echo
echo "Conflict count: $conflict_count"

mechanical_conflicts=(
  ".github/workflows/build-ghosttykit.yml"
  ".github/workflows/ci-macos-compat.yml"
  ".github/workflows/ci.yml"
  "scripts/reload.sh"
  "tests/test_ci_self_hosted_guard.sh"
)

for file in "${mechanical_conflicts[@]}"; do
  if printf '%s\n' "$conflicted_files" | grep -Fxq "$file"; then
    echo
    echo "Mechanical Atlas policy conflicts detected."
    echo "During a real merge, you can pre-resolve them with:"
    echo "  ./scripts/upstream-merge-apply-atlas-overrides.sh"
    break
  fi
done
exit 1
