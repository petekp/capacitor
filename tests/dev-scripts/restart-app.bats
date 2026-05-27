#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT_PATH="$PROJECT_ROOT/scripts/dev/restart-app.sh"
    TEST_HOME="$TEST_DIR/home"

    mkdir -p "$TEST_HOME/.capacitor/runtime"
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_minimal_plist() {
    local path="$1"

    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF
}

run_restart_cleanup_shell() {
    local script_body="$1"
    shift

    run env \
        HOME="$TEST_HOME" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        CAPACITOR_RUNTIME_ENV_FILE="$TEST_DIR/missing-runtime-env" \
        CAPACITOR_RESTART_APP_SOURCE_ONLY=1 \
        "$@" \
        /bin/bash -lc "$script_body"
}

@test "reap_runtime_service kills the listener discovered by lsof and clears stale artifacts" {
    local port=17474
    local runtime_dir="$TEST_HOME/.capacitor/runtime"
    local signals_log="$TEST_DIR/runtime-signals.log"
    local port_state_file="$TEST_DIR/runtime-port-state"
    local listener_pid=4242

    printf '999999\n' > "$runtime_dir/runtime-service-$port.pid"
    printf 'token\n' > "$runtime_dir/runtime-service-$port.token"
    printf '{"port":17474,"auth_token":"fixture"}\n' > "$runtime_dir/runtime-service.json"
    printf 'occupied\n' > "$port_state_file"

    run_restart_cleanup_shell '
sleep() { :; }
kill() {
    printf "%s\n" "$*" >> "$SIGNALS_LOG"
    if [[ "$1" == "-0" ]]; then
        shift
        if [[ "${1:-}" == "$LISTENER_PID" && "$(cat "$PORT_STATE_FILE")" == "occupied" ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "${2:-}" == "$LISTENER_PID" ]]; then
        printf "clear\n" > "$PORT_STATE_FILE"
    fi
    return 0
}
lsof() {
    case "$*" in
        *"-iTCP:$TEST_PORT"*"-sTCP:LISTEN -t"*)
            if [[ "$(cat "$PORT_STATE_FILE")" == "occupied" ]]; then
                printf "%s\n" "$LISTENER_PID"
            fi
            return 0
            ;;
        *"-iTCP:$TEST_PORT"*"-sTCP:LISTEN"*)
            if [[ "$(cat "$PORT_STATE_FILE")" == "occupied" ]]; then
                printf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
                printf "hud-hook %s user 3u IPv4 0t0 TCP 127.0.0.1:%s (LISTEN)\n" "$LISTENER_PID" "$TEST_PORT"
                return 0
            fi
            return 1
            ;;
    esac
    return 1
}
source "$SCRIPT_PATH"
reap_runtime_service "$TEST_PORT"
' \
        SIGNALS_LOG="$signals_log" \
        PORT_STATE_FILE="$port_state_file" \
        LISTENER_PID="$listener_pid" \
        TEST_PORT="$port"

    [ "$status" -eq 0 ]
    [ ! -f "$runtime_dir/runtime-service-$port.pid" ]
    [ ! -f "$runtime_dir/runtime-service-$port.token" ]
    [ ! -f "$runtime_dir/runtime-service.json" ]

    run grep -F -- "-0 999999" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-TERM $listener_pid" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-KILL $listener_pid" "$signals_log"
    [ "$status" -eq 1 ]
}

@test "write_debug_bundle_metadata stamps llm feature overrides into the debug app plist" {
    local debug_app="$TEST_DIR/CapacitorDebug.app"
    local plist="$debug_app/Contents/Info.plist"

    mkdir -p "$debug_app/Contents"
    write_minimal_plist "$plist"

    run env \
        /bin/bash -lc "
            CAPACITOR_RESTART_APP_SOURCE_ONLY=1
            CHANNEL='alpha'
            PROFILE='stable'
            SKIP_SETUP_VALIDATION='0'
            CAPACITOR_FEATURES_ENABLED='projectDetails,llmFeatures'
            CAPACITOR_FEATURES_DISABLED='delegationLoop'
            source '$SCRIPT_PATH'
            write_debug_bundle_metadata '$plist'
            /usr/libexec/PlistBuddy -c 'Print :CapacitorFeaturesEnabled' '$plist'
            /usr/libexec/PlistBuddy -c 'Print :CapacitorFeaturesDisabled' '$plist'
            /usr/libexec/PlistBuddy -c 'Print :CapacitorChannel' '$plist'
            /usr/libexec/PlistBuddy -c 'Print :CapacitorProfile' '$plist'
        "

    [ "$status" -eq 0 ]
    [[ "$output" == *"projectDetails,llmFeatures"* ]]
    [[ "$output" == *"delegationLoop"* ]]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"stable"* ]]
}

