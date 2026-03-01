#!/usr/bin/env bash
set -euo pipefail

CAP_HOME="${CAPACITOR_HOME:-$HOME/.capacitor}"
RUNTIME_DIR="${CAP_HOME}/runtime"
SNAPSHOT_PATH="${CAPACITOR_CORE_SNAPSHOT:-${RUNTIME_DIR}/app_snapshot.json}"
APP_LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-${RUNTIME_DIR}/app-debug.log}"
RUNTIME_STDERR_LOG_PATH="${CAPACITOR_RUNTIME_STDERR_LOG:-${RUNTIME_DIR}/runtime.stderr.log}"
RUNTIME_STDOUT_LOG_PATH="${CAPACITOR_RUNTIME_STDOUT_LOG:-${RUNTIME_DIR}/runtime.stdout.log}"
TRANSPARENT_UI_BASE_URL="${CAPACITOR_TRANSPARENT_UI_BASE_URL:-http://localhost:9133}"

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
  briefing [limit]                       Transparent UI: GET /agent-briefing
  telemetry [limit]                      Transparent UI: GET /telemetry
  stream                                 Transparent UI: GET /telemetry-stream (SSE passthrough)
  tail <app|runtime-stderr|runtime-stdout> Tail key logs
  smoke [project_path] [workspace_id]    Run all observability smoke checks
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

  echo "Transparent UI: $TRANSPARENT_UI_BASE_URL"
  if curl -fsS "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot" >/dev/null 2>&1; then
    echo "  ok (reachable)"
  else
    echo "  not reachable"
  fi

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
transparent_ui_base_url=$TRANSPARENT_UI_BASE_URL
telemetry_endpoint=${TRANSPARENT_UI_BASE_URL}/telemetry
telemetry_stream_endpoint=${TRANSPARENT_UI_BASE_URL}/telemetry-stream
runtime_snapshot_endpoint=${TRANSPARENT_UI_BASE_URL}/runtime-snapshot
agent_briefing_endpoint=${TRANSPARENT_UI_BASE_URL}/agent-briefing
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
    if curl -fsS "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot" >/dev/null 2>&1; then
      http_get_json "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot"
    else
      read_snapshot | pretty_print_json
    fi
    ;;
  briefing)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/agent-briefing?limit=${limit}"
    ;;
  telemetry)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/telemetry?limit=${limit}"
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
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
