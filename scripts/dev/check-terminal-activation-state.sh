#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${CAPACITOR_APP_DEBUG_LOG:-$HOME/.capacitor/runtime/app-debug.log}"
TERMINAL_TRACE_SINCE_SECONDS="${CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS:-1800}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBUG_APP_PATH="${CAPACITOR_DEBUG_APP_PATH:-$PROJECT_ROOT/apps/swift/CapacitorDebug.app}"
REQUIRE_DEBUG_FRONTMOST="${CAPACITOR_REQUIRE_DEBUG_FRONTMOST:-0}"
ACTIVATE_DEBUG="${CAPACITOR_ACTIVATE_DEBUG_APP:-0}"
SWIFT_SOURCE_ROOT="${CAPACITOR_SWIFT_SOURCE_ROOT:-$PROJECT_ROOT/apps/swift/Sources}"
CORE_RUST_SOURCE_ROOT="${CAPACITOR_CORE_RUST_SOURCE_ROOT:-$PROJECT_ROOT/core/capacitor-core/src}"
HUD_HOOK_RUST_SOURCE_ROOT="${CAPACITOR_HUD_HOOK_RUST_SOURCE_ROOT:-$PROJECT_ROOT/core/hud-hook/src}"

usage() {
    cat <<EOF
Usage: check-terminal-activation-state.sh [--activate-debug] [--require-debug-frontmost]

Print live Capacitor/Ghostty/tmux/Claude state and fail when the dev app
identity is unsafe for manual verification.

Options:
  --activate-debug           Bring the running Capacitor Debug app forward first.
  --require-debug-frontmost  Also require Capacitor Debug to be the frontmost app.
EOF
}

front_app_snapshot() {
    # Query name, PID, and bundle path from the same frontmost process. Separate
    # AppleScript calls can race when focus changes during live manual checks.
    osascript \
        -e 'tell application "System Events"' \
        -e 'set frontProc to first application process whose frontmost is true' \
        -e 'set procName to name of frontProc' \
        -e 'set procID to unix id of frontProc' \
        -e 'try' \
        -e 'set procPath to POSIX path of application file of frontProc' \
        -e 'on error' \
        -e 'set procPath to ""' \
        -e 'end try' \
        -e 'return procName & linefeed & procID & linefeed & procPath' \
        -e 'end tell' 2>/dev/null || true
}

ghostty_windows() {
    osascript -e 'tell application "System Events" to if exists process "Ghostty" then tell process "Ghostty" to get name of every window' 2>/dev/null || true
}

capacitor_debug_processes() {
    pgrep -fl "$DEBUG_APP_PATH/Contents/MacOS/Capacitor$" 2>/dev/null || true
}

activate_debug_app() {
    local debug_processes="$1"
    local debug_pid

    debug_pid="$(printf '%s\n' "$debug_processes" | awk 'NF { print $1; exit }')"
    if [[ -z "$debug_pid" ]]; then
        return 0
    fi

    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $debug_pid) to true" >/dev/null 2>&1 ||
        open "$DEBUG_APP_PATH" >/dev/null 2>&1 ||
        true
    sleep 0.2
}

capacitor_release_processes() {
    pgrep -fl '/Applications/Capacitor.app/Contents/MacOS/Capacitor$' 2>/dev/null || true
}

capacitor_preview_processes() {
    pgrep -fl '/CapacitorPreview\.app/Contents/MacOS/Capacitor$' 2>/dev/null || true
}

non_debug_capacitor_processes() {
    local debug_binary="$DEBUG_APP_PATH/Contents/MacOS/Capacitor"
    local process_line

    pgrep -fl '/Capacitor$' 2>/dev/null | while IFS= read -r process_line; do
        [[ -z "$process_line" ]] && continue
        case "$process_line" in
            *"$debug_binary" | \
            *'/CapacitorPreview.app/Contents/MacOS/Capacitor')
                ;;
            *)
                printf '%s\n' "$process_line"
                ;;
        esac
    done || true
}

release_capacitor_guard() {
    local release_processes="$1"

    if [[ -z "$release_processes" ||
        "${CAPACITOR_ALLOW_RELEASE_CAPACITOR_DURING_DEBUG:-0}" == "1" ||
        "${CAPACITOR_ALLOW_NON_DEBUG_CAPACITOR_DURING_DEBUG:-0}" == "1" ]]; then
        return 0
    fi

    echo "error: a non-Debug Capacitor build is running during Debug verification." >&2
    echo "non_debug_processes:" >&2
    printf '%s\n' "$release_processes" >&2
    echo "Use the Debug app bundle explicitly: $DEBUG_APP_PATH" >&2
    return 2
}

