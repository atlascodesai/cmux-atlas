#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build|unit|ui-regressions|compat> [ref] [ui_test_filter]" >&2
  exit 1
fi

LANE="$1"
REF="${2:-$(git rev-parse --abbrev-ref HEAD)}"
UI_TEST_FILTER="${3:-DisplayResolutionRegressionUITests}"
WORKFLOW="merge-validation.yml"
REPO="${GITHUB_REPOSITORY_OVERRIDE:-atlas-fork/cmux-atlas}"

ARGS=(-f "lane=$LANE" -f "ref=$REF")
if [[ "$LANE" == "ui-regressions" ]]; then
  ARGS+=(-f "ui_test_filter=$UI_TEST_FILTER")
fi

gh workflow run "$WORKFLOW" --repo "$REPO" "${ARGS[@]}"

echo "Waiting for workflow run to register..."
sleep 5

RUN_ID="$(
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 10 --json databaseId,createdAt,status \
    --jq 'sort_by(.createdAt) | reverse | .[0].databaseId'
)"

if [[ -z "${RUN_ID:-}" || "$RUN_ID" == "null" ]]; then
  echo "Could not determine merge-validation run id" >&2
  exit 1
fi

echo "Watching run $RUN_ID"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status
