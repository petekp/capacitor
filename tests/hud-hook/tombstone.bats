#!/usr/bin/env bats

# Tests for the tombstone mechanism that prevents post-SessionEnd race conditions.
# Run with: bats tests/hud-hook/tombstone.bats
# Install bats: brew install bats-core

setup() {
    # Create isolated test environment
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"

    # Paths the hook binary will use (relative to HOME)
    CAPACITOR_DIR="$TEST_HOME/.capacitor"
    SESSIONS_FILE="$CAPACITOR_DIR/sessions.json"
    TOMBSTONES_DIR="$CAPACITOR_DIR/ended-sessions"
    LOCKS_DIR="$CAPACITOR_DIR/sessions"

    # Create required directories
    mkdir -p "$CAPACITOR_DIR"
    mkdir -p "$LOCKS_DIR"

    # Get the hud-hook binary from target/release
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HUD_HOOK="$PROJECT_ROOT/target/release/hud-hook"

    # Ensure binary exists
    if [ ! -x "$HUD_HOOK" ]; then
        skip "hud-hook binary not found at $HUD_HOOK (run 'cargo build -p hud-hook --release')"
    fi
}

teardown() {
    rm -rf "$TEST_HOME"
}

# Helper to send a hook event
send_event() {
    local event="$1"
    local session_id="$2"
    local cwd="${3:-/test/project}"

    echo "{\"hook_event_name\": \"$event\", \"session_id\": \"$session_id\", \"cwd\": \"$cwd\"}" \
        | "$HUD_HOOK" handle
}

# Helper to check if session exists
session_exists() {
    local session_id="$1"
    [ -f "$SESSIONS_FILE" ] && jq -e ".sessions[\"$session_id\"]" "$SESSIONS_FILE" > /dev/null 2>&1
}

# Helper to get session state
get_session_state() {
    local session_id="$1"
    jq -r ".sessions[\"$session_id\"].state" "$SESSIONS_FILE" 2>/dev/null
}

# Helper to check if tombstone exists
tombstone_exists() {
    local session_id="$1"
    [ -f "$TOMBSTONES_DIR/$session_id" ]
}

# =============================================================================
# Basic Lifecycle Tests
# =============================================================================

@test "SessionStart creates session with ready state" {
    send_event "SessionStart" "test-session-1"

    session_exists "test-session-1"
    [ "$(get_session_state 'test-session-1')" = "ready" ]
}

@test "SessionEnd removes session" {
    send_event "SessionStart" "test-session-2"
    session_exists "test-session-2"

    send_event "SessionEnd" "test-session-2"
    ! session_exists "test-session-2"
}

# =============================================================================
# Tombstone Mechanism Tests
# =============================================================================

@test "SessionEnd creates tombstone" {
    send_event "SessionStart" "test-session-3"
    send_event "SessionEnd" "test-session-3"

    tombstone_exists "test-session-3"
}

@test "UserPromptSubmit after SessionEnd is blocked by tombstone" {
    # Start and end a session
    send_event "SessionStart" "race-test-1"
    send_event "SessionEnd" "race-test-1"

    # Verify session is gone and tombstone exists
    ! session_exists "race-test-1"
    tombstone_exists "race-test-1"

    # Send late UserPromptSubmit (simulates /exit race condition)
    send_event "UserPromptSubmit" "race-test-1"

    # Session should NOT be recreated
    ! session_exists "race-test-1"
}

@test "PreToolUse after SessionEnd is blocked by tombstone" {
    send_event "SessionStart" "race-test-2"
    send_event "SessionEnd" "race-test-2"

    # Send late PreToolUse
    send_event "PreToolUse" "race-test-2"

    # Session should NOT be recreated
    ! session_exists "race-test-2"
}

@test "PostToolUse after SessionEnd is blocked by tombstone" {
    send_event "SessionStart" "race-test-3"
    send_event "SessionEnd" "race-test-3"

    # Send late PostToolUse
    send_event "PostToolUse" "race-test-3"

    # Session should NOT be recreated
    ! session_exists "race-test-3"
}

@test "multiple late events after SessionEnd are all blocked" {
    send_event "SessionStart" "race-test-4"
    send_event "SessionEnd" "race-test-4"

    # Barrage of late events
    send_event "UserPromptSubmit" "race-test-4"
    send_event "PreToolUse" "race-test-4"
    send_event "PostToolUse" "race-test-4"
    send_event "PermissionRequest" "race-test-4"

    # Session should still not exist
    ! session_exists "race-test-4"
}

@test "new SessionStart for same session_id works after tombstone" {
    # First lifecycle
    send_event "SessionStart" "reuse-test"
    send_event "SessionEnd" "reuse-test"
    tombstone_exists "reuse-test"

    # New session with same ID should work (SessionEnd clears tombstone... or does it?)
    # Actually, SessionStart should work regardless - tombstone only blocks non-SessionStart events
    send_event "SessionStart" "reuse-test"

    # Session should exist again
    session_exists "reuse-test"
    [ "$(get_session_state 'reuse-test')" = "ready" ]
}

# =============================================================================
# Edge Cases
# =============================================================================

@test "events for never-started session are handled gracefully" {
    # UserPromptSubmit for a session that was never started
    # Should create the session (no tombstone exists)
    send_event "UserPromptSubmit" "never-started"

    session_exists "never-started"
    [ "$(get_session_state 'never-started')" = "working" ]
}

@test "tombstone only affects its own session" {
    # Start two sessions
    send_event "SessionStart" "session-a"
    send_event "SessionStart" "session-b"

    # End only session-a
    send_event "SessionEnd" "session-a"

    # Late event for session-a should be blocked
    send_event "UserPromptSubmit" "session-a"
    ! session_exists "session-a"

    # Event for session-b should work normally
    send_event "UserPromptSubmit" "session-b"
    session_exists "session-b"
    [ "$(get_session_state 'session-b')" = "working" ]
}
