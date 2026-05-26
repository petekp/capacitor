#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-$HOME/.capacitor/runtime/app-debug.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBUG_APP_PATH="${CAPACITOR_DEBUG_APP_PATH:-$PROJECT_ROOT/apps/swift/CapacitorDebug.app}"

front_app() {
    osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true
}

ghostty_windows() {
    osascript -e 'tell application "System Events" to if exists process "Ghostty" then tell process "Ghostty" to get name of every window' 2>/dev/null || true
}

echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "front_app: $(front_app)"
echo

echo "capacitor_debug_processes:"
pgrep -fl "$DEBUG_APP_PATH/Contents/MacOS/Capacitor$" 2>/dev/null || true
echo

echo "capacitor_release_processes:"
pgrep -fl '/Applications/Capacitor.app/Contents/MacOS/Capacitor$' 2>/dev/null || true
echo

echo "ghostty_windows:"
ghostty_windows
echo

echo "tmux_clients:"
tmux list-clients -F '#{client_tty}|#{client_session}|#{client_activity}' 2>/dev/null || true
echo

echo "tmux_sessions:"
tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_windows}' 2>/dev/null || true
echo

echo "claude_processes:"
ps -axo pid=,args= | awk '
    /\/claude( |$)|^[[:space:]]*[0-9]+[[:space:]]+claude( |$)/ {
        if ($0 ~ /Claude\.app|Claude Helper|mcp-remote|figma-console-mcp|rg claude|awk/) {
            next
        }

        pid = $1
        session = "manual"
        name = ""
        for (i = 2; i <= NF; i++) {
            if ($i == "--session-id" && (i + 1) <= NF) {
                session = "session_id=" $(i + 1)
            } else if ($i == "--resume" && (i + 1) <= NF) {
                session = "resume=" $(i + 1)
            } else if ($i == "--name" && (i + 1) <= NF) {
                limit = i + 5
                if (limit > NF) {
                    limit = NF
                }
                for (j = i + 1; j <= limit; j++) {
                    if ($(j) ~ /^--/) {
                        break
                    }
                    if ($(j) == "You" || $(j) == "Read" || $(j) == "Treat") {
                        break
                    }
                    name = name (name == "" ? "" : " ") $(j)
                }
            }
        }

        if (name != "") {
            print pid " " session " name=\"" name "\""
        } else {
            print pid " " session
        }
    }
' || true
echo

echo "recent_terminal_activation_trace:"
if [[ -f "$LOG_PATH" ]]; then
    grep '\[TerminalActivation\]' "$LOG_PATH" | tail -n 40 || true
else
    echo "no log file at $LOG_PATH"
fi
