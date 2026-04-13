#!/usr/bin/env bash
# Atlas-specific test runner for cmux-atlas fork features.
#
# Usage:
#   ./scripts/test-atlas.sh                     # run all tiers
#   ./scripts/test-atlas.sh --shell             # shell wrapper tests only
#   ./scripts/test-atlas.sh --swift             # swift unit tests only
#   ./scripts/test-atlas.sh --socket --tag foo  # socket tests against tagged build
#   ./scripts/test-atlas.sh --tag foo           # all tiers with tag context

set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

RUN_SHELL=0
RUN_SWIFT=0
RUN_SOCKET=0
TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shell)  RUN_SHELL=1; shift ;;
        --swift)  RUN_SWIFT=1; shift ;;
        --socket) RUN_SOCKET=1; shift ;;
        --tag)    TAG="$2"; shift 2 ;;
        --tag=*)  TAG="${1#--tag=}"; shift ;;
        --all)    RUN_SHELL=1; RUN_SWIFT=1; RUN_SOCKET=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--shell] [--swift] [--socket] [--tag <tag>]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Default: run all tiers
if [[ "$RUN_SHELL" == "0" && "$RUN_SWIFT" == "0" && "$RUN_SOCKET" == "0" ]]; then
    RUN_SHELL=1
    RUN_SWIFT=1
    RUN_SOCKET=1
fi

PASSED=0
FAILED=0
SKIPPED=0
SHELL_PASSED=0
SHELL_FAILED=0
SWIFT_PASSED=0
SWIFT_FAILED=0
SOCKET_PASSED=0
SOCKET_FAILED=0
SOCKET_SKIPPED=0

run_python_test() {
    local test_file="$1"
    local tier="$2"
    local name
    name="$(basename "$test_file" .py)"

    printf "  %-45s " "$name"
    local output
    if output=$(python3 -m unittest "$test_file" 2>&1); then
        local count
        count=$(echo "$output" | grep -oE 'Ran [0-9]+ test' | grep -oE '[0-9]+' || echo "0")
        printf "\033[32m%s passed\033[0m\n" "$count"
        case "$tier" in
            shell)  SHELL_PASSED=$((SHELL_PASSED + count)); PASSED=$((PASSED + count)) ;;
            socket) SOCKET_PASSED=$((SOCKET_PASSED + count)); PASSED=$((PASSED + count)) ;;
        esac
    else
        local fail_count
        fail_count=$(echo "$output" | grep -oE 'failures=[0-9]+' | grep -oE '[0-9]+' || echo "1")
        local skip_count
        skip_count=$(echo "$output" | grep -oE 'skipped=[0-9]+' | grep -oE '[0-9]+' || echo "0")
        if [[ "$fail_count" == "0" && "$skip_count" -gt 0 ]]; then
            printf "\033[33m%s skipped\033[0m\n" "$skip_count"
            case "$tier" in
                socket) SOCKET_SKIPPED=$((SOCKET_SKIPPED + skip_count)); SKIPPED=$((SKIPPED + skip_count)) ;;
            esac
        else
            printf "\033[31mFAILED (%s)\033[0m\n" "$fail_count"
            echo "$output" | tail -20
            case "$tier" in
                shell)  SHELL_FAILED=$((SHELL_FAILED + fail_count)); FAILED=$((FAILED + fail_count)) ;;
                socket) SOCKET_FAILED=$((SOCKET_FAILED + fail_count)); FAILED=$((FAILED + fail_count)) ;;
            esac
        fi
    fi
}

# ── Tier 1: Shell Wrapper Tests ──

if [[ "$RUN_SHELL" == "1" ]]; then
    echo ""
    echo "=== Shell Wrapper Tests ==="
    for f in "$ROOT"/atlas-tests/shell/test_*.py; do
        [[ -f "$f" ]] || continue
        run_python_test "$f" shell
    done
fi

# ── Tier 2: Swift Unit Tests ──

