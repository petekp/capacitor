#!/usr/bin/env bash
set -euo pipefail

CAP_HOME="${CAPACITOR_HOME:-$HOME/.capacitor}"
RUNTIME_DIR="${CAP_HOME}/runtime"
RUNTIME_ARTIFACT_PATH="${CAPACITOR_RUNTIME_ARTIFACT_PATH:-${RUNTIME_DIR}/app_snapshot.json}"
RUNTIME_SERVICE_CONNECTION_PATH="${CAPACITOR_RUNTIME_SERVICE_CONNECTION_PATH:-${RUNTIME_DIR}/runtime-service.json}"
APP_LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-${RUNTIME_DIR}/app-debug.log}"
RUNTIME_STDERR_LOG_PATH="${CAPACITOR_RUNTIME_STDERR_LOG:-${RUNTIME_DIR}/runtime.stderr.log}"
RUNTIME_STDOUT_LOG_PATH="${CAPACITOR_RUNTIME_STDOUT_LOG:-${RUNTIME_DIR}/runtime.stdout.log}"
TRANSPARENT_UI_BASE_URL="${CAPACITOR_TRANSPARENT_UI_BASE_URL:-http://localhost:9133}"
HEARTBEAT_PATH="${CAPACITOR_HEARTBEAT_PATH:-${CAP_HOME}/hud-hook-heartbeat}"

RUNTIME_SERVICE_DISCOVERY_DONE=0
RUNTIME_SERVICE_PORT=""
RUNTIME_SERVICE_TOKEN=""
RUNTIME_SERVICE_SOURCE=""