@test "build_sanitized_debug_app_env keeps agent host environment out of debug app launch" {
    run_restart_cleanup_shell '
USER="pete"
LOGNAME="pete"
HOME="$TEST_HOME"
SHELL="/bin/zsh"
TMPDIR="/tmp/capacitor-test"
LANG="en_US.UTF-8"
LC_CTYPE="UTF-8"
SSH_AUTH_SOCK="/tmp/ssh.sock"
__CF_USER_TEXT_ENCODING="0x1F5:0x0:0x0"
NO_COLOR="1"
TERM="dumb"
COLORTERM=""
CODEX_THREAD_ID="thread"
OPENAI_API_KEY="secret"
CAPACITOR_FEATURES_ENABLED="projectDetails"
source "$SCRIPT_PATH"
build_sanitized_debug_app_env
printf "%s\n" "${SANITIZED_APP_ENV[@]}"
'

    [ "$status" -eq 0 ]
    [[ "$output" == *"env"* ]]
    [[ "$output" == *"-i"* ]]
    [[ "$output" == *"HOME=$TEST_HOME"* ]]
    [[ "$output" == *"USER=pete"* ]]
    [[ "$output" == *"LOGNAME=pete"* ]]
    [[ "$output" == *"SHELL=/bin/zsh"* ]]
    [[ "$output" == *"TMPDIR=/tmp/capacitor-test"* ]]
    [[ "$output" == *"LANG=en_US.UTF-8"* ]]
    [[ "$output" == *"SSH_AUTH_SOCK=/tmp/ssh.sock"* ]]
    [[ "$output" == *"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"* ]]
    [[ "$output" != *"NO_COLOR"* ]]
    [[ "$output" != *"TERM=dumb"* ]]
    [[ "$output" != *"COLORTERM"* ]]
    [[ "$output" != *"LC_CTYPE"* ]]
    [[ "$output" != *"CODEX_THREAD_ID"* ]]
    [[ "$output" != *"OPENAI_API_KEY"* ]]
    [[ "$output" != *"CAPACITOR_FEATURES_ENABLED"* ]]
}

@test "restart script regenerates UniFFI bindings through the release target" {
    run grep -F -- "cargo run --release -p capacitor-core --bin uniffi-bindgen generate" "$SCRIPT_PATH"

    [ "$status" -eq 0 ]
}

@test "kill_stale_capacitor_daemon removes legacy daemon residue" {
    local signals_log="$TEST_DIR/daemon-signals.log"
    local launchctl_log="$TEST_DIR/launchctl.log"
    local daemon_state_file="$TEST_DIR/daemon-state"
    local daemon_root="$TEST_HOME/.capacitor/daemon"
    local launch_agent="$TEST_HOME/Library/LaunchAgents/com.capacitor.daemon.plist"

    mkdir -p "$daemon_root"
    mkdir -p "$(dirname "$launch_agent")"
    printf 'socket\n' > "$TEST_HOME/.capacitor/daemon.sock"
    printf 'legacy\n' > "$daemon_root/state.json"
    printf '<plist><dict/></plist>\n' > "$launch_agent"
    printf 'present\n' > "$daemon_state_file"

    run_restart_cleanup_shell '
sleep() { :; }
id() {
    if [[ "${1:-}" == "-u" ]]; then
        printf "501\n"
        return 0
    fi
    command id "$@"
}
launchctl() {
    printf "%s\n" "$*" >> "$LAUNCHCTL_LOG"
    return 0
}
pgrep() {
    if [[ "$(cat "$DAEMON_STATE_FILE")" == "present" ]]; then
        printf "5151\n"
        return 0
    fi
    return 1
}
pkill() {
    printf "%s\n" "$*" >> "$SIGNALS_LOG"
    if [[ "$(cat "$DAEMON_STATE_FILE")" == "present" ]]; then
        printf "gone\n" > "$DAEMON_STATE_FILE"
        return 0
    fi
    return 1
}
source "$SCRIPT_PATH"
kill_stale_capacitor_daemon
' \
        SIGNALS_LOG="$signals_log" \
        LAUNCHCTL_LOG="$launchctl_log" \
        DAEMON_STATE_FILE="$daemon_state_file"

    [ "$status" -eq 0 ]
    [ ! -f "$TEST_HOME/.capacitor/daemon.sock" ]
    [ ! -d "$daemon_root" ]
    [ ! -f "$launch_agent" ]

    run grep -F -- "bootout gui/501 $launch_agent" "$launchctl_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-TERM -f [c]apacitor-daemon" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-KILL -f [c]apacitor-daemon" "$signals_log"
    [ "$status" -eq 1 ]
}

@test "terminate_installed_release_capacitor removes the installed release app before debug launch" {
    local signals_log="$TEST_DIR/release-app-signals.log"
    local release_state_file="$TEST_DIR/release-app-state"
    local release_pid=4242

    printf 'present\n' > "$release_state_file"

    run_restart_cleanup_shell '
sleep() { :; }
kill() {
    printf "%s\n" "$*" >> "$SIGNALS_LOG"
    if [[ "$1" == "-0" ]]; then
        shift
        if [[ "${1:-}" == "$RELEASE_PID" && "$(cat "$RELEASE_STATE_FILE")" == "present" ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "${1:-}" == "-TERM" && "${2:-}" == "$RELEASE_PID" ]]; then
        printf "gone\n" > "$RELEASE_STATE_FILE"
    fi
    return 0
}
pgrep() {
    if [[ "${1:-}" == "-f" && "${2:-}" == "/Applications/Capacitor.app/Contents/MacOS/Capacitor$" ]]; then
        if [[ "$(cat "$RELEASE_STATE_FILE")" == "present" ]]; then
            printf "%s\n" "$RELEASE_PID"
        fi
        return 0
    fi
    return 1
}
source "$SCRIPT_PATH"
terminate_installed_release_capacitor
assert_no_installed_release_capacitor
' \
        SIGNALS_LOG="$signals_log" \
        RELEASE_STATE_FILE="$release_state_file" \
        RELEASE_PID="$release_pid"

    [ "$status" -eq 0 ]

    run grep -F -- "-TERM $release_pid" "$signals_log"
    [ "$status" -eq 0 ]
}

@test "terminate_non_debug_capacitor_processes removes all non-canonical Capacitor builds" {
    local signals_log="$TEST_DIR/non-debug-app-signals.log"
    local debug_binary="$TEST_DIR/CapacitorDebug.app/Contents/MacOS/Capacitor"
    local release_pid=4242
    local home_release_pid=4243
    local swift_run_pid=4244

    run_restart_cleanup_shell '
sleep() { :; }
kill() {
    printf "%s\n" "$*" >> "$SIGNALS_LOG"
    return 0
}
pgrep() {
    if [[ "${1:-}" == "-fl" && "${2:-}" == "/Capacitor$" ]]; then
        printf "%s\n" \
            "4000 $DEBUG_BINARY" \
            "$RELEASE_PID /Applications/Capacitor.app/Contents/MacOS/Capacitor" \
            "$HOME_RELEASE_PID /Users/pete/Applications/Capacitor.app/Contents/MacOS/Capacitor" \
            "$SWIFT_RUN_PID /Users/pete/Code/capacitor/apps/swift/.build/debug/Capacitor"
        return 0
    fi
    return 1
}
source "$SCRIPT_PATH"
terminate_non_debug_capacitor_processes "$DEBUG_BINARY"
' \
        SIGNALS_LOG="$signals_log" \
        DEBUG_BINARY="$debug_binary" \
        RELEASE_PID="$release_pid" \
        HOME_RELEASE_PID="$home_release_pid" \
        SWIFT_RUN_PID="$swift_run_pid"

    [ "$status" -eq 0 ]

    run grep -F -- "-TERM 4000" "$signals_log"
    [ "$status" -eq 1 ]

    run grep -F -- "-TERM $release_pid" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-TERM $home_release_pid" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-TERM $swift_run_pid" "$signals_log"
    [ "$status" -eq 0 ]
}

@test "assert_debug_app_frontmost can be relaxed for CI AX verification" {
    run_restart_cleanup_shell '
CAPACITOR_ALLOW_BACKGROUND_DEBUG_APP=1
frontmost_app_snapshot() {
    printf "%s\n%s\n%s\n" "Setup Assistant" "329" "/System/Library/CoreServices/Setup Assistant.app"
}
source "$SCRIPT_PATH"
assert_debug_app_frontmost "$TEST_DIR/CapacitorDebug.app" "7612"
' \
        TEST_DIR="$TEST_DIR"

    [ "$status" -eq 0 ]
}
