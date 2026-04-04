#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT_PATH="$PROJECT_ROOT/scripts/dev/agent-observe.sh"
    TEST_HOME="$TEST_DIR/home"
    RUNTIME_DIR="$TEST_HOME/.capacitor/runtime"

    mkdir -p "$RUNTIME_DIR"

    cat > "$RUNTIME_DIR/app_snapshot.json" <<'EOF'
{
  "generated_at": "2026-04-02T20:00:00Z",
  "sessions": [
    {
      "session_id": "worker-1",
      "project_path": "/tmp/demo",
      "state": "working",
      "updated_at": "2026-04-02T19:58:00Z",
      "tools_in_flight": 1,
      "last_event": "tool_call",
      "last_activity_at": "2026-04-02T19:58:30Z",
      "pid": 123,
      "gc_reason": "missing_pid"
    }
  ],
  "projects": [],
  "shells": [],
  "routing": [],
  "diagnostics": {
    "events_ingested": 10,
    "events_skipped": 1,
    "stale_events_skipped": 0,
    "informational_events_skipped": 0,
    "reducer_events_skipped": 0
  }
}
EOF
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "diagnose shows gc reasons in stuck sessions and dedicated gc section" {
    command -v jq >/dev/null 2>&1 || skip "agent-observe diagnose coverage requires jq"

    run env \
        HOME="$TEST_HOME" \
        CAPACITOR_HOME="$TEST_HOME/.capacitor" \
        CAPACITOR_RUNTIME_ARTIFACT_PATH="$RUNTIME_DIR/app_snapshot.json" \
        /bin/bash "$SCRIPT_PATH" diagnose

    [ "$status" -eq 0 ]
    [[ "$output" == *"--- GC Reasons ---"* ]]

    local stuck_section="${output#*--- Stuck Sessions ---}"
    stuck_section="${stuck_section%%--- GC Reasons ---*}"
    [[ "$stuck_section" == *'"gc_reason": "missing_pid"'* ]]

    local gc_section="${output#*--- GC Reasons ---}"
    gc_section="${gc_section%%--- Skip Counters ---*}"
    [[ "$gc_section" == *"1 session(s) with GC reason:"* ]]
    [[ "$gc_section" == *'"session_id": "worker-1"'* ]]
    [[ "$gc_section" == *'"gc_reason": "missing_pid"'* ]]
}
