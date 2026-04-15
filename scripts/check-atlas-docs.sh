#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  exit 0
fi

staged_files=()
while IFS= read -r line; do
  staged_files+=("$line")
done < <(git diff --cached --name-only --diff-filter=ACMR)

if [[ ${#staged_files[@]} -eq 0 ]]; then
  exit 0
fi

devlog_files=()
for path in "${staged_files[@]}"; do
  if [[ "$path" == atlas-docs/devlog/*.md ]]; then
    devlog_files+=("$path")
  fi
done

if [[ ${#devlog_files[@]} -eq 0 ]]; then
  cat <<'EOF'
Commit blocked: stage a devlog update under atlas-docs/devlog/.

Expected workflow:
  ./scripts/atlas-devlog.sh add "Short summary of what this commit delivers" --docs "none needed"
  git add atlas-docs/devlog/YYYY-MM.md
EOF
  exit 1
fi

for file in "${devlog_files[@]}"; do
  diff_text="$(git diff --cached --unified=0 -- "$file")"

  if ! grep -Eq '^\+.*- Delivery:' <<<"$diff_text"; then
    cat <<EOF
Commit blocked: $file does not include a newly added '- Delivery:' line.
Use ./scripts/atlas-devlog.sh add ... to append a proper entry.
EOF
    exit 1
  fi

  if ! grep -Eq '^\+.*- Canonical docs reviewed:' <<<"$diff_text"; then
    cat <<EOF
Commit blocked: $file does not include a newly added '- Canonical docs reviewed:' line.
EOF
    exit 1
  fi

  if ! grep -Eq '^\+.*- Canonical docs updates:' <<<"$diff_text"; then
    cat <<EOF
Commit blocked: $file does not include a newly added '- Canonical docs updates:' line.
EOF
    exit 1
  fi

  if grep -Eq '^\+.*PENDING' <<<"$diff_text"; then
    cat <<EOF
Commit blocked: $file still has a PENDING docs review marker.
Replace it with 'none needed' or list the canonical docs you updated.
EOF
    exit 1
  fi
done