if [[ "$RUN_SWIFT" == "1" ]]; then
    echo ""
    echo "=== Swift Unit Tests ==="
    printf "  %-45s " "AtlasFeatureTests"

    DERIVED_DATA="/tmp/cmux-atlas-test"
    if [[ -n "$TAG" ]]; then
        DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-atlas-$(slugify "$TAG")"
    fi

    swift_output=$(xcodebuild \
        -project "$ROOT/GhosttyTabs.xcodeproj" \
        -scheme cmux-unit \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -only-testing:cmuxTests/AtlasFeatureTests \
        test 2>&1) || true

    if echo "$swift_output" | grep -q "Test Suite.*passed"; then
        count=$(echo "$swift_output" | grep -oE 'Executed [0-9]+ test' | grep -oE '[0-9]+' | tail -1 || echo "0")
        printf "\033[32m%s passed\033[0m\n" "$count"
        SWIFT_PASSED=$((SWIFT_PASSED + count))
        PASSED=$((PASSED + count))
    elif echo "$swift_output" | grep -q "BUILD FAILED\|Test Suite.*failed"; then
        count=$(echo "$swift_output" | grep -oE '[0-9]+ failure' | grep -oE '[0-9]+' | head -1 || echo "1")
        printf "\033[31mFAILED\033[0m\n"
        echo "$swift_output" | grep -E "error:|failed|FAIL" | tail -10
        SWIFT_FAILED=$((SWIFT_FAILED + count))
        FAILED=$((FAILED + count))
    else
        printf "\033[33mSKIPPED\033[0m (add AtlasFeatureTests.swift to cmuxTests target in Xcode)\n"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ── Tier 3: Socket Tests ──

if [[ "$RUN_SOCKET" == "1" ]]; then
    echo ""
    echo "=== Socket Tests ==="

    # Discover CLI binary: /tmp/cmux-last-cli-path is the authoritative source
    # (written by reload.sh after every tagged build).
    CLI_PATH=""
    if [[ -f /tmp/cmux-last-cli-path ]]; then
        CLI_PATH="$(cat /tmp/cmux-last-cli-path 2>/dev/null || true)"
    fi
    # Fallback: tagged DerivedData path (matches reload.sh tagged_derived_data_path)
    if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]] && [[ -n "$TAG" ]]; then
        local_slug="$(slugify "$TAG")"
        CLI_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-atlas-${local_slug}/Build/Products/Debug/cmux"
        # Also check /tmp compatibility symlink
        if [[ ! -x "$CLI_PATH" ]]; then
            CLI_PATH="/tmp/cmux-${local_slug}/Build/Products/Debug/cmux"
        fi
    fi

    if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]]; then
        printf "  \033[33mSKIPPED (no CLI binary found)\033[0m\n"
        SOCKET_SKIPPED=$((SOCKET_SKIPPED + 1))
        SKIPPED=$((SKIPPED + 1))
    else
        export CMUX_CLI_BIN="$CLI_PATH"
        for f in "$ROOT"/atlas-tests/socket/test_*.py; do
            [[ -f "$f" ]] || { printf "  \033[33mNo socket tests found\033[0m\n"; break; }
            run_python_test "$f" socket
        done
    fi
fi

# ── Summary ──

echo ""
echo "=== Atlas Test Results ==="
[[ "$RUN_SHELL" == "1" ]]  && printf "Shell:   %d passed, %d failed\n" "$SHELL_PASSED" "$SHELL_FAILED"
[[ "$RUN_SWIFT" == "1" ]]  && printf "Swift:   %d passed, %d failed\n" "$SWIFT_PASSED" "$SWIFT_FAILED"
[[ "$RUN_SOCKET" == "1" ]] && printf "Socket:  %d passed, %d failed, %d skipped\n" "$SOCKET_PASSED" "$SOCKET_FAILED" "$SOCKET_SKIPPED"
printf "Total:   %d passed, %d failed, %d skipped\n" "$PASSED" "$FAILED" "$SKIPPED"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
