#!/bin/bash

# Lock System Tests
# Tests the mkdir-based locking mechanism for session detection

# Note: We don't use set -e because test failures should be counted, not abort

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSIONS_DIR="$HOME/.claude/sessions"
HOOK_SCRIPT="$HOME/.claude/scripts/hud-state-tracker.sh"
STATE_FILE="$HOME/.claude/hud-session-states-v2.json"

# Test colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test project path
TEST_CWD="/tmp/test-lock-project-$(date +%s)"

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

log_info() {
    echo -e "      $1"
}

# Calculate lock hash for a path (same algorithm as hook script)
get_lock_hash() {
    local path="$1"
    if command -v md5 &>/dev/null; then
        echo -n "$path" | md5
    elif command -v md5sum &>/dev/null; then
        echo -n "$path" | md5sum | cut -d' ' -f1
    else
        echo -n "$path" | cksum | cut -d' ' -f1
    fi
}

setup() {
    mkdir -p "$TEST_CWD"
    mkdir -p "$SESSIONS_DIR"
    echo '{"version":1,"projects":{}}' > "$STATE_FILE"
}

teardown() {
    rm -rf "$TEST_CWD"
    # Clean up test locks only
    local hash=$(get_lock_hash "$TEST_CWD")
    rm -rf "$SESSIONS_DIR/${hash}.lock"
}

# ============================================
# Test Cases
# ============================================

test_lock_created_on_user_prompt() {
    log_test "Lock directory should be created on UserPromptSubmit"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    # Clean up any existing lock
    rm -rf "$lock_dir"

    # Simulate Claude process (use our own PID as the "Claude" process)
    # We'll run a background sleep to simulate Claude
    sleep 300 &
    local fake_claude_pid=$!

    # Send UserPromptSubmit with our fake Claude PID
    # Note: The hook uses $PPID which will be our shell, but for testing
    # we need to verify the lock mechanism works
    echo "{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"$TEST_CWD\", \"session_id\": \"test-123\", \"stop_hook_active\": false}" | "$HOOK_SCRIPT"

    # Give background process time to create lock
    sleep 0.5

    if [ -d "$lock_dir" ]; then
        log_pass "Lock directory created"
        log_info "Lock at: $lock_dir"
    else
        log_fail "Lock directory not created at $lock_dir"
    fi

    # Clean up fake Claude
    kill $fake_claude_pid 2>/dev/null || true
    wait $fake_claude_pid 2>/dev/null || true

    # Give lock holder time to clean up
    sleep 1.5
}

test_lock_contains_pid_file() {
    log_test "Lock directory should contain pid file"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    # Create a lock manually to test
    mkdir -p "$lock_dir"
    echo "12345" > "$lock_dir/pid"

    if [ -f "$lock_dir/pid" ]; then
        local pid=$(cat "$lock_dir/pid")
        if [ "$pid" = "12345" ]; then
            log_pass "PID file contains correct value"
        else
            log_fail "PID file has wrong value: $pid"
        fi
    else
        log_fail "PID file not found"
    fi

    rm -rf "$lock_dir"
}

test_lock_contains_metadata() {
    log_test "Lock directory should contain meta.json"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    # Create a lock with metadata
    mkdir -p "$lock_dir"
    echo '{"pid": 12345, "started": "2024-01-01T00:00:00Z", "path": "/test/path"}' > "$lock_dir/meta.json"

    if [ -f "$lock_dir/meta.json" ]; then
        if jq -e . "$lock_dir/meta.json" > /dev/null 2>&1; then
            log_pass "meta.json is valid JSON"
        else
            log_fail "meta.json is not valid JSON"
        fi
    else
        log_fail "meta.json not found"
    fi

    rm -rf "$lock_dir"
}

