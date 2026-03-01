#!/usr/bin/env bash
set -euo pipefail

# Test harness for agent-observe.sh diagnostic CLI.
# Uses a fixture snapshot with known data to validate command output.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OBSERVE="$REPO_ROOT/scripts/dev/agent-observe.sh"
FIXTURE_DIR=$(mktemp -d)
SNAPSHOT_PATH="$FIXTURE_DIR/app_snapshot.json"
APP_LOG_PATH="$FIXTURE_DIR/app-debug.log"
HEARTBEAT_PATH="$FIXTURE_DIR/hud-hook-heartbeat"

trap 'rm -rf "$FIXTURE_DIR"' EXIT

pass_count=0
fail_count=0

pass() {
  echo "  ok $1"
  pass_count=$((pass_count + 1))
}

fail() {
  echo "  FAIL $1: $2"
  fail_count=$((fail_count + 1))
}

assert_contains() {
  local output="$1" pattern="$2" label="$3"
  if echo "$output" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label" "expected pattern '$pattern' not found"
  fi
}

assert_not_contains() {
  local output="$1" pattern="$2" label="$3"
  if echo "$output" | grep -qE "$pattern"; then
    fail "$label" "unexpected pattern '$pattern' found"
  else
    pass "$label"
  fi
}

assert_json_field() {
  local output="$1" field="$2" label="$3"
  if echo "$output" | jq -e "$field" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "json field '$field' missing or null"
  fi
}

# ── Fixture: snapshot with a stuck session + a healthy session ──

write_fixture_snapshot() {
  cat > "$SNAPSHOT_PATH" <<'SNAPSHOT'
{
  "projects": [
    {
      "project_path": "/test/stuck-project",
      "project_id": "/test/stuck-project/.git",
      "workspace_id": "ws-stuck",
      "display_name": "stuck-project",
      "state": "working",
      "state_changed_at": "2025-01-01T00:00:00+00:00",
      "updated_at": "2025-01-01T00:00:00+00:00",
      "representative_session_id": "sess-stuck-1",
      "latest_session_id": "sess-stuck-1",
      "session_count": 1,
      "active_count": 1,
      "has_session": true
    },
    {
      "project_path": "/test/healthy-project",
      "project_id": "/test/healthy-project/.git",
      "workspace_id": "ws-healthy",
      "display_name": "healthy-project",
      "state": "ready",
      "state_changed_at": "2026-03-01T12:00:00+00:00",
      "updated_at": "2026-03-01T12:00:00+00:00",
      "representative_session_id": "sess-healthy-1",
      "latest_session_id": "sess-healthy-1",
      "session_count": 1,
      "active_count": 0,
      "has_session": false
    }
  ],
  "sessions": [
    {
      "session_id": "sess-stuck-1",
      "pid": 99999,
      "cwd": "/test/stuck-project",
      "project_id": "/test/stuck-project/.git",
      "project_path": "/test/stuck-project",
      "workspace_id": "ws-stuck",
      "state": "working",
      "state_changed_at": "2025-01-01T00:00:00+00:00",
      "updated_at": "2025-01-01T00:00:00+00:00",
      "last_event": "pre_tool_use",
      "last_activity_at": "2025-01-01T00:00:00+00:00",
      "tools_in_flight": 3,
      "ready_reason": null
    },
    {
      "session_id": "sess-healthy-1",
      "pid": 88888,
      "cwd": "/test/healthy-project",
      "project_id": "/test/healthy-project/.git",
      "project_path": "/test/healthy-project",
      "workspace_id": "ws-healthy",
      "state": "ready",
      "state_changed_at": "2026-03-01T12:00:00+00:00",
      "updated_at": "2026-03-01T12:00:00+00:00",
      "last_event": "notification",
      "last_activity_at": "2026-03-01T11:59:50+00:00",
      "tools_in_flight": 0,
      "ready_reason": "idle_prompt"
    }
  ],
  "shells": [
    {
      "pid": 77777,
      "cwd": "/test/stuck-project",
      "tty": "/dev/ttys999",
      "parent_app": "ghostty",
      "tmux_session": null,
      "updated_at": "2025-01-01T00:00:00+00:00",
      "is_alive": false
    },
    {
      "pid": 66666,
      "cwd": "/test/healthy-project",
      "tty": "/dev/ttys998",
      "parent_app": "iterm2",
      "tmux_session": "dev",
      "updated_at": "2026-03-01T12:00:00+00:00",
      "is_alive": true
    }
  ],
  "routing": [
    {
      "workspace_id": "ws-healthy",
      "project_path": "/test/healthy-project",
      "status": "attached",
      "target_kind": "tmux_session",
      "target_value": "dev",
      "reason_code": "tmux_session_match",
      "reason": "Matched tmux session 'dev'",
      "updated_at": "2026-03-01T12:00:00+00:00"
    }
  ],
  "diagnostics": {
    "events_ingested": 500,
    "sessions_tracked": 2,
    "shell_signals_tracked": 2,
    "events_skipped": 42,
    "stale_events_skipped": 10,
    "informational_events_skipped": 25,
    "reducer_events_skipped": 7,
    "last_error": null
  },
  "generated_at": "2026-03-01T12:00:05+00:00"
}
SNAPSHOT
}

