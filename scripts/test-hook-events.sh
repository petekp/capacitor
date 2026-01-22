#!/bin/bash
# Test script for hud-state-tracker.sh
# Exercises all hook events and verifies v3 format output
#
# Usage: ./scripts/test-hook-events.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hud-state-tracker.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for this test script"
    echo "Install with: brew install jq"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Override HOME for testing (so we don't touch real ~/.capacitor)
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

send_event() {
    local json="$1"
    echo "$json" | "$HOOK_SCRIPT" >/dev/null 2>&1
}

state_file() {
    echo "$HOME/.capacitor/sessions.json"
}

get_version() {
    local file
    file="$(state_file)"
    [ -f "$file" ] || return 0
    jq -r ".version // empty" "$file"
}

get_state() {
    local session_id="$1"
    local file
    file="$(state_file)"
    [ -f "$file" ] || return 0
    jq -r ".sessions[\"$session_id\"].state // empty" "$file"
}

get_field() {
    local session_id="$1"
    local field_path="$2" # e.g. "state_changed_at", "last_event.hook_event_name"
    local file
    file="$(state_file)"
    [ -f "$file" ] || return 0
    jq -r ".sessions[\"$session_id\"].${field_path} // empty" "$file"
}

has_key() {
    local session_id="$1"
    local key="$2"
    local file
    file="$(state_file)"
    [ -f "$file" ] || {
        echo "false"
        return 0
    }
    jq -r ".sessions[\"$session_id\"] | has(\"$key\")" "$file"
}

session_exists() {
    local session_id="$1"
    local file
    file="$(state_file)"
    [ -f "$file" ] || return 1
    jq -e ".sessions[\"$session_id\"] != null" "$file" >/dev/null 2>&1
}

echo "=== Claude HUD Hook Event Tests (v3) ==="
echo ""

# Test 1: SessionStart → ready
echo "Test 1: SessionStart event"
send_event '{"hook_event_name":"SessionStart","session_id":"test-1","cwd":"/test/project","transcript_path":"~/.claude/test.jsonl","permission_mode":"default","source":"startup"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "SessionStart → ready"
else
    fail "SessionStart → ready" "ready" "$STATE"
fi

# Test 2: Version is 3
echo "Test 2: State file version"
VERSION=$(get_version)
if [ "$VERSION" = "3" ]; then
    pass "Version is 3"
else
    fail "Version is 3" "3" "$VERSION"
fi

# Test 3: v3 schema fields present
echo "Test 3: v3 schema fields present"
UPDATED_AT=$(get_field "test-1" "updated_at")
STATE_CHANGED_AT=$(get_field "test-1" "state_changed_at")
LAST_EVENT=$(get_field "test-1" "last_event.hook_event_name")
if [ -n "$UPDATED_AT" ] && [ -n "$STATE_CHANGED_AT" ] && [ "$LAST_EVENT" = "SessionStart" ]; then
    pass "Record includes updated_at, state_changed_at, last_event"
else
    fail "Record includes updated_at, state_changed_at, last_event" "non-empty fields + last_event=SessionStart" "updated_at=$UPDATED_AT state_changed_at=$STATE_CHANGED_AT last_event=$LAST_EVENT"
fi

# Test 4: UserPromptSubmit → working (and denylist: prompt is not persisted)
echo "Test 4: UserPromptSubmit event"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project","prompt":"SECRET-PROMPT"}'
STATE=$(get_state "test-1")
HAS_PROMPT=$(has_key "test-1" "prompt")
if [ "$STATE" = "working" ] && [ "$HAS_PROMPT" = "false" ]; then
    pass "UserPromptSubmit → working (prompt not persisted)"
else
    fail "UserPromptSubmit → working (prompt not persisted)" "state=working and no prompt key" "state=$STATE prompt_key=$HAS_PROMPT"
fi

# Test 5: PreToolUse → working (captures tool metadata)
echo "Test 5: PreToolUse event"
send_event '{"hook_event_name":"PreToolUse","session_id":"test-1","cwd":"/test/project","tool_name":"Bash","tool_use_id":"toolu_123","tool_input":{"cmd":"echo hi"}}'
STATE=$(get_state "test-1")
TOOL_NAME=$(get_field "test-1" "last_event.tool_name")
TOOL_USE_ID=$(get_field "test-1" "last_event.tool_use_id")
HAS_TOOL_INPUT=$(has_key "test-1" "tool_input")
if [ "$STATE" = "working" ] && [ "$TOOL_NAME" = "Bash" ] && [ "$TOOL_USE_ID" = "toolu_123" ] && [ "$HAS_TOOL_INPUT" = "false" ]; then
    pass "PreToolUse → working (tool metadata captured; tool_input not persisted)"
else
    fail "PreToolUse → working (tool metadata captured; tool_input not persisted)" "state=working tool_name=Bash tool_use_id=toolu_123 no tool_input key" "state=$STATE tool_name=$TOOL_NAME tool_use_id=$TOOL_USE_ID tool_input_key=$HAS_TOOL_INPUT"
fi

# Test 6: PermissionRequest → waiting
echo "Test 6: PermissionRequest event"
send_event '{"hook_event_name":"PermissionRequest","session_id":"test-1","cwd":"/test/project","tool_name":"Bash"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "waiting" ]; then
    pass "PermissionRequest → waiting"
else
    fail "PermissionRequest → waiting" "waiting" "$STATE"
fi

# Test 7: Notification (idle_prompt) → ready
echo "Test 7: Notification (idle_prompt) event"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'  # Set to working first
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"idle_prompt","message":"ignored"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "Notification (idle_prompt) → ready"
else
    fail "Notification (idle_prompt) → ready" "ready" "$STATE"
fi

# Test 8: Notification (permission_prompt) → waiting
echo "Test 8: Notification (permission_prompt) event"
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"permission_prompt"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "waiting" ]; then
    pass "Notification (permission_prompt) → waiting"
