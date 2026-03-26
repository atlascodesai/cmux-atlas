#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/upstream-merge-apply-atlas-overrides.sh

During an in-progress upstream merge, restore the Atlas policy files to our side
for the files where runner/socket/reload behavior is intentionally fork-specific.

This script resolves the mechanical files to `--ours` and stages them. It does
not attempt to re-apply new upstream jobs or steps; use the merge guide for the
manual follow-up.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

git rev-parse -q --verify MERGE_HEAD >/dev/null || {
  echo "No merge in progress." >&2
  exit 1
}

files=(
  ".github/workflows/build-ghosttykit.yml"
  ".github/workflows/ci-macos-compat.yml"
  ".github/workflows/ci.yml"
  "scripts/reload.sh"
  "tests/test_ci_self_hosted_guard.sh"
)

for file in "${files[@]}"; do
  if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    git checkout --ours -- "$file"
    git add "$file"
    echo "resolved to ours: $file"
  fi
done

cat <<'EOF'

Next:
  1. Re-apply any new upstream jobs/steps you still want in the workflow files.
  2. Re-run the dry merge guide for the remaining source conflicts.
  3. Build with a tagged reload before finalizing the merge.
EOF