write_fixture_log() {
  cat > "$APP_LOG_PATH" <<'LOG'
[2026-03-01T11:00:00Z] [Startup] Setup complete
[2026-03-01T11:00:01Z] ReadyChime.play action=engine_start_failed request_id=1
[2026-03-01T11:00:02Z] RuntimeClient.fetchRuntimeSnapshot source=core_snapshot_map_error cid=failure-invalid_shell_timestamp pid=4242 invalid_updated_at=bad-ts
[2026-03-01T11:00:03Z] RuntimeClient.fetchRuntimeSnapshot source=core_snapshot_disabled cid=failure-snapshot_read_disabled
[2026-03-01T11:00:04Z] [Startup] Hooks blocked by policy (disableAllHooks is enabled.), showing WelcomeView
[2026-03-01T11:00:05Z] [Startup] Hook status binaryBroken requires auto-repair
[2026-03-01T11:00:06Z] SessionStateManager skipped stale refresh generation=5
[2026-03-01T11:00:07Z] RuntimeClient unable to resolve workspace identity for /test/foo
[2026-03-01T11:00:08Z] TerminalLauncher activation rejected: no routing evidence
[2026-03-01T11:00:09Z] Some normal log line with nothing notable
LOG
}

write_fixture_heartbeat() {
  # Touch with a known time (60 seconds ago)
  touch -t "$(date -v-60S '+%Y%m%d%H%M.%S')" "$HEARTBEAT_PATH"
}

# ── Set env to use fixture paths ──

export CAPACITOR_CORE_SNAPSHOT="$SNAPSHOT_PATH"
export CAPACITOR_APP_DEBUG_LOG="$APP_LOG_PATH"
export CAPACITOR_RUNTIME_STDERR_LOG="$FIXTURE_DIR/runtime.stderr.log"
export CAPACITOR_RUNTIME_STDOUT_LOG="$FIXTURE_DIR/runtime.stdout.log"
export CAPACITOR_HEARTBEAT_PATH="$HEARTBEAT_PATH"

# ── Tests ──

echo "agent-observe.sh diagnostic tests"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# T1: Enriched stuck sessions in diagnose
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T1: diagnose — enriched stuck session output"
write_fixture_snapshot

output=$("$OBSERVE" diagnose 2>&1)

assert_contains "$output" "last_event" "stuck session includes last_event"
assert_contains "$output" "tools_in_flight" "stuck session includes tools_in_flight"
assert_contains "$output" "last_activity_at" "stuck session includes last_activity_at"
assert_contains "$output" "pid_alive" "stuck session includes pid_alive"
assert_contains "$output" "Skip Counters" "diagnose includes skip counters section"
assert_contains "$output" "events_skipped" "diagnose shows events_skipped"
assert_contains "$output" "stale_events_skipped" "diagnose shows stale_events_skipped"
assert_contains "$output" "skip_rate" "diagnose shows skip_rate"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# T2: session detail command
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T2: session — full session detail"
write_fixture_snapshot

