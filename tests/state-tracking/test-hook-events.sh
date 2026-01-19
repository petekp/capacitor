#!/bin/bash

# Hook Event Tests
# Tests the hud-state-tracker.sh hook script behavior for all event types

# Note: We don't use set -e because test failures should be counted, not abort

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$HOME/.claude/scripts/hud-state-tracker.sh"
STATE_FILE="$HOME/.claude/hud-session-states-v2.json"
ORIGINAL_STATE=""  # Will be populated in setup()

# Test colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test project path (use a fake path for testing)
TEST_CWD="/tmp/test-project-$(date +%s)"

log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    ((TESTS_FAILED++))
}

setup() {
    # Backup existing state file (preserve contents, not just copy)
    if [ -f "$STATE_FILE" ]; then
        ORIGINAL_STATE=$(cat "$STATE_FILE")
    else
        ORIGINAL_STATE=""
    fi

    # Create test project directory
    mkdir -p "$TEST_CWD"

    # Initialize clean state file for testing
    echo '{"version":1,"projects":{}}' > "$STATE_FILE"
}

cleanup_test_locks() {
    # Calculate hash for test path
    local hash
    if command -v md5 &>/dev/null; then
        hash=$(echo -n "$TEST_CWD" | md5)
    elif command -v md5sum &>/dev/null; then
        hash=$(echo -n "$TEST_CWD" | md5sum | cut -d' ' -f1)
    else
        hash=$(echo -n "$TEST_CWD" | cksum | cut -d' ' -f1)
    fi

    # Kill any background processes monitoring our test locks
    if [ -f "$HOME/.claude/sessions/${hash}.lock/pid" ]; then
        local lock_pid=$(cat "$HOME/.claude/sessions/${hash}.lock/pid" 2>/dev/null || true)
        if [ -n "$lock_pid" ]; then
            # Kill the background monitor process (it's watching for our parent to die)
            pkill -P "$lock_pid" 2>/dev/null || true
        fi
    fi

    rm -rf "$HOME/.claude/sessions/${hash}.lock" 2>/dev/null || true
}

teardown() {
    # Clean up locks first
    cleanup_test_locks

    # Restore original state file from memory
    if [ -n "$ORIGINAL_STATE" ]; then
        echo "$ORIGINAL_STATE" > "$STATE_FILE"
    fi

    # Clean up test directory
    rm -rf "$TEST_CWD"

    # Clean up any test locks (broader pattern)
    rm -rf "$HOME/.claude/sessions/"*test-project* 2>/dev/null || true
}

# Helper to send hook event
send_hook_event() {
    local event="$1"
    local extra_json="${2:-}"

    local json="{\"hook_event_name\": \"$event\", \"cwd\": \"$TEST_CWD\", \"session_id\": \"test-session-123\", \"stop_hook_active\": false"

    if [ -n "$extra_json" ]; then
        json="$json, $extra_json"
    fi

    json="$json}"

    echo "$json" | "$HOOK_SCRIPT"
}

# Helper to get current state for test project
get_state() {
    jq -r --arg cwd "$TEST_CWD" '.projects[$cwd].state // "not_found"' "$STATE_FILE"
}

get_thinking() {
    jq -r --arg cwd "$TEST_CWD" '.projects[$cwd].thinking // false' "$STATE_FILE"
}

# ============================================
# Test Cases
# ============================================

test_session_start_sets_ready() {
    log_test "SessionStart should set state to 'ready'"

    send_hook_event "SessionStart"

    local state=$(get_state)
    if [ "$state" = "ready" ]; then
        log_pass "SessionStart → ready"
    else
        log_fail "SessionStart → ready (got: $state)"
    fi
}

test_user_prompt_submit_sets_working() {
    log_test "UserPromptSubmit should set state to 'working'"

    # First set to ready
    send_hook_event "SessionStart"

    # Then submit prompt (this spawns a background lock holder)
    send_hook_event "UserPromptSubmit"

    # Give background process time to start
    sleep 0.3

    local state=$(get_state)
    local thinking=$(get_thinking)

    if [ "$state" = "working" ]; then
        log_pass "UserPromptSubmit → working"
    else
        log_fail "UserPromptSubmit → working (got: $state)"
    fi

    if [ "$thinking" = "true" ]; then
        log_pass "UserPromptSubmit → thinking=true"
    else
        log_fail "UserPromptSubmit → thinking=true (got: $thinking)"
    fi

    # Clean up any spawned background processes and locks for test path
    local hash
    if command -v md5 &>/dev/null; then
        hash=$(echo -n "$TEST_CWD" | md5)
    elif command -v md5sum &>/dev/null; then
        hash=$(echo -n "$TEST_CWD" | md5sum | cut -d' ' -f1)
    else
        hash=$(echo -n "$TEST_CWD" | cksum | cut -d' ' -f1)
    fi
    rm -rf "$HOME/.claude/sessions/${hash}.lock" 2>/dev/null || true
}

test_stop_sets_ready() {
    log_test "Stop should set state to 'ready'"

    # Set to working first
    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2

    # Then stop
    send_hook_event "Stop"

    local state=$(get_state)
    local thinking=$(get_thinking)

    if [ "$state" = "ready" ]; then
        log_pass "Stop → ready"
    else
        log_fail "Stop → ready (got: $state)"
    fi

    if [ "$thinking" = "false" ]; then
        log_pass "Stop → thinking=false"
    else
        log_fail "Stop → thinking=false (got: $thinking)"
    fi

    cleanup_test_locks
}

