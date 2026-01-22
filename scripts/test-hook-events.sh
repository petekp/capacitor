#!/bin/bash
# Test script for hud-state-tracker.sh
# Exercises all hook events and verifies v3 format output
#
# Usage: ./scripts/test-hook-events.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hud-state-tracker.sh"

HAVE_JQ=""
HAVE_PY=""
command -v jq >/dev/null 2>&1 && HAVE_JQ="1"
command -v python3 >/dev/null 2>&1 && HAVE_PY="1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Override HOME for testing
export HOME="/tmp/test-capacitor-$$"
mkdir -p "$HOME/.capacitor"

PASSED=0
FAILED=0

cleanup() {
    rm -rf "$HOME"
}
trap cleanup EXIT

pass() {
    echo -e "${GREEN}✓ $1${NC}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}✗ $1${NC}"
    echo -e "${YELLOW}  Expected: $2${NC}"
    echo -e "${YELLOW}  Got: $3${NC}"
    FAILED=$((FAILED + 1))
}

check_json_parser() {
    if [ -z "$HAVE_JQ" ] && [ -z "$HAVE_PY" ]; then
        echo -e "${RED}Error: jq or python3 is required but not installed${NC}"
        echo "Install with: brew install jq (or ensure python3 is available)"
        exit 1
    fi
}

hash_path() {
    local path="$1"
    if command -v md5 >/dev/null 2>&1; then
        md5 -q -s "$path"
        return 0
    fi
    if command -v md5sum >/dev/null 2>&1; then
        echo -n "$path" | md5sum | cut -d' ' -f1
        return 0
    fi
    echo ""
}

wait_for_lock() {
    local lock_path="$1"
    local attempts=20
    local i=0
    while [ $i -lt $attempts ]; do
        if [ -d "$lock_path" ]; then
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

send_event() {
    local json="$1"
    echo "$json" | "$HOOK_SCRIPT"
}

get_state() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        if [ -n "$HAVE_JQ" ]; then
            jq -r ".sessions[\"$session_id\"].state // empty" "$state_file"
        else
            python3 - "$state_file" "$session_id" <<'PY'
import json
import sys

path, sid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
print(data.get("sessions", {}).get(sid, {}).get("state", ""))
PY
        fi
    fi
}

get_session() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        if [ -n "$HAVE_JQ" ]; then
            jq ".sessions[\"$session_id\"] // null" "$state_file"
        else
            python3 - "$state_file" "$session_id" <<'PY'
import json
import sys

path, sid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    print("null")
    sys.exit(0)
session = data.get("sessions", {}).get(sid)
if session is None:
    print("null")
else:
    print(json.dumps(session))
PY
        fi
    fi
}

session_exists() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        local result
        result=$(get_session "$session_id")
        [ "$result" != "null" ]
    else
        return 1
    fi
}

check_version() {
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        jq -r ".version" "$state_file"
    fi
}

echo "=== Claude HUD Hook Event Tests ==="
echo ""

check_json_parser

# Test 1: SessionStart → ready
echo "Test 1: SessionStart event"
send_event '{"hook_event_name":"SessionStart","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "SessionStart → ready"
else
    fail "SessionStart → ready" "ready" "$STATE"
fi

# Test 1b: SessionStart creates lock
echo "Test 1b: SessionStart lock creation"
LOCK_HASH=$(hash_path "/test/project")
if [ -z "$LOCK_HASH" ]; then
    echo -e "${YELLOW}Skipping lock test: md5 not available${NC}"
else
    LOCK_PATH="$HOME/.capacitor/sessions/${LOCK_HASH}.lock"
    if wait_for_lock "$LOCK_PATH"; then
        pass "SessionStart → lock created"
    else
        fail "SessionStart → lock created" "$LOCK_PATH exists" "missing"
    fi
fi

# Test 2: Version is 3
echo "Test 2: State file version"
VERSION=$(check_version)
if [ "$VERSION" = "3" ]; then
    pass "Version is 3"
else
    fail "Version is 3" "3" "$VERSION"
fi

# Test 3: UserPromptSubmit → working
echo "Test 3: UserPromptSubmit event"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "working" ]; then
    pass "UserPromptSubmit → working"
else
    fail "UserPromptSubmit → working" "working" "$STATE"
fi

# Test 4: PreToolUse → working
echo "Test 4: PreToolUse event"
send_event '{"hook_event_name":"PreToolUse","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "working" ]; then
    pass "PreToolUse → working"
else
    fail "PreToolUse → working" "working" "$STATE"
fi

# Test 5: PostToolUse → working
echo "Test 5: PostToolUse event"
send_event '{"hook_event_name":"PostToolUse","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "working" ]; then
    pass "PostToolUse → working"
else
    fail "PostToolUse → working" "working" "$STATE"
fi

# Test 6: PermissionRequest → waiting
echo "Test 6: PermissionRequest event"
send_event '{"hook_event_name":"PermissionRequest","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "waiting" ]; then
    pass "PermissionRequest → waiting"
else
    fail "PermissionRequest → waiting" "waiting" "$STATE"
fi

