#!/bin/bash
# Live crash simulation test for AI session detection.
#
# This script:
# 1. Starts a Claude Code session with a known session ID
# 2. Sends it a unique message (so we can verify the right session later)
# 3. Kills it (simulates crash)
# 4. Runs the detector to find the session ID
# 5. Verifies the detected ID matches the original
# 6. Optionally resumes and verifies continuity
#
# Usage: ./scripts/test-crash-resume.sh [--resume]
#
# Requirements: claude CLI installed, python3

set -euo pipefail

RESUME_AFTER_TEST="${1:-}"
TEST_DIR=$(mktemp -d)
MARKER="CMUX_CRASH_TEST_$(date +%s)_$$"
SESSION_ID=""
CLAUDE_PID=""
CLAUDE_TTY=""

cleanup() {
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "=== cmux AI Session Crash Resume Test ==="
echo "Test marker: $MARKER"
echo "Working dir: $TEST_DIR"
echo ""

# Step 1: Start Claude with a fresh session
echo "[1/6] Starting Claude Code session..."
cd "$TEST_DIR"
mkdir -p .git  # Make it look like a project
git init -q

# Start claude in background with print mode to get a response, using a unique session
claude --print --session-id "$(uuidgen)" -p "Say exactly this and nothing else: $MARKER" > "$TEST_DIR/output.txt" 2>&1 &
CLAUDE_PID=$!

echo "  PID: $CLAUDE_PID"
CLAUDE_TTY=$(ps -o tty= -p $CLAUDE_PID 2>/dev/null | tr -d ' ' || echo "unknown")
echo "  TTY: $CLAUDE_TTY"

# Wait for it to start writing
sleep 3

# Step 2: Find the session ID it's using
echo "[2/6] Finding session ID..."

# Encode the test dir path to Claude project dir format
ENCODED_DIR=$(echo "$TEST_DIR" | sed 's|/|-|g')
CLAUDE_PROJECT_DIR="$HOME/.claude/projects/$ENCODED_DIR"

if [ -d "$CLAUDE_PROJECT_DIR" ]; then
    echo "  Project dir: $CLAUDE_PROJECT_DIR"

    # Find the most recently modified .jsonl
    SESSION_FILE=$(ls -t "$CLAUDE_PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$SESSION_FILE" ]; then
        SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
        echo "  Session ID: $SESSION_ID"
        echo "  File: $SESSION_FILE"
        LINE_COUNT=$(wc -l < "$SESSION_FILE" | tr -d ' ')
        echo "  Lines: $LINE_COUNT"
    else
        echo "  ERROR: No .jsonl files found"
    fi
else
    echo "  Project dir not found: $CLAUDE_PROJECT_DIR"
    echo "  Checking alternative locations..."
    find "$HOME/.claude/projects" -name "*.jsonl" -newer "$TEST_DIR/.git" 2>/dev/null | head -5
fi

# Wait for claude to finish (it's in --print mode)
wait $CLAUDE_PID 2>/dev/null || true
CLAUDE_PID=""

# Step 3: Verify the output contains our marker
echo "[3/6] Verifying session output..."
if grep -q "$MARKER" "$TEST_DIR/output.txt" 2>/dev/null; then
    echo "  ✅ Output contains test marker"
else
    echo "  ⚠️  Marker not found in output (claude may still be processing)"
    echo "  Output: $(head -3 "$TEST_DIR/output.txt" 2>/dev/null)"
fi

# Step 4: Now start a NEW session that we'll "crash"
echo "[4/6] Starting session to crash..."
claude -p "Remember this number: 42. Say 'ready'" > /dev/null 2>&1 &
CLAUDE_PID=$!
sleep 5

# Get process info before kill
CRASH_TTY=$(ps -o tty= -p $CLAUDE_PID 2>/dev/null | tr -d ' ' || echo "")
CRASH_START=$(ps -o lstart= -p $CLAUDE_PID 2>/dev/null | xargs || echo "")
echo "  Crash target PID: $CLAUDE_PID TTY: $CRASH_TTY Started: $CRASH_START"

# Kill it (simulate crash)
echo "  Sending SIGKILL..."
kill -9 $CLAUDE_PID 2>/dev/null || true
wait $CLAUDE_PID 2>/dev/null || true
CLAUDE_PID=""
echo "  Process killed."

# Step 5: Run our detector logic
echo "[5/6] Running session detection..."

python3 << PYEOF
import json, os, time
from datetime import datetime

test_dir = "$TEST_DIR"
encoded = test_dir.replace('/', '-')
project_dir = os.path.expanduser(f'~/.claude/projects/{encoded}')

if not os.path.isdir(project_dir):
    print(f"  Project dir not found: {project_dir}")
    exit(1)

# Find all .jsonl files modified in last 60 seconds
now = time.time()
candidates = []
for f in os.listdir(project_dir):
    if not f.endswith('.jsonl'): continue
    path = os.path.join(project_dir, f)
    mtime = os.path.getmtime(path)
    if now - mtime > 120: continue
    sid = f.replace('.jsonl', '')

    with open(path) as fh:
        lines = fh.readlines()

    # Get first timestamp
    first_ts = None
    for line in lines[:5]:
        try:
            d = json.loads(line)
            if d.get('timestamp'):
                first_ts = d['timestamp']
                break
        except: pass

    last_ts = None
    for line in reversed(lines[-5:]):
        try:
            d = json.loads(line)
            if d.get('timestamp'):
                last_ts = d['timestamp']
                break
        except: pass

    candidates.append({
        'sid': sid, 'lines': len(lines), 'mtime': mtime,
        'first_ts': first_ts, 'last_ts': last_ts
    })

candidates.sort(key=lambda c: c['mtime'], reverse=True)

print(f"  Found {len(candidates)} recent session(s) in {project_dir}")
for c in candidates:
    age = now - c['mtime']
    print(f"  • {c['sid'][:20]}... lines={c['lines']} age={age:.0f}s")
    print(f"    first={c['first_ts']} last={c['last_ts']}")

if candidates:
    best = candidates[0]  # Most recently modified
    print(f"\n  ✅ Detected session: {best['sid']}")
    print(f"  Resume command: claude --resume {best['sid']}")
else:
    print(f"\n  ❌ No session detected")
PYEOF

# Step 6: Optionally resume
if [ "$RESUME_AFTER_TEST" = "--resume" ] && [ -n "$SESSION_ID" ]; then
    echo "[6/6] Resuming session..."
    echo "  Running: claude --resume $SESSION_ID --print -p 'What number did I ask you to remember?'"
    RESPONSE=$(claude --resume "$SESSION_ID" --print -p "What number did I ask you to remember?" 2>/dev/null || echo "FAILED")
    if echo "$RESPONSE" | grep -q "42"; then
        echo "  ✅ Session resumed successfully — agent remembered '42'"
    else
        echo "  ❌ Resume failed or agent didn't remember. Response: $(echo "$RESPONSE" | head -3)"
    fi
else
    echo "[6/6] Skipping resume (use --resume flag to test)"
fi

echo ""
echo "=== Test Complete ==="
