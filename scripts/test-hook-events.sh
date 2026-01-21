#!/bin/bash
# Test script for hud-state-tracker.sh
# Exercises all hook events and verifies v2 format output
#
# Usage: ./scripts/test-hook-events.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hud-state-tracker.sh"

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

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required but not installed${NC}"
        echo "Install with: brew install jq"
        exit 1
    fi
}

send_event() {
    local json="$1"
    echo "$json" | "$HOOK_SCRIPT"
}

get_state() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        jq -r ".sessions[\"$session_id\"].state // empty" "$state_file"
    fi
}

get_session() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        jq ".sessions[\"$session_id\"] // null" "$state_file"
    fi
}

session_exists() {
    local session_id="$1"
    local state_file="$HOME/.capacitor/sessions.json"
    if [ -f "$state_file" ]; then
        local result
        result=$(jq ".sessions[\"$session_id\"]" "$state_file")
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

check_jq

# Test 1: SessionStart → ready
echo "Test 1: SessionStart event"
send_event '{"hook_event_name":"SessionStart","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "SessionStart → ready"
else
    fail "SessionStart → ready" "ready" "$STATE"
fi

# Test 2: Version is 2
echo "Test 2: State file version"
VERSION=$(check_version)
if [ "$VERSION" = "2" ]; then
    pass "Version is 2"
else
    fail "Version is 2" "2" "$VERSION"
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

# Test 6: PermissionRequest → blocked
echo "Test 6: PermissionRequest event"
send_event '{"hook_event_name":"PermissionRequest","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "blocked" ]; then
    pass "PermissionRequest → blocked"
else
    fail "PermissionRequest → blocked" "blocked" "$STATE"
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

# Test 14: No PID in output
echo "Test 14: No PID field in session record"
SESSION=$(get_session "session-a")
if echo "$SESSION" | jq -e '.pid' > /dev/null 2>&1; then
    fail "No PID field" "no pid field" "pid field present"
else
    pass "No PID field"
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

# Test 16: Missing cwd with fallback
echo "Test 16: Missing cwd uses PWD fallback"
export CLAUDE_PROJECT_DIR="/fallback/project"
send_event '{"hook_event_name":"SessionStart","session_id":"fallback-test"}'
SESSION=$(get_session "fallback-test")
CWD=$(echo "$SESSION" | jq -r '.cwd')
unset CLAUDE_PROJECT_DIR
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