debug_process_guard() {
    local debug_processes="$1"

    if [[ -n "$debug_processes" || "${CAPACITOR_ALLOW_MISSING_DEBUG_APP:-0}" == "1" ]]; then
        return 0
    fi

    echo "error: Capacitor Debug is not running." >&2
    echo "Start the canonical dev build first: ./scripts/dev/restart-alpha-stable.sh" >&2
    echo "Expected debug bundle: $DEBUG_APP_PATH" >&2
    return 3
}

newest_source_after_artifact() {
    local artifact_path="$1"
    local source_root="$2"
    local source_path

    if [[ ! -e "$artifact_path" || ! -d "$source_root" ]]; then
        return 1
    fi

    source_path="$(find "$source_root" -type f -newer "$artifact_path" -print -quit 2>/dev/null || true)"
    if [[ -n "$source_path" ]]; then
        printf '%s\n' "$source_path"
        return 0
    fi

    return 1
}

debug_build_freshness_guard() {
    local debug_binary="$DEBUG_APP_PATH/Contents/MacOS/Capacitor"
    local core_dylib="$DEBUG_APP_PATH/Contents/Frameworks/libcapacitor_core.dylib"
    local hud_hook="$DEBUG_APP_PATH/Contents/Resources/hud-hook"
    local stale_source=""
    local stale_artifact=""
    local stale_area=""

    if [[ "${CAPACITOR_ALLOW_STALE_DEBUG_BUILD:-0}" == "1" ]]; then
        return 0
    fi

    if stale_source="$(newest_source_after_artifact "$debug_binary" "$SWIFT_SOURCE_ROOT")"; then
        stale_artifact="$debug_binary"
        stale_area="Swift app"
    elif stale_source="$(newest_source_after_artifact "$core_dylib" "$CORE_RUST_SOURCE_ROOT")"; then
        stale_artifact="$core_dylib"
        stale_area="Rust core"
    elif stale_source="$(newest_source_after_artifact "$hud_hook" "$HUD_HOOK_RUST_SOURCE_ROOT")"; then
        stale_artifact="$hud_hook"
        stale_area="runtime service"
    else
        return 0
    fi

    echo "error: Capacitor Debug build is stale for manual verification." >&2
    echo "stale_area: $stale_area" >&2
    echo "newer_source: $stale_source" >&2
    echo "older_artifact: $stale_artifact" >&2
    echo "Restart through ./scripts/dev/restart-alpha-stable.sh before testing UI behavior." >&2
    return 7
}

frontmost_capacitor_guard() {
    local front_app_name="$1"
    local front_app_path="$2"

    if [[ "$front_app_path" == "$DEBUG_APP_PATH" ]]; then
        return 0
    fi

    case "$front_app_path" in
        */CapacitorPreview.app)
            return 0
            ;;
        */Capacitor.app)
            echo "error: frontmost Capacitor app is not the Debug build." >&2
            echo "front_app: $front_app_name" >&2
            echo "front_app_path: $front_app_path" >&2
            echo "Expected debug bundle: $DEBUG_APP_PATH" >&2
            echo "Restart through ./scripts/dev/restart-alpha-stable.sh before manual testing." >&2
            return 4
            ;;
    esac

    # Some macOS automation snapshots can report the process name even when the
    # bundle path is unavailable. Treat a foreground Capacitor without the debug
    # path as unsafe instead of silently letting manual tests hit the wrong app.
    if [[ "$front_app_name" == "Capacitor" || "$front_app_name" == "Capacitor Debug" ]]; then
        echo "error: frontmost Capacitor identity could not be proven to be Debug." >&2
        echo "front_app: $front_app_name" >&2
        echo "front_app_path: ${front_app_path:-<empty>}" >&2
        echo "Expected debug bundle: $DEBUG_APP_PATH" >&2
        return 5
    fi

    return 0
}

require_debug_frontmost_guard() {
    local front_app_name="$1"
    local front_app_path="$2"

    if [[ "$REQUIRE_DEBUG_FRONTMOST" != "1" ]]; then
        return 0
    fi

    if [[ "$front_app_path" == "$DEBUG_APP_PATH" ]]; then
        return 0
    fi

    echo "error: Capacitor Debug is not frontmost." >&2
    echo "front_app: ${front_app_name:-<unknown>}" >&2
    echo "front_app_path: ${front_app_path:-<empty>}" >&2
    echo "Expected debug bundle: $DEBUG_APP_PATH" >&2
    echo "Rerun ./scripts/dev/restart-alpha-stable.sh, then retry the manual check." >&2
    return 6
}