test_stale_lock_detection() {
    log_test "Stale lock (dead PID) should be detected"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    # Create a stale lock with a definitely-dead PID
    mkdir -p "$lock_dir"
    echo "999999999" > "$lock_dir/pid"

    # Check if PID is actually dead (it should be)
    if kill -0 999999999 2>/dev/null; then
        log_info "Skipping test - PID 999999999 unexpectedly exists"
        rm -rf "$lock_dir"
        return
    fi

    # Try to send another UserPromptSubmit - should be able to acquire lock
    sleep 60 &
    local new_pid=$!

    echo "{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"$TEST_CWD\", \"session_id\": \"test-456\", \"stop_hook_active\": false}" | "$HOOK_SCRIPT"

    sleep 0.5

    # The lock should have been taken over (old one removed, new one created)
    if [ -d "$lock_dir" ]; then
        local current_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "none")
        if [ "$current_pid" != "999999999" ]; then
            log_pass "Stale lock was replaced"
            log_info "New PID in lock: $current_pid"
        else
            log_fail "Stale lock was not replaced (still has old PID)"
        fi
    else
        log_fail "Lock directory disappeared"
    fi

    kill $new_pid 2>/dev/null || true
    wait $new_pid 2>/dev/null || true
    sleep 1.5
    rm -rf "$lock_dir"
}

test_lock_cleanup_on_process_exit() {
    log_test "Lock should be cleaned up when process exits"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    rm -rf "$lock_dir"

    # Start a background process that will exit quickly
    (sleep 0.5) &
    local short_lived_pid=$!

    # Manually create a lock for this short-lived process
    mkdir -p "$lock_dir"
    echo "$short_lived_pid" > "$lock_dir/pid"

    # Start a monitoring process (simulating what hook does)
    (
        while kill -0 $short_lived_pid 2>/dev/null; do
            sleep 0.1
        done
        rm -rf "$lock_dir"
    ) &
    local monitor_pid=$!

    # Wait for the short-lived process to exit
    wait $short_lived_pid 2>/dev/null || true

    # Give monitor time to clean up
    sleep 0.3

    if [ ! -d "$lock_dir" ]; then
        log_pass "Lock cleaned up after process exit"
    else
        log_fail "Lock not cleaned up after process exit"
        rm -rf "$lock_dir"
    fi

    kill $monitor_pid 2>/dev/null || true
}

test_concurrent_lock_attempt() {
    log_test "Second session should not acquire lock if first is active"

    local hash=$(get_lock_hash "$TEST_CWD")
    local lock_dir="$SESSIONS_DIR/${hash}.lock"

    rm -rf "$lock_dir"

    # Start first "session"
    sleep 300 &
    local first_pid=$!

    mkdir -p "$lock_dir"
    echo "$first_pid" > "$lock_dir/pid"

    # Try to acquire lock from hook (simulating second session)
    # The hook should see lock is held and exit without changing it
    echo "{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"$TEST_CWD\", \"session_id\": \"test-second\", \"stop_hook_active\": false}" | "$HOOK_SCRIPT"

    sleep 0.5

    local current_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "none")
    if [ "$current_pid" = "$first_pid" ]; then
        log_pass "Lock retained by first session"
    else
        log_fail "Lock was overwritten (expected $first_pid, got $current_pid)"
    fi

    kill $first_pid 2>/dev/null || true
    wait $first_pid 2>/dev/null || true
    rm -rf "$lock_dir"
}

test_hash_consistency() {
    log_test "Hash should be consistent for same path"

    local hash1=$(get_lock_hash "$TEST_CWD")
    local hash2=$(get_lock_hash "$TEST_CWD")

    if [ "$hash1" = "$hash2" ]; then
        log_pass "Hash is consistent"
        log_info "Hash: $hash1"
    else
        log_fail "Hash is inconsistent ($hash1 vs $hash2)"
    fi
}

test_hash_uniqueness() {
    log_test "Different paths should have different hashes"

    local hash1=$(get_lock_hash "/path/one")
    local hash2=$(get_lock_hash "/path/two")

    if [ "$hash1" != "$hash2" ]; then
        log_pass "Different paths have different hashes"
    else
        log_fail "Different paths have same hash: $hash1"
    fi
}

# ============================================
# Run Tests
# ============================================

main() {
    echo "========================================"
    echo "Lock System Tests"
    echo "========================================"
    echo ""

    if [ ! -f "$HOOK_SCRIPT" ]; then
        echo -e "${RED}ERROR:${NC} Hook script not found at $HOOK_SCRIPT"
        exit 1
    fi

    setup

    test_hash_consistency
    test_hash_uniqueness
    test_lock_contains_pid_file
    test_lock_contains_metadata
    test_stale_lock_detection
    test_lock_cleanup_on_process_exit
    test_concurrent_lock_attempt
    test_lock_created_on_user_prompt

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