else
    fail "Notification (permission_prompt) → waiting" "waiting" "$STATE"
fi

# Test 9: Notification (elicitation_dialog) → waiting
echo "Test 9: Notification (elicitation_dialog) event"
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"elicitation_dialog"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "waiting" ]; then
    pass "Notification (elicitation_dialog) → waiting"
else
    fail "Notification (elicitation_dialog) → waiting" "waiting" "$STATE"
fi

# Test 10: Notification (other) → no state change, but last_event updates
echo "Test 10: Notification (other) event - should not change state"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'  # Set to working
send_event '{"hook_event_name":"Notification","session_id":"test-1","cwd":"/test/project","notification_type":"task_complete","message":"ignored"}'
STATE=$(get_state "test-1")
NOTIF=$(get_field "test-1" "last_event.notification_type")
HAS_MESSAGE=$(has_key "test-1" "message")
if [ "$STATE" = "working" ] && [ "$NOTIF" = "task_complete" ] && [ "$HAS_MESSAGE" = "false" ]; then
    pass "Notification (other) → no change (metadata captured; message not persisted)"
else
    fail "Notification (other) → no change (metadata captured; message not persisted)" "state=working last_event.notification_type=task_complete no message key" "state=$STATE notif=$NOTIF message_key=$HAS_MESSAGE"
fi

# Test 11: Stop (stop_hook_active=true) → no state change
echo "Test 11: Stop (stop_hook_active=true) - should not force ready"
send_event '{"hook_event_name":"UserPromptSubmit","session_id":"test-1","cwd":"/test/project"}'  # working
send_event '{"hook_event_name":"Stop","session_id":"test-1","stop_hook_active":true}'
STATE=$(get_state "test-1")
STOP_ACTIVE=$(get_field "test-1" "last_event.stop_hook_active")
if [ "$STATE" = "working" ] && [ "$STOP_ACTIVE" = "true" ]; then
    pass "Stop(stop_hook_active=true) → no change"
else
    fail "Stop(stop_hook_active=true) → no change" "state=working stop_hook_active=true" "state=$STATE stop_hook_active=$STOP_ACTIVE"
fi

# Test 12: Stop (stop_hook_active=false) → ready
echo "Test 12: Stop (stop_hook_active=false) event"
send_event '{"hook_event_name":"Stop","session_id":"test-1","cwd":"/test/project","stop_hook_active":false}'
STATE=$(get_state "test-1")
if [ "$STATE" = "ready" ]; then
    pass "Stop → ready"
else
    fail "Stop → ready" "ready" "$STATE"
fi

# Test 13: PreCompact (auto) → compacting
echo "Test 13: PreCompact (auto) event"
send_event '{"hook_event_name":"PreCompact","session_id":"test-1","cwd":"/test/project","trigger":"auto"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "compacting" ]; then
    pass "PreCompact (auto) → compacting"
