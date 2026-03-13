#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

count_matches() {
  local pattern="$1"
  shift
  (rg -n --glob '!**/.build/**' --glob '!**/target/**' --glob '!**/node_modules/**' "$pattern" "$@" || true) | wc -l | tr -d ' '
}

count_matches_excluding() {
  local pattern="$1"
  local exclude="$2"
  shift 2
  (rg -n --glob '!**/.build/**' --glob '!**/target/**' --glob '!**/node_modules/**' --glob "!$exclude" "$pattern" "$@" || true) | wc -l | tr -d ' '
}

DIRECT_TMUX_BUDGET=0
TERMINAL_SWITCH_BUDGET=0
RAW_ROUTE_SHAPE_BUDGET=0
HOST_FOCUS_APPLESCRIPT_BUDGET=0
DUPLICATE_ENTRYPOINT_BUDGET=0

direct_tmux_count="$(count_matches_excluding 'tmux (switch-client|select-window|select-pane|new-session|list-clients|list-windows|display-message)' 'apps/swift/Sources/Capacitor/Models/TmuxRouter.swift' apps/swift/Sources/Capacitor/Models)"
terminal_switch_count="$(count_matches 'case \.ghostty|case \.iTerm|case \.terminal' apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift)"
raw_route_shape_count="$(count_matches 'target_kind|target_value' apps/swift core)"
host_focus_applescript_count="$(count_matches_excluding 'tell application "iTerm2"|tell application "Terminal"' 'apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift' apps/swift/Sources/Capacitor/Models)"
duplicate_entrypoint_count="$(count_matches 'performUnifiedActivation\(|activateProjectSession\(' apps/swift/Sources/Capacitor/Models)"

print_status() {
  cat <<EOF
direct_tmux_outside_router=$direct_tmux_count/$DIRECT_TMUX_BUDGET
terminal_switch_inside_launcher=$terminal_switch_count/$TERMINAL_SWITCH_BUDGET
raw_route_shape=$raw_route_shape_count/$RAW_ROUTE_SHAPE_BUDGET
host_focus_applescript_outside_drivers=$host_focus_applescript_count/$HOST_FOCUS_APPLESCRIPT_BUDGET
duplicate_activation_entrypoints=$duplicate_entrypoint_count/$DUPLICATE_ENTRYPOINT_BUDGET
EOF
}

if [[ "${1:-}" == "--status" ]]; then
  print_status
  exit 0
fi

print_status

[[ "$direct_tmux_count" -le "$DIRECT_TMUX_BUDGET" ]] || { echo "direct tmux literal budget exceeded" >&2; exit 1; }
[[ "$terminal_switch_count" -le "$TERMINAL_SWITCH_BUDGET" ]] || { echo "terminal switch budget exceeded" >&2; exit 1; }
[[ "$raw_route_shape_count" -le "$RAW_ROUTE_SHAPE_BUDGET" ]] || { echo "raw route shape budget exceeded" >&2; exit 1; }
[[ "$host_focus_applescript_count" -le "$HOST_FOCUS_APPLESCRIPT_BUDGET" ]] || { echo "host focus AppleScript budget exceeded" >&2; exit 1; }
[[ "$duplicate_entrypoint_count" -le "$DUPLICATE_ENTRYPOINT_BUDGET" ]] || { echo "duplicate activation entrypoint budget exceeded" >&2; exit 1; }
