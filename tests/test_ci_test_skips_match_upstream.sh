#!/usr/bin/env bash
# Guard test: ensures our fork's unit test skip list and expected-failure
# handling match upstream exactly.
#
# Upstream skips one test and uses a "(0 unexpected)" check to treat
# XCTExpectFailure failures as a pass. If upstream changes their skips
# or handling, this test will fail and flag the drift.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

# ---------------------------------------------------------------------------
# 1. Verify the exact set of -skip-testing entries in the tests job matches
#    upstream. Upstream skips exactly one test:
# ---------------------------------------------------------------------------
EXPECTED_SKIPS=(
  "cmuxTests/AppDelegateShortcutRoutingTests/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace"
  "cmuxTests/AppDelegateShortcutRoutingTests/testCustomCmdTNewWorkspacePrunesOrphanedContextWithoutLiveWindow"
)

# Extract all -skip-testing values from the "Run unit tests" step in ci.yml
ACTUAL_SKIPS=()
while IFS= read -r line; do
  ACTUAL_SKIPS+=("$line")
done < <(grep -oE '\-skip-testing:[^ ]+' "$WORKFLOW_FILE" | sed 's/-skip-testing://' | sort -u)

if [ "${#ACTUAL_SKIPS[@]}" -ne "${#EXPECTED_SKIPS[@]}" ]; then
  echo "FAIL: Expected ${#EXPECTED_SKIPS[@]} skip-testing entries, found ${#ACTUAL_SKIPS[@]}"
  echo "  Expected: ${EXPECTED_SKIPS[*]}"
  echo "  Actual:   ${ACTUAL_SKIPS[*]}"
  exit 1
fi

for i in "${!EXPECTED_SKIPS[@]}"; do
  if [ "${ACTUAL_SKIPS[$i]}" != "${EXPECTED_SKIPS[$i]}" ]; then
    echo "FAIL: Skip mismatch at index $i"
    echo "  Expected: ${EXPECTED_SKIPS[$i]}"
    echo "  Actual:   ${ACTUAL_SKIPS[$i]}"
    exit 1
  fi
done

echo "PASS: test skip list matches upstream (${#EXPECTED_SKIPS[@]} skip(s))"

# ---------------------------------------------------------------------------
# 2. Verify the "(0 unexpected)" expected-failure pass-through is present
# ---------------------------------------------------------------------------
if ! grep -Fq '(0 unexpected)' "$WORKFLOW_FILE"; then
  echo "FAIL: Missing '(0 unexpected)' expected-failure handling in $WORKFLOW_FILE"
  echo "  Upstream treats xcodebuild failures with 0 unexpected as a pass."
  echo "  This check must be present so XCTExpectFailure tests don't break CI."
  exit 1
fi

if ! grep -Fq 'All failures are expected, treating as pass' "$WORKFLOW_FILE"; then
  echo "FAIL: Missing 'All failures are expected' message in $WORKFLOW_FILE"
  exit 1
fi

echo "PASS: expected-failure pass-through handling is present"