else
    fail "PreCompact (auto) → compacting" "compacting" "$STATE"
fi

# Test 14: PreCompact (manual) → compacting
echo "Test 14: PreCompact (manual) event"
send_event '{"hook_event_name":"PreCompact","session_id":"test-1","cwd":"/test/project","trigger":"manual"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "compacting" ]; then
    pass "PreCompact (manual) → compacting"
else
    fail "PreCompact (manual) → compacting" "compacting" "$STATE"
fi

# Test 15: PreCompact (missing trigger) → compacting
echo "Test 15: PreCompact (missing trigger) event"
send_event '{"hook_event_name":"PreCompact","session_id":"test-1","cwd":"/test/project"}'
STATE=$(get_state "test-1")
if [ "$STATE" = "compacting" ]; then
    pass "PreCompact (missing trigger) → compacting"
else
    fail "PreCompact (missing trigger) → compacting" "compacting" "$STATE"
fi

# Test 16: Task tool subagent count best-effort (PreToolUse +1, PostToolUse -1)
echo "Test 16: Task tool increments/decrements active_subagent_count (best-effort)"
send_event '{"hook_event_name":"SessionStart","session_id":"subagent-test","cwd":"/test/project"}'
send_event '{"hook_event_name":"PreToolUse","session_id":"subagent-test","cwd":"/test/project","tool_name":"Task","tool_use_id":"task_1"}'
COUNT_BEFORE=$(get_field "subagent-test" "active_subagent_count")
send_event '{"hook_event_name":"PostToolUse","session_id":"subagent-test","cwd":"/test/project","tool_name":"Task","tool_use_id":"task_1"}'
COUNT_AFTER=$(get_field "subagent-test" "active_subagent_count")
STATE=$(get_state "subagent-test")
if [ "$COUNT_BEFORE" = "1" ] && [ "$COUNT_AFTER" = "0" ] && [ "$STATE" = "working" ]; then
    pass "Task tool count returns to 0 (and state remains working)"
else
    fail "Task tool count returns to 0 (and state remains working)" "count 1→0 and state=working" "count_before=$COUNT_BEFORE count_after=$COUNT_AFTER state=$STATE"
fi

# Test 17: SessionEnd → session deleted
echo "Test 17: SessionEnd event - should delete session"
send_event '{"hook_event_name":"SessionEnd","session_id":"test-1","cwd":"/test/project"}'
if ! session_exists "test-1"; then
    pass "SessionEnd → session deleted"
else
    fail "SessionEnd → session deleted" "session removed" "session still exists"
fi

# Test 18: Multiple sessions
echo "Test 18: Multiple concurrent sessions"
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

# Test 19: No PID in output
echo "Test 19: No PID field in session record"
HAS_PID=$(has_key "session-a" "pid")
if [ "$HAS_PID" = "false" ]; then
    pass "No PID field"
else
    fail "No PID field" "no pid field" "pid field present"
fi

# Test 20: Missing session_id - should exit gracefully
echo "Test 20: Missing session_id - graceful exit"
set +e
echo '{"hook_event_name":"SessionStart","cwd":"/test/project"}' | "$HOOK_SCRIPT" >/dev/null 2>&1
EXIT_CODE=$?
set -e
if [ $EXIT_CODE -eq 0 ]; then
    pass "Missing session_id handled gracefully"
else
    fail "Missing session_id handled gracefully" "exit 0" "exit $EXIT_CODE"
fi

# Test 21: Missing cwd with fallback (PWD)
echo "Test 21: Missing cwd uses CLAUDE_PROJECT_DIR fallback"
export CLAUDE_PROJECT_DIR="/fallback/project"
send_event '{"hook_event_name":"SessionStart","session_id":"fallback-test"}'
CWD=$(get_field "fallback-test" "cwd")
PROJECT_DIR=$(get_field "fallback-test" "project_dir")
unset CLAUDE_PROJECT_DIR
if [ "$CWD" = "/fallback/project" ] && [ "$PROJECT_DIR" = "/fallback/project" ]; then
    pass "CLAUDE_PROJECT_DIR fallback works (cwd + project_dir)"
else
    fail "CLAUDE_PROJECT_DIR fallback" "cwd=/fallback/project project_dir=/fallback/project" "cwd=$CWD project_dir=$PROJECT_DIR"
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