usage() {
  cat <<'USAGE'
Usage: scripts/dev/agent-observe.sh <command> [args...]

Runtime observability helper for Capacitor (runtime-service first).

Commands:
  check                                  Validate runtime service/artifact observability paths
  paths                                  Print canonical paths + endpoint roots
  health                                 Runtime health (`/health` first, artifact fallback)
  sessions                               Print runtime session summaries
  projects                               Print runtime project summaries
  shells                                 Print runtime shell summaries
  activity [limit]                       Print most recent session activity (default limit=50)
  routing-snapshot <project_path> [ws]   Print routing entry for a project/workspace
  routing-diagnostics                    Print diagnostics summary
  snapshot                               Print full runtime snapshot payload
  briefing                               Agent briefing from runtime snapshot (self-sufficient)
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

trim_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_runtime_service_connection() {
  local connection_path="$1"
  python3 - "$connection_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

payload = json.loads(path.read_text())
port = payload.get("port")
auth_token = (payload.get("auth_token") or "").strip()
if port is None or not auth_token:
    raise SystemExit(1)

print(port)
print(auth_token)
PY
}

load_runtime_service_connection() {
  local connection_path="$1"
  local connection_port=""
  local connection_token=""
  local line=""

  while IFS= read -r line; do
    if [[ -z "$connection_port" ]]; then
      connection_port="$line"
    elif [[ -z "$connection_token" ]]; then
      connection_token="$line"
      break
    fi
  done < <(read_runtime_service_connection "$connection_path" 2>/dev/null || true)

  if [[ -n "$connection_port" && -n "$connection_token" ]]; then
    printf '%s\n%s\n' "$connection_port" "$connection_token"
    return 0
  fi

  return 1
}

discover_runtime_service() {
  if [[ "$RUNTIME_SERVICE_DISCOVERY_DONE" -eq 1 ]]; then
    [[ -n "$RUNTIME_SERVICE_PORT" && -n "$RUNTIME_SERVICE_TOKEN" ]]
    return
  fi

  RUNTIME_SERVICE_DISCOVERY_DONE=1

  local env_port env_token
  env_port="$(trim_whitespace "${CAPACITOR_RUNTIME_SERVICE_PORT:-}")"
  env_token="$(trim_whitespace "${CAPACITOR_RUNTIME_SERVICE_TOKEN:-}")"
  if [[ -n "$env_port" || -n "$env_token" ]]; then
    if [[ -n "$env_port" && -n "$env_token" ]]; then
      RUNTIME_SERVICE_PORT="$env_port"
      RUNTIME_SERVICE_TOKEN="$env_token"
      RUNTIME_SERVICE_SOURCE="env"
      return 0
    fi
    return 1
  fi

  local explicit_artifact_override explicit_connection_override
  explicit_artifact_override="$(trim_whitespace "${CAPACITOR_RUNTIME_ARTIFACT_PATH-}")"
  explicit_connection_override="$(trim_whitespace "${CAPACITOR_RUNTIME_SERVICE_CONNECTION_PATH-}")"

  if [[ -n "$explicit_artifact_override" && -z "$explicit_connection_override" ]]; then
    return 1
  fi

  if [[ -f "$RUNTIME_SERVICE_CONNECTION_PATH" ]]; then
    local connection_port=""
    local connection_token=""
    local line_index=0
    local line=""

    while IFS= read -r line; do
      if [[ "$line_index" -eq 0 ]]; then
        connection_port="$line"
      elif [[ "$line_index" -eq 1 ]]; then
        connection_token="$line"
        break
      fi
      line_index=$((line_index + 1))
    done < <(load_runtime_service_connection "$RUNTIME_SERVICE_CONNECTION_PATH" 2>/dev/null || true)

    if [[ -n "$connection_port" && -n "$connection_token" ]]; then
      RUNTIME_SERVICE_PORT="$connection_port"
      RUNTIME_SERVICE_TOKEN="$connection_token"
      RUNTIME_SERVICE_SOURCE="connection_file"
      return 0
    fi
  fi

  return 1
}

runtime_service_base_url() {
  discover_runtime_service || return 1
  printf 'http://127.0.0.1:%s' "$RUNTIME_SERVICE_PORT"
}

runtime_source_label() {
  if discover_runtime_service; then
    printf 'runtime_service'
  else
    printf 'artifact_file'
  fi
}

runtime_snapshot_location() {
  if discover_runtime_service; then
    printf '%s/runtime/snapshot' "$(runtime_service_base_url)"
  else
    printf '%s' "$RUNTIME_ARTIFACT_PATH"
  fi
}

runtime_service_get() {
  local path="$1"
  local base_url
  base_url="$(runtime_service_base_url)" || return 1
  require_cmd curl
  curl -fsS \
    -H "Authorization: Bearer ${RUNTIME_SERVICE_TOKEN}" \
    "${base_url}${path}"
}

read_artifact_snapshot() {
  if [[ ! -f "$RUNTIME_ARTIFACT_PATH" ]]; then
    echo "Runtime artifact not found: $RUNTIME_ARTIFACT_PATH" >&2
    exit 1
  fi

  cat "$RUNTIME_ARTIFACT_PATH"
}

read_snapshot() {
  if discover_runtime_service; then
    runtime_service_get "/runtime/snapshot"
  else
    read_artifact_snapshot
  fi
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

  if discover_runtime_service; then
    echo "Runtime service: $(runtime_service_base_url) (${RUNTIME_SERVICE_SOURCE})"
    if runtime_service_get "/health" >/dev/null 2>&1; then
      echo "  ok (service reachable)"
    else
      echo "  unreachable"
      ok=0
    fi
  else
    echo "Runtime service: not discovered"
  fi

  echo "Runtime artifact: $RUNTIME_ARTIFACT_PATH"
  if [[ -f "$RUNTIME_ARTIFACT_PATH" ]]; then
    echo "  ok (artifact exists)"
    if command -v jq >/dev/null 2>&1; then
      if jq . "$RUNTIME_ARTIFACT_PATH" >/dev/null 2>&1; then
        echo "  ok (artifact parses)"
      else
        echo "  invalid json"
        ok=0
      fi
    fi
  else
    echo "  missing"
    if ! discover_runtime_service; then
      ok=0
    fi
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
runtime_source=$(runtime_source_label)
runtime_artifact_path=$RUNTIME_ARTIFACT_PATH
runtime_snapshot_location=$(runtime_snapshot_location)
runtime_service_connection_path=$RUNTIME_SERVICE_CONNECTION_PATH
app_log_path=$APP_LOG_PATH
runtime_stderr_log_path=$RUNTIME_STDERR_LOG_PATH
runtime_stdout_log_path=$RUNTIME_STDOUT_LOG_PATH
PATHS
  if discover_runtime_service; then
    cat <<PATHS
runtime_service_base_url=$(runtime_service_base_url)
runtime_service_source=$RUNTIME_SERVICE_SOURCE
PATHS
  fi
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
    if discover_runtime_service; then
      runtime_service_get "/health" | pretty_print_json
    elif command -v jq >/dev/null 2>&1 && [[ -f "$RUNTIME_ARTIFACT_PATH" ]]; then
      jq '{ok:true,status:"healthy",source:"artifact_file",generated_at:.generated_at,sessions:(.sessions|length),projects:(.projects|length)}' "$RUNTIME_ARTIFACT_PATH"
    else
      if [[ -f "$RUNTIME_ARTIFACT_PATH" ]]; then
        printf '{"ok":true,"status":"healthy","source":"artifact_file"}\n'
      else
        printf '{"ok":false,"status":"unavailable","source":"artifact_file","error":"runtime_artifact_missing"}\n'
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
    snapshot_payload="$(read_snapshot 2>/dev/null || true)"
    if [[ -z "$snapshot_payload" ]]; then
      echo "{\"ok\":false,\"error\":\"runtime_snapshot_unavailable\",\"source\":\"$(runtime_source_label)\",\"age_seconds\":null}" | pretty_print_json
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      echo "$snapshot_payload" | jq --arg source "$(runtime_source_label)" 'def parse_ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
      {
        ok: true,
        source: $source,
        generated_at: .generated_at,
        age_seconds: (now - (.generated_at | parse_ts) | floor),
        stale: ((now - (.generated_at | parse_ts)) > 30)
      }' 2>/dev/null || echo '{"ok":true,"age_seconds":null,"note":"could not parse generated_at"}' | pretty_print_json
    else
      echo "jq required for detailed freshness"
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
    snapshot_payload=""
    if command -v jq >/dev/null 2>&1; then
      snapshot_payload="$(read_snapshot 2>/dev/null || true)"
    fi

    echo "=== Capacitor Diagnostics ==="
    echo ""

    echo "--- Freshness ---"
    "$0" freshness 2>/dev/null || echo '{"ok":false,"error":"freshness check failed"}'
    echo ""

    echo "--- Health ---"
    "$0" health 2>/dev/null || echo '{"ok":false,"error":"health check failed"}'
    echo ""

    echo "--- Stuck Sessions ---"
    if [[ -n "$snapshot_payload" ]]; then
      stuck=$(echo "$snapshot_payload" | jq 'def parse_ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
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
      }]' 2>/dev/null)
      count=$(echo "$stuck" | jq 'length' 2>/dev/null || echo "0")
      if [[ "$count" -gt 0 ]]; then
        echo "  WARNING: $count potentially stuck session(s):"
        echo "$stuck" | jq .
      else
        echo "  ok (no stuck sessions)"
      fi
    else
      echo "  (requires jq + runtime snapshot)"
    fi
    echo ""

    echo "--- Skip Counters ---"
    if [[ -n "$snapshot_payload" ]]; then
      echo "$snapshot_payload" | jq '.diagnostics | {
        events_skipped,
        stale_events_skipped,
        informational_events_skipped,
        reducer_events_skipped,
        skip_rate: (if .events_ingested > 0 then
          "\((.events_skipped * 100 / .events_ingested))%"
        else "n/a" end)
      }' 2>/dev/null || echo "  (skip counters not available in this snapshot)"
    else
      echo "  (requires jq + runtime snapshot)"
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
    if [[ -n "$snapshot_payload" ]]; then
      echo "$snapshot_payload" | jq '.routing | map({project_path, status, target_kind, reason_code})' 2>/dev/null || echo "  (parse error)"
    else
      echo "  (requires jq + runtime snapshot)"
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