output=$("$OBSERVE" session sess-stuck-1 2>&1)

assert_json_field "$output" '.session_id' "returns session object"
assert_json_field "$output" '.last_event' "includes last_event"
assert_json_field "$output" '.tools_in_flight' "includes tools_in_flight"
assert_json_field "$output" '.last_activity_at' "includes last_activity_at"
assert_json_field "$output" '.pid' "includes pid"
assert_json_field "$output" '.state' "includes state"

# Verify wrong session_id returns empty/null
output_miss=$("$OBSERVE" session nonexistent-id 2>&1) || true
assert_contains "$output_miss" "not found|null" "nonexistent session returns not-found"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# T3: heartbeat age in hooks
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T3: hooks — heartbeat age"
write_fixture_snapshot
write_fixture_heartbeat

output=$("$OBSERVE" hooks 2>&1)

assert_contains "$output" "[Hh]eartbeat" "hooks output mentions heartbeat"
assert_contains "$output" "ago|seconds|age" "hooks output shows heartbeat age"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# T4: shell-audit command
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T4: shell-audit"
write_fixture_snapshot

output=$("$OBSERVE" shell-audit 2>&1)

assert_contains "$output" "pid" "shell-audit shows pid"
assert_contains "$output" "tty|parent_app" "shell-audit shows terminal info"
assert_contains "$output" "alive|dead|live" "shell-audit shows liveness"
assert_contains "$output" "ghostty|iterm" "shell-audit shows parent apps"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# T5: wider error patterns
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T5: errors — wider pattern matching"
write_fixture_log

output=$("$OBSERVE" errors 20 2>&1)

# Should catch original patterns
assert_contains "$output" "engine_start_failed" "catches 'failed' pattern"
# Should catch new operational patterns
assert_contains "$output" "skipped stale" "catches 'skipped' pattern"
assert_contains "$output" "unable to resolve" "catches 'unable' pattern"
assert_contains "$output" "rejected" "catches 'rejected' pattern"
assert_contains "$output" "blocked by policy" "catches 'blocked' pattern"
assert_contains "$output" "binaryBroken" "catches 'broken' pattern"
# Should NOT catch normal log lines
assert_not_contains "$output" "nothing notable" "excludes normal lines"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Existing commands still work (regression)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "T6: regression — existing commands"
write_fixture_snapshot

"$OBSERVE" check >/dev/null 2>&1 && pass "check" || fail "check" "exited non-zero"
"$OBSERVE" health >/dev/null 2>&1 && pass "health" || fail "health" "exited non-zero"
"$OBSERVE" paths >/dev/null 2>&1 && pass "paths" || fail "paths" "exited non-zero"
"$OBSERVE" projects >/dev/null 2>&1 && pass "projects" || fail "projects" "exited non-zero"
"$OBSERVE" sessions >/dev/null 2>&1 && pass "sessions" || fail "sessions" "exited non-zero"
"$OBSERVE" shells >/dev/null 2>&1 && pass "shells" || fail "shells" "exited non-zero"
"$OBSERVE" snapshot >/dev/null 2>&1 && pass "snapshot" || fail "snapshot" "exited non-zero"
"$OBSERVE" briefing >/dev/null 2>&1 && pass "briefing" || fail "briefing" "exited non-zero"
"$OBSERVE" freshness >/dev/null 2>&1 && pass "freshness" || fail "freshness" "exited non-zero"

output=$("$OBSERVE" smoke /test/healthy-project 2>&1)
assert_contains "$output" "smoke checks passed" "smoke passes on fixture"
echo ""

# ── Summary ──

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((pass_count + fail_count))
echo "Results: $pass_count/$total passed"
if [[ "$fail_count" -gt 0 ]]; then
  echo "FAILED ($fail_count failures)"
  exit 1
else
  echo "ALL PASSED"
fi