test_session_end_sets_idle() {
    log_test "SessionEnd should set state to 'idle'"

    # Go through full lifecycle
    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2
    send_hook_event "Stop"
    send_hook_event "SessionEnd"

    local state=$(get_state)

    if [ "$state" = "idle" ]; then
        log_pass "SessionEnd → idle"
    else
        log_fail "SessionEnd → idle (got: $state)"
    fi

    cleanup_test_locks
}

test_precompact_auto_sets_compacting() {
    log_test "PreCompact with trigger=auto should set state to 'compacting'"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2
    send_hook_event "PreCompact" '"trigger": "auto"'

    local state=$(get_state)

    if [ "$state" = "compacting" ]; then
        log_pass "PreCompact(auto) → compacting"
    else
        log_fail "PreCompact(auto) → compacting (got: $state)"
    fi

    cleanup_test_locks
}

test_precompact_manual_no_change() {
    log_test "PreCompact with trigger=manual should not change state"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2

    local before=$(get_state)
    send_hook_event "PreCompact" '"trigger": "manual"'
    local after=$(get_state)

    if [ "$before" = "$after" ]; then
        log_pass "PreCompact(manual) → no change"
    else
        log_fail "PreCompact(manual) → no change (was: $before, now: $after)"
    fi

    cleanup_test_locks
}

test_post_tool_use_from_compacting() {
    log_test "PostToolUse from compacting should return to working"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2
    send_hook_event "PreCompact" '"trigger": "auto"'

    # Verify compacting
    local mid=$(get_state)
    if [ "$mid" != "compacting" ]; then
        log_fail "Setup failed - expected compacting, got: $mid"
        cleanup_test_locks
        return
    fi

    send_hook_event "PostToolUse"

    local state=$(get_state)
    if [ "$state" = "working" ]; then
        log_pass "PostToolUse (from compacting) → working"
    else
        log_fail "PostToolUse (from compacting) → working (got: $state)"
    fi

    cleanup_test_locks
}

test_notification_idle_prompt_sets_ready() {
    log_test "Notification with idle_prompt should set state to 'ready'"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2
    send_hook_event "Notification" '"notification_type": "idle_prompt"'

    local state=$(get_state)

    if [ "$state" = "ready" ]; then
        log_pass "Notification(idle_prompt) → ready"
    else
        log_fail "Notification(idle_prompt) → ready (got: $state)"
    fi

    cleanup_test_locks
}

test_permission_request_no_change() {
    log_test "PermissionRequest should not change state"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2

    local before=$(get_state)
    send_hook_event "PermissionRequest"
    local after=$(get_state)

    if [ "$before" = "$after" ]; then
        log_pass "PermissionRequest → no change"
    else
        log_fail "PermissionRequest → no change (was: $before, now: $after)"
    fi

    cleanup_test_locks
}

test_stop_with_stop_hook_active_ignored() {
    log_test "Stop with stop_hook_active=true should be ignored"

    send_hook_event "SessionStart"
    send_hook_event "UserPromptSubmit"
    sleep 0.2

    # Send Stop with stop_hook_active=true
    echo "{\"hook_event_name\": \"Stop\", \"cwd\": \"$TEST_CWD\", \"session_id\": \"test-123\", \"stop_hook_active\": true}" | "$HOOK_SCRIPT"

    local state=$(get_state)

    if [ "$state" = "working" ]; then
        log_pass "Stop (stop_hook_active=true) → ignored"
    else
        log_fail "Stop (stop_hook_active=true) → ignored (got: $state)"
    fi

    cleanup_test_locks
}

test_state_file_recovery() {
    log_test "Corrupted state file should be repaired"

    # Corrupt the state file
    echo "not valid json" > "$STATE_FILE"

    send_hook_event "SessionStart"

    # Check if file is valid JSON now
    if jq -e . "$STATE_FILE" > /dev/null 2>&1; then
        log_pass "Corrupted state file recovered"
    else
        log_fail "Corrupted state file not recovered"
    fi
}

# ============================================
# Run Tests
# ============================================

main() {
    echo "========================================"
    echo "Hook Event Tests"
    echo "========================================"
    echo ""

    # Check prerequisites
    if [ ! -f "$HOOK_SCRIPT" ]; then
        echo -e "${RED}ERROR:${NC} Hook script not found at $HOOK_SCRIPT"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        echo -e "${RED}ERROR:${NC} jq is required but not installed"
        exit 1
    fi

    setup

    # Run all tests
    test_session_start_sets_ready
    test_user_prompt_submit_sets_working
    test_stop_sets_ready
    test_session_end_sets_idle
    test_precompact_auto_sets_compacting
    test_precompact_manual_no_change
    test_post_tool_use_from_compacting
    test_notification_idle_prompt_sets_ready
    test_permission_request_no_change
    test_stop_with_stop_hook_active_ignored
    test_state_file_recovery

    teardown

    echo ""
    echo "========================================"
    echo "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "========================================"

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
}

main "$@"
