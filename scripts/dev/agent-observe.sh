#!/usr/bin/env bash
set -euo pipefail

CAP_HOME="${CAPACITOR_HOME:-$HOME/.capacitor}"
RUNTIME_DIR="${CAP_HOME}/runtime"
SNAPSHOT_PATH="${CAPACITOR_CORE_SNAPSHOT:-${RUNTIME_DIR}/app_snapshot.json}"
APP_LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-${RUNTIME_DIR}/app-debug.log}"
RUNTIME_STDERR_LOG_PATH="${CAPACITOR_RUNTIME_STDERR_LOG:-${RUNTIME_DIR}/runtime.stderr.log}"
RUNTIME_STDOUT_LOG_PATH="${CAPACITOR_RUNTIME_STDOUT_LOG:-${RUNTIME_DIR}/runtime.stdout.log}"
TRANSPARENT_UI_BASE_URL="${CAPACITOR_TRANSPARENT_UI_BASE_URL:-http://localhost:9133}"
HEARTBEAT_PATH="${CAPACITOR_HEARTBEAT_PATH:-${CAP_HOME}/hud-hook-heartbeat}"

usage() {
  cat <<'USAGE'
Usage: scripts/dev/agent-observe.sh <command> [args...]

Runtime observability helper for Capacitor (direct-core mode).

Commands:
  check                                  Validate local runtime observability paths
  paths                                  Print canonical paths + endpoint roots
  health                                 Derived runtime health from snapshot presence/parseability
  sessions                               Print runtime session summaries
  projects                               Print runtime project summaries
  shells                                 Print runtime shell summaries
  activity [limit]                       Print most recent session activity (default limit=50)
  routing-snapshot <project_path> [ws]   Print routing entry for a project/workspace
  routing-diagnostics                    Print diagnostics summary
  snapshot                               Print full runtime snapshot payload
  briefing                                Agent briefing from snapshot (self-sufficient)
  telemetry [limit]                      Transparent UI: GET /telemetry
  stream                                 Transparent UI: GET /telemetry-stream (SSE passthrough)
  tail <app|runtime-stderr|runtime-stdout> Tail key logs
  smoke [project_path] [workspace_id]    Run all observability smoke checks
  freshness                              Snapshot age and staleness check
  session <session_id>                   Full detail for one session
  shell-audit                            Cross-validate shells: PID liveness, TTY, parent_app
  errors [limit]                         Recent error/warning lines from app debug log (default=20)
  hooks                                  Hook installation status + heartbeat + recent events
  activation-traces [limit]              Recent activation decision traces from debug log (default=50)
  diagnose                               One-shot full diagnostic summary
USAGE
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

pretty_print_json() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

read_snapshot() {
  if [[ ! -f "$SNAPSHOT_PATH" ]]; then
    echo "Runtime snapshot not found: $SNAPSHOT_PATH" >&2
    exit 1
  fi

  cat "$SNAPSHOT_PATH"
}

snapshot_query() {
  local filter="$1"
  if command -v jq >/dev/null 2>&1; then
    read_snapshot | jq "$filter"
  else
    read_snapshot
  fi
}

http_get_json() {
  require_cmd curl
  local url="$1"
  curl -fsS "$url" | pretty_print_json
}

check() {
  local ok=1

  echo "Snapshot: $SNAPSHOT_PATH"
  if [[ -f "$SNAPSHOT_PATH" ]]; then
    echo "  ok (snapshot exists)"
    if command -v jq >/dev/null 2>&1; then
      if jq . "$SNAPSHOT_PATH" >/dev/null 2>&1; then
        echo "  ok (snapshot parses)"
      else
        echo "  invalid json"
        ok=0
      fi
    fi
  else
    echo "  missing"
    ok=0
  fi

  echo "App log: $APP_LOG_PATH"
  [[ -f "$APP_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  echo "Runtime stderr log: $RUNTIME_STDERR_LOG_PATH"
  [[ -f "$RUNTIME_STDERR_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  echo "Runtime stdout log: $RUNTIME_STDOUT_LOG_PATH"
  [[ -f "$RUNTIME_STDOUT_LOG_PATH" ]] && echo "  ok" || echo "  missing"

  if [[ "$ok" -eq 0 ]]; then
    exit 1
  fi
}

paths() {
  cat <<PATHS
snapshot_path=$SNAPSHOT_PATH
app_log_path=$APP_LOG_PATH
runtime_stderr_log_path=$RUNTIME_STDERR_LOG_PATH
runtime_stdout_log_path=$RUNTIME_STDOUT_LOG_PATH
PATHS
}

routing_snapshot() {
  local project_path="$1"
  local workspace_id="${2:-}"

  if [[ -z "$project_path" ]]; then
    echo "Usage: scripts/dev/agent-observe.sh routing-snapshot <project_path> [workspace_id]" >&2
    exit 1
  fi

  if command -v jq >/dev/null 2>&1; then
    if [[ -n "$workspace_id" ]]; then
      snapshot_query ".routing | map(select(.project_path == \"${project_path}\" and .workspace_id == \"${workspace_id}\")) | first"
    else
      snapshot_query ".routing | map(select(.project_path == \"${project_path}\")) | first"
    fi
  else
    read_snapshot
  fi
}

command="${1:-help}"
shift || true

case "$command" in
  help|-h|--help)
    usage
    ;;
  check)
    check
    ;;
  paths)
    paths
    ;;
  health)
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      jq '{ok:true,status:"healthy",generated_at:.generated_at,sessions:(.sessions|length),projects:(.projects|length)}' "$SNAPSHOT_PATH"
    else
      if [[ -f "$SNAPSHOT_PATH" ]]; then
        printf '{"ok":true,"status":"healthy"}\n'
      else
        printf '{"ok":false,"status":"unavailable","error":"snapshot_missing"}\n'
        exit 1
      fi
    fi
    ;;
  sessions)
    snapshot_query '.sessions'
    ;;
  projects)
    snapshot_query '.projects'
    ;;
  shells)
    snapshot_query '.shells'
    ;;
  activity)
    limit="${1:-50}"
    if command -v jq >/dev/null 2>&1; then
      snapshot_query ".sessions | sort_by(.updated_at) | reverse | .[:${limit}]"
    else
      read_snapshot
    fi
    ;;
  routing-snapshot)
    routing_snapshot "${1:-}" "${2:-}"
    ;;
  routing-diagnostics)
    snapshot_query '.diagnostics'
    ;;
  snapshot)
    read_snapshot | pretty_print_json
    ;;
  briefing)
    if command -v jq >/dev/null 2>&1; then
      read_snapshot | jq '{
        ok: true,
        summary: {
          projects: { count: (.projects | length), paths: [.projects[].project_path] },
          sessions: {
            count: (.sessions | length),
            states: ([.sessions[].state] | group_by(.) | map({(.[0]): length}) | add // {}),
            working: [.sessions[] | select(.state == "working") | {session_id, project_path, updated_at, tools_in_flight}]
          },
          shells: { count: (.shells | length) },
          routing: [.routing[] | {project_path, status, target_kind, target_value, reason_code}],
          diagnostics: .diagnostics,
          generated_at: .generated_at
        }
      }'
    else
      read_snapshot
    fi
    ;;
  telemetry)
    limit="${1:-200}"
    if curl -fsS "${TRANSPARENT_UI_BASE_URL}/telemetry?limit=${limit}" 2>/dev/null | pretty_print_json; then
      :
    else
      echo "Telemetry requires transparent-ui-server (node scripts/transparent-ui-server.mjs)" >&2
      exit 1
    fi
    ;;
  stream)
    require_cmd curl
    curl -N -fsS "${TRANSPARENT_UI_BASE_URL}/telemetry-stream"
    ;;
  tail)
    if [[ $# -lt 1 ]]; then
      echo "Usage: scripts/dev/agent-observe.sh tail <app|runtime-stderr|runtime-stdout>" >&2
      exit 1
    fi
    case "$1" in
      app)
        tail -n 80 -f "$APP_LOG_PATH"
        ;;
      runtime-stderr)
        tail -n 80 -f "$RUNTIME_STDERR_LOG_PATH"
        ;;
      runtime-stdout)
        tail -n 80 -f "$RUNTIME_STDOUT_LOG_PATH"
        ;;
      *)
        echo "Unknown tail target: $1" >&2
        exit 1
        ;;
    esac
    ;;
  smoke)
    project_path="${1:-$(pwd)}"
    workspace_id="${2:-}"
    echo "Running observability smoke checks..."
    set -e
    "$0" check >/dev/null && echo "  ok check"
    "$0" health >/dev/null && echo "  ok health"
    "$0" projects >/dev/null && echo "  ok projects"
    "$0" sessions >/dev/null && echo "  ok sessions"
    "$0" shells >/dev/null && echo "  ok shells"
    "$0" snapshot >/dev/null && echo "  ok snapshot"
    if [[ -n "$project_path" ]]; then
      "$0" routing-snapshot "$project_path" "$workspace_id" >/dev/null && echo "  ok routing-snapshot ($project_path)"
      "$0" routing-diagnostics >/dev/null && echo "  ok routing-diagnostics"
    fi
    echo "Observability smoke checks passed."
    ;;
  freshness)
    if [[ ! -f "$SNAPSHOT_PATH" ]]; then
      echo '{"ok":false,"error":"snapshot_missing","age_seconds":null}' | pretty_print_json
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      jq 'def parse_ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
      {
        ok: true,
        generated_at: .generated_at,
        age_seconds: (now - (.generated_at | parse_ts) | floor),
        stale: ((now - (.generated_at | parse_ts)) > 30)
      }' "$SNAPSHOT_PATH" 2>/dev/null || echo '{"ok":true,"age_seconds":null,"note":"could not parse generated_at"}' | pretty_print_json
    else
      stat -f "%m" "$SNAPSHOT_PATH" 2>/dev/null || echo "jq required for detailed freshness"
    fi
    ;;
  session)
    session_id="${1:-}"
    if [[ -z "$session_id" ]]; then
      echo "Usage: scripts/dev/agent-observe.sh session <session_id>" >&2
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      result=$(snapshot_query ".sessions[] | select(.session_id == \"${session_id}\")" 2>/dev/null) || true
      if [[ -z "$result" || "$result" == "null" ]]; then
        echo "Session not found: $session_id" >&2
        exit 1
      fi
      echo "$result"
    else
      read_snapshot
    fi
    ;;
  shell-audit)
    if command -v jq >/dev/null 2>&1; then
      read_snapshot | jq -r '.shells[] | {
        pid,
        cwd,
        tty,
        parent_app,
        tmux_session,
        is_alive: (.is_alive // "unknown"),
        updated_at
      }' | while IFS= read -r shell_json; do
        echo "$shell_json"
      done
      echo ""
      echo "Shell health summary:"
      read_snapshot | jq -r '
        def shell_status:
          if .is_alive == true then "alive"
          elif .is_alive == false then "dead"
          else "unknown"
          end;
        .shells | group_by(shell_status) | map({(.[0] | shell_status): length}) | add // {}
      '
    else
      read_snapshot
    fi
    ;;
  errors)
    limit="${1:-20}"
    if [[ ! -f "$APP_LOG_PATH" ]]; then
      echo "No app debug log found: $APP_LOG_PATH" >&2
      exit 1
    fi
    grep -i -E 'error|fail|crash|fatal|skip|unable|reject|block|broken|stale|unavailable' "$APP_LOG_PATH" | tail -n "$limit"
    ;;
  hooks)
    echo "Hook binary:"
    hook_path="${HOME}/.local/bin/hud-hook"
    if [[ -L "$hook_path" ]]; then
      target=$(readlink "$hook_path")
      if [[ -x "$hook_path" ]]; then
        echo "  ok (symlink -> $target)"
      else
        echo "  broken symlink (-> $target)"
      fi
    elif [[ -x "$hook_path" ]]; then
      echo "  ok (binary)"
    else
      echo "  missing ($hook_path)"
    fi
    echo ""
    echo "Heartbeat:"
    if [[ -f "$HEARTBEAT_PATH" ]]; then
      heartbeat_mtime=$(stat -f "%m" "$HEARTBEAT_PATH" 2>/dev/null || stat -c "%Y" "$HEARTBEAT_PATH" 2>/dev/null || echo "0")
      now_epoch=$(date +%s)
      heartbeat_age=$((now_epoch - heartbeat_mtime))
      if [[ "$heartbeat_age" -le 30 ]]; then
        echo "  ok (${heartbeat_age} seconds ago)"
      elif [[ "$heartbeat_age" -le 300 ]]; then
        echo "  stale (${heartbeat_age} seconds ago)"
      else
        echo "  WARNING: very stale (${heartbeat_age} seconds ago)"
      fi
    else
      echo "  missing ($HEARTBEAT_PATH)"
    fi
    echo ""
    echo "Recent hook events (from debug log):"
    if [[ -f "$APP_LOG_PATH" ]]; then
      grep -i -E 'hook|hud-hook|shell.integration|startup' "$APP_LOG_PATH" | tail -n 20
    else
      echo "  (no debug log found)"
    fi
    ;;
  activation-traces)
    limit="${1:-50}"
    if [[ ! -f "$APP_LOG_PATH" ]]; then
      echo "No app debug log found: $APP_LOG_PATH" >&2
      exit 1
    fi
    grep -E 'ActivationTrace ' "$APP_LOG_PATH" | tail -n "$limit"
    ;;
  diagnose)
    echo "=== Capacitor Diagnostics ==="
    echo ""

    echo "--- Freshness ---"
    "$0" freshness 2>/dev/null || echo '{"ok":false,"error":"freshness check failed"}'
    echo ""

    echo "--- Health ---"
    "$0" health 2>/dev/null || echo '{"ok":false,"error":"health check failed"}'
    echo ""

    echo "--- Stuck Sessions ---"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      stuck=$(jq 'def parse_ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
      [.sessions[] | select(.state == "working") | select(
        (.updated_at // "" | length) > 0 and
        ((now - ((.updated_at // "1970-01-01T00:00:00Z") | parse_ts)) > 30)
      ) | {
        session_id,
        project_path,
        state,
        updated_at,
        tools_in_flight,
        last_event: (.last_event // "unknown"),
        last_activity_at: (.last_activity_at // "unknown"),
        age_seconds: ((now - ((.updated_at // "1970-01-01T00:00:00Z") | parse_ts)) | floor),
        pid_alive: (if .pid > 0 then "check: kill -0 \(.pid)" else "no_pid" end)
      }]' "$SNAPSHOT_PATH" 2>/dev/null)
      count=$(echo "$stuck" | jq 'length' 2>/dev/null || echo "0")
      if [[ "$count" -gt 0 ]]; then
        echo "  WARNING: $count potentially stuck session(s):"
        echo "$stuck" | jq .
      else
        echo "  ok (no stuck sessions)"
      fi
    else
      echo "  (requires jq + snapshot)"
    fi
    echo ""

    echo "--- Skip Counters ---"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      jq '.diagnostics | {
        events_skipped,
        stale_events_skipped,
        informational_events_skipped,
        reducer_events_skipped,
        skip_rate: (if .events_ingested > 0 then
          "\((.events_skipped * 100 / .events_ingested))%"
        else "n/a" end)
      }' "$SNAPSHOT_PATH" 2>/dev/null || echo "  (skip counters not available in this snapshot)"
    else
      echo "  (requires jq + snapshot)"
    fi
    echo ""

    echo "--- Recent Errors ---"
    if [[ -f "$APP_LOG_PATH" ]]; then
      error_count=$(grep -c -i -E 'error|fail|crash|fatal|skip|unable|reject|block|broken|stale|unavailable' "$APP_LOG_PATH" 2>/dev/null || echo "0")
      echo "  Total error/warning lines: $error_count"
      if [[ "$error_count" -gt 0 ]]; then
        echo "  Last 5:"
        grep -i -E 'error|fail|crash|fatal|skip|unable|reject|block|broken|stale|unavailable' "$APP_LOG_PATH" | tail -n 5 | sed 's/^/    /'
      fi
    else
      echo "  (no debug log)"
    fi
    echo ""

    echo "--- Hooks ---"
    "$0" hooks 2>/dev/null | sed 's/^/  /'
    echo ""

    echo "--- Routing Summary ---"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      jq '.routing | map({project_path, status, target_kind, reason_code})' "$SNAPSHOT_PATH" 2>/dev/null || echo "  (parse error)"
    else
      echo "  (requires jq + snapshot)"
    fi
    echo ""
    echo "=== End Diagnostics ==="
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