is_test_terminal_activation_trace() {
    local line="$1"

    # Unit tests write fixture activation traces to the shared debug log. Hide
    # those paths so this live diagnostic only reports believable cockpit clicks.
    case "$line" in
        *'project_path="/tmp/'* | \
        *'project_path="/path/to/'* | \
        *'project_path="/Users/pete/Code/'* | \
        *'project_path="/other"'* | \
        *'project_path="/broken"'* | \
        *'project_path="/new"'* | \
        *'project_path="/var/folders/'* | \
        *'batch_id="batch-mobile"'*'batch="Mobile prototype"'*)
            return 0
            ;;
    esac

    return 1
}

terminal_activation_trace_timestamp() {
    local line="$1"

    if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]+Z\] ]]; then
        printf '%sZ\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z\] ]]; then
        printf '%sZ\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z ]]; then
        printf '%sZ\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

terminal_activation_trace_epoch() {
    local timestamp="$1"

    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s" 2>/dev/null && return 0
    date -u -d "$timestamp" "+%s" 2>/dev/null && return 0
    return 1
}

is_recent_terminal_activation_trace() {
    local line="$1"
    local since_seconds="$2"
    local now_epoch="$3"
    local timestamp
    local event_epoch

    if [[ "$since_seconds" == "0" ]]; then
        return 0
    fi

    timestamp="$(terminal_activation_trace_timestamp "$line" || true)"
    if [[ -z "$timestamp" ]]; then
        return 0
    fi

    event_epoch="$(terminal_activation_trace_epoch "$timestamp" || true)"
    if [[ -z "$event_epoch" ]]; then
        return 0
    fi

    ((now_epoch - event_epoch <= since_seconds))
}

recent_terminal_activation_trace() {
    local log_path="$1"
    local since_seconds="${CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS:-$TERMINAL_TRACE_SINCE_SECONDS}"
    local now_epoch="${CAPACITOR_TERMINAL_TRACE_NOW_EPOCH:-$(date -u +%s)}"
    local traces

    if [[ -f "$log_path" ]]; then
        traces="$(grep '\[TerminalActivation\]' "$log_path" | while IFS= read -r line; do
            if ! is_test_terminal_activation_trace "$line"; then
                if is_recent_terminal_activation_trace "$line" "$since_seconds" "$now_epoch"; then
                    printf '%s\n' "$line"
                fi
            fi
        done | tail -n 40 || true)"
        if [[ -n "$traces" ]]; then
            printf '%s\n' "$traces"
        else
            printf 'none within %ss after fixture filtering\n' "$since_seconds"
        fi
    else
        echo "no log file at $log_path"
    fi
}

if [[ "${CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --activate-debug)
            ACTIVATE_DEBUG=1
            shift
            ;;
        --require-debug-frontmost)
            REQUIRE_DEBUG_FRONTMOST=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$ACTIVATE_DEBUG" == "1" ]]; then
    activate_debug_app "$(capacitor_debug_processes)"
fi

FRONT_APP_SNAPSHOT="$(front_app_snapshot)"
FRONT_APP_NAME="$(printf '%s\n' "$FRONT_APP_SNAPSHOT" | sed -n '1p')"
FRONT_APP_PID="$(printf '%s\n' "$FRONT_APP_SNAPSHOT" | sed -n '2p')"
FRONT_APP_PATH="$(printf '%s\n' "$FRONT_APP_SNAPSHOT" | sed -n '3p')"

echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "front_app: $FRONT_APP_NAME"
echo "front_app_pid: $FRONT_APP_PID"
echo "front_app_path: $FRONT_APP_PATH"
echo

echo "capacitor_debug_processes:"
DEBUG_PROCESSES="$(capacitor_debug_processes)"
printf '%s\n' "$DEBUG_PROCESSES"
echo

echo "capacitor_release_processes:"
RELEASE_PROCESSES="$(capacitor_release_processes)"
printf '%s\n' "$RELEASE_PROCESSES"
echo

echo "capacitor_preview_processes:"
PREVIEW_PROCESSES="$(capacitor_preview_processes)"
printf '%s\n' "$PREVIEW_PROCESSES"
echo

echo "capacitor_non_debug_processes:"
NON_DEBUG_PROCESSES="$(non_debug_capacitor_processes)"
printf '%s\n' "$NON_DEBUG_PROCESSES"
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
recent_terminal_activation_trace "$LOG_PATH"

release_capacitor_guard "${NON_DEBUG_PROCESSES:-$RELEASE_PROCESSES}"
debug_process_guard "$DEBUG_PROCESSES"
debug_build_freshness_guard
frontmost_capacitor_guard "$FRONT_APP_NAME" "$FRONT_APP_PATH"
require_debug_frontmost_guard "$FRONT_APP_NAME" "$FRONT_APP_PATH"