# Test 7: Stop → ready
echo "Test 7: Stop event"
send_event '{"hook_event_name":"Stop","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "Stop → ready"
else
    fail "Stop → ready" "ready" "$STATE"
fi

# Test 8: Notification (idle_prompt) → ready
echo "Test 8: Notification (idle_prompt) event"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'  # Set to working first
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"idle_prompt"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "Notification (idle_prompt) → ready"
else
    fail "Notification (idle_prompt) → ready" "ready" "$STATE"
fi

# Test 9: Notification (other) → no change
echo "Test 9: Notification (other) event - should not change state"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'  # Set to working
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"task_complete"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "working" ]; then
    pass "Notification (other) → no change"
else
    fail "Notification (other) → no change" "working" "$STATE"
fi

# Test 10: PreCompact (auto) → compacting
echo "Test 10: PreCompact (auto) event"
send_event '{"hook_event_name":"PreCompact","session_id":"test-1","cwd":"/test/project","trigger":"auto"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "compacting" ]; then
    pass "PreCompact (auto) → compacting"
else
    fail "PreCompact (auto) → compacting" "compacting" "$STATE"
fi

# Test 11: PreCompact (manual) → no change
echo "Test 11: PreCompact (manual) event - should not change state"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'
send_event '{"hook_event_name":"PreCompact","session_id":"test-1","cwd":"/test/project","trigger":"manual"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "working" ]; then
    pass "PreCompact (manual) → no change"
else
    fail "PreCompact (manual) → no change" "working" "$STATE"
fi

# Test 12: SessionEnd → session deleted
echo "Test 12: SessionEnd event - should delete session"
send_event '{"hook_event_name":"SessionEnd","session_id":"test-1","cwd":"/test/project"}'
if ! session_exists "test-1"; then
    pass "SessionEnd → session deleted"
else
    fail "SessionEnd → session deleted" "session removed" "session still exists"
fi

# Test 13: Multiple sessions
echo "Test 13: Multiple concurrent sessions"
send_event '{"hook_event_name":"SessionStart","session_id":"session-a","cwd":"/project/a"}'
send_event '{"hook_event_name":"SessionStart","session_id":"session-b","cwd":"/project/b"}'
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"session-a","cwd":"/project/a"}'
STATE_A=$(get_state "session-a")
STATE_B=$(get_state "session-b")
if [ "$STATE_A" = "working" ] && [ "$STATE_B" = "ready" ]; then
    pass "Multiple sessions tracked independently"
else
    fail "Multiple sessions tracked independently" "session-a=working, session-b=ready" "session-a=$STATE_A, session-b=$STATE_B"
fi

# Test 14: v3 fields present in session record (state_changed_at, last_event)
echo "Test 14: v3 fields present in session record"
SESSION=$(get_session "session-a")
STATE_CHANGED_AT=$(echo "$SESSION" | jq -r '.state_changed_at // empty')
LAST_EVENT=$(echo "$SESSION" | jq -r '.last_event.event // empty')
if [ -n "$STATE_CHANGED_AT" ] && [ -n "$LAST_EVENT" ]; then
    pass "v3 fields present (state_changed_at, last_event)"
else
    fail "v3 fields present" "state_changed_at and last_event" "state_changed_at=$STATE_CHANGED_AT, last_event=$LAST_EVENT"
fi

# Test 15: Missing session_id - should exit gracefully
echo "Test 15: Missing session_id - graceful exit"
# Temporarily disable set -e for this test
set +e
send_event '{"hook_event_name":"SessionStart","cwd":"/test/project"}' 2>/dev/null
EXIT_CODE=$?
set -e
if [ $EXIT_CODE -eq 0 ]; then
    pass "Missing session_id handled gracefully"
else
    fail "Missing session_id handled gracefully" "exit 0" "exit $EXIT_CODE"
fi

# Test 16: Missing cwd uses CLAUDE_PROJECT_DIR fallback
echo "Test 16: Missing cwd uses CLAUDE_PROJECT_DIR fallback"
export CLAUDE_PROJECT_DIR="/fallback/project"
send_event '{"hook_event_name":"SessionStart","session_id":"fallback-test"}'
SESSION=$(get_session "fallback-test")
CWD=$(echo "$SESSION" | jq -r '.cwd')
unset CLAUDE_PROJECT_DIR
if [ "$CWD" = "/fallback/project" ]; then
    pass "CLAUDE_PROJECT_DIR fallback works"
else
    fail "CLAUDE_PROJECT_DIR fallback" "/fallback/project" "$CWD"
fi

# Test 17: Missing cwd falls back to PWD when env is unset
echo "Test 17: Missing cwd uses PWD fallback"
send_event '{"hook_event_name":"SessionStart","session_id":"pwd-fallback"}'
SESSION=$(get_session "pwd-fallback")
CWD=$(echo "$SESSION" | jq -r '.cwd')
if [ "$CWD" = "$PWD" ]; then
    pass "PWD fallback works"
else
    fail "PWD fallback" "$PWD" "$CWD"
fi

echo ""
echo "=== Results ==="
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"

if [ $FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi
