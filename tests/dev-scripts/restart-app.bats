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

@test "kill_stale_capacitor_daemon removes legacy daemon residue" {
    local signals_log="$TEST_DIR/daemon-signals.log"
    local daemon_state_file="$TEST_DIR/daemon-state"
    local daemon_root="$TEST_HOME/.capacitor/daemon"

    mkdir -p "$daemon_root"
    printf 'socket\n' > "$TEST_HOME/.capacitor/daemon.sock"
    printf 'legacy\n' > "$daemon_root/state.json"
    printf 'present\n' > "$daemon_state_file"

    run_restart_cleanup_shell '
sleep() { :; }
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
        DAEMON_STATE_FILE="$daemon_state_file"

    [ "$status" -eq 0 ]
    [ ! -f "$TEST_HOME/.capacitor/daemon.sock" ]
    [ ! -d "$daemon_root" ]

    run grep -F -- "-TERM -f [c]apacitor-daemon" "$signals_log"
    [ "$status" -eq 0 ]

    run grep -F -- "-KILL -f [c]apacitor-daemon" "$signals_log"
    [ "$status" -eq 1 ]
}
