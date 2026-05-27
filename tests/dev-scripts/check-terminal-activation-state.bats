#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT_PATH="$PROJECT_ROOT/scripts/dev/check-terminal-activation-state.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "recent_terminal_activation_trace hides Swift test fixture paths" {
    local log_path="$TEST_DIR/app-debug.log"

    cat > "$log_path" <<'EOF'
2026-05-26T10:00:00Z [TerminalActivation] route="direct_focus" project_path="/Users/petepetrash/Code/pete-2025" outcome="focused"
2026-05-26T10:00:01Z [TerminalActivation] route="direct_focus" project_path="/tmp/project/.capacitor/worktrees/batch-mobile" outcome="focused"
2026-05-26T10:00:02Z [TerminalActivation] route="tmux_client" project_path="/path/to/project" outcome="none"
2026-05-26T10:00:03Z [TerminalActivation] route="launch" project_path="/other" outcome="launched"
2026-05-26T10:00:04Z [TerminalActivation] route="launch" project_path="/broken" outcome="failed"
2026-05-26T10:00:05Z [TerminalActivation] route="launch" project_path="/new" outcome="launched"
2026-05-26T10:00:06Z [TerminalActivation] route="launch" project_path="/var/folders/ab/cd/T/TerminalActivationCoordinatorTests/project/.capacitor/worktrees/batch-mobile" outcome="launched"
2026-05-26T10:00:07Z [TerminalActivation] route="launch" project_path="/tmp/coordinator-project" outcome="launched"
2026-05-26T10:00:08Z [TerminalActivation] route="direct_focus" project_path="/Users/pete/Code/parable-school" outcome="focused"
2026-05-26T10:00:09Z [TerminalActivation] surface="work_batch_card" route="work_batch_cockpit" action="open_cockpit" outcome="blocked_no_binding" batch_id="batch-mobile" batch="Mobile prototype" evidence="missing_binding"
EOF

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS=0 \
        SCRIPT_PATH="$SCRIPT_PATH" \
        TRACE_LOG="$log_path" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; recent_terminal_activation_trace "$TRACE_LOG"'

    [ "$status" -eq 0 ]
    [[ "$output" == *'project_path="/Users/petepetrash/Code/pete-2025"'* ]]
    [[ "$output" != *"/tmp/project"* ]]
    [[ "$output" != *"/path/to/project"* ]]
    [[ "$output" != *"/other"* ]]
    [[ "$output" != *"/broken"* ]]
    [[ "$output" != *"/new"* ]]
    [[ "$output" != *"/var/folders/"* ]]
    [[ "$output" != *"/tmp/coordinator-project"* ]]
    [[ "$output" != *"/Users/pete/Code/"* ]]
    [[ "$output" != *'batch_id="batch-mobile"'* ]]
}

@test "recent_terminal_activation_trace hides stale live traces by default window" {
    local log_path="$TEST_DIR/app-debug.log"

    cat > "$log_path" <<'EOF'
[1970-01-01T00:00:00.000Z] [TerminalActivation] route="direct_focus" project_path="/Users/petepetrash/Code/stale-project" outcome="focused"
[1970-01-01T00:30:01.000Z] [TerminalActivation] route="direct_focus" project_path="/Users/petepetrash/Code/recent-project" outcome="focused"
EOF

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_TERMINAL_TRACE_NOW_EPOCH=3600 \
        CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS=1800 \
        SCRIPT_PATH="$SCRIPT_PATH" \
        TRACE_LOG="$log_path" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; recent_terminal_activation_trace "$TRACE_LOG"'

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Users/petepetrash/Code/recent-project"* ]]
    [[ "$output" != *"/Users/petepetrash/Code/stale-project"* ]]
}

@test "release_capacitor_guard fails when any non-Debug Capacitor build is running" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; release_capacitor_guard "2134 /Users/pete/Applications/Capacitor.app/Contents/MacOS/Capacitor"'

    [ "$status" -eq 2 ]
    [[ "$output" == *"non-Debug Capacitor build is running"* ]]
    [[ "$output" == *"Use the Debug app bundle explicitly"* ]]
}

@test "release_capacitor_guard allows explicit release-app override" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_ALLOW_RELEASE_CAPACITOR_DURING_DEBUG=1 \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; release_capacitor_guard "2134 /Applications/Capacitor.app/Contents/MacOS/Capacitor"'

    [ "$status" -eq 0 ]
}

@test "non_debug_capacitor_processes excludes only the canonical Debug app process" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc '
            source "$SCRIPT_PATH"
            pgrep() {
                if [[ "${1:-}" == "-fl" && "${2:-}" == "/Capacitor$" ]]; then
                    printf "%s\n" \
                        "100 $CAPACITOR_DEBUG_APP_PATH/Contents/MacOS/Capacitor" \
                        "200 /Applications/Capacitor.app/Contents/MacOS/Capacitor" \
                        "300 /Users/pete/Applications/Capacitor.app/Contents/MacOS/Capacitor" \
                        "400 /Users/pete/Code/capacitor/apps/swift/.build/debug/Capacitor"
                    return 0
                fi
                return 1
            }
            non_debug_capacitor_processes
        '

    [ "$status" -eq 0 ]
    [[ "$output" != *"100 "* ]]
    [[ "$output" == *"200 /Applications/Capacitor.app/Contents/MacOS/Capacitor"* ]]
    [[ "$output" == *"300 /Users/pete/Applications/Capacitor.app/Contents/MacOS/Capacitor"* ]]
    [[ "$output" == *"400 /Users/pete/Code/capacitor/apps/swift/.build/debug/Capacitor"* ]]
}

@test "debug_process_guard fails when the Debug app is missing" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; debug_process_guard ""'

    [ "$status" -eq 3 ]
    [[ "$output" == *"Capacitor Debug is not running"* ]]
    [[ "$output" == *"restart-alpha-stable.sh"* ]]
}

@test "debug_build_freshness_guard fails when Swift sources are newer than the Debug app" {
    local debug_app="$TEST_DIR/CapacitorDebug.app"
    local swift_sources="$TEST_DIR/swift-sources"

    mkdir -p "$debug_app/Contents/MacOS" "$debug_app/Contents/Frameworks" "$debug_app/Contents/Resources" "$swift_sources"
    touch -t 202601010000 "$debug_app/Contents/MacOS/Capacitor"
    touch -t 202601010100 "$swift_sources/App.swift"

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$debug_app" \
        CAPACITOR_SWIFT_SOURCE_ROOT="$swift_sources" \
        CAPACITOR_CORE_RUST_SOURCE_ROOT="$TEST_DIR/missing-core" \
        CAPACITOR_HUD_HOOK_RUST_SOURCE_ROOT="$TEST_DIR/missing-hook" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; debug_build_freshness_guard'

    [ "$status" -eq 7 ]
    [[ "$output" == *"Capacitor Debug build is stale"* ]]
    [[ "$output" == *"newer_source: $swift_sources/App.swift"* ]]
    [[ "$output" == *"restart-alpha-stable.sh"* ]]
}

@test "debug_build_freshness_guard passes when sources are older than the Debug app" {
    local debug_app="$TEST_DIR/CapacitorDebug.app"
    local swift_sources="$TEST_DIR/swift-sources"

    mkdir -p "$debug_app/Contents/MacOS" "$debug_app/Contents/Frameworks" "$debug_app/Contents/Resources" "$swift_sources"
    touch -t 202601010100 "$debug_app/Contents/MacOS/Capacitor"
    touch -t 202601010000 "$swift_sources/App.swift"

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$debug_app" \
        CAPACITOR_SWIFT_SOURCE_ROOT="$swift_sources" \
        CAPACITOR_CORE_RUST_SOURCE_ROOT="$TEST_DIR/missing-core" \
        CAPACITOR_HUD_HOOK_RUST_SOURCE_ROOT="$TEST_DIR/missing-hook" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; debug_build_freshness_guard'

    [ "$status" -eq 0 ]
}

@test "debug_build_freshness_guard allows an explicit stale-build override" {
    local debug_app="$TEST_DIR/CapacitorDebug.app"
    local swift_sources="$TEST_DIR/swift-sources"

    mkdir -p "$debug_app/Contents/MacOS" "$swift_sources"
    touch -t 202601010000 "$debug_app/Contents/MacOS/Capacitor"
    touch -t 202601010100 "$swift_sources/App.swift"

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_ALLOW_STALE_DEBUG_BUILD=1 \
        CAPACITOR_DEBUG_APP_PATH="$debug_app" \
        CAPACITOR_SWIFT_SOURCE_ROOT="$swift_sources" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; debug_build_freshness_guard'

    [ "$status" -eq 0 ]
}

@test "frontmost_capacitor_guard fails when the release app is frontmost" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; frontmost_capacitor_guard "Capacitor" "/Applications/Capacitor.app"'

    [ "$status" -eq 4 ]
    [[ "$output" == *"frontmost Capacitor app is not the Debug build"* ]]
    [[ "$output" == *"/Applications/Capacitor.app"* ]]
}

@test "frontmost_capacitor_guard fails when a Capacitor identity has no provable debug path" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; frontmost_capacitor_guard "Capacitor Debug" ""'

    [ "$status" -eq 5 ]
    [[ "$output" == *"could not be proven to be Debug"* ]]
}

@test "require_debug_frontmost_guard fails when strict mode is enabled and another app is frontmost" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_REQUIRE_DEBUG_FRONTMOST=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; require_debug_frontmost_guard "Codex" "/Applications/Codex.app"'

    [ "$status" -eq 6 ]
    [[ "$output" == *"Capacitor Debug is not frontmost"* ]]
}

@test "strict build guards pass for a running frontmost Debug app" {
    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_REQUIRE_DEBUG_FRONTMOST=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; debug_process_guard "4242 $CAPACITOR_DEBUG_APP_PATH/Contents/MacOS/Capacitor"; frontmost_capacitor_guard "Capacitor Debug" "$CAPACITOR_DEBUG_APP_PATH"; require_debug_frontmost_guard "Capacitor Debug" "$CAPACITOR_DEBUG_APP_PATH"'

    [ "$status" -eq 0 ]
}

@test "activate_debug_app focuses the running Debug process by pid" {
    local osascript_log="$TEST_DIR/osascript.log"

    run env \
        CAPACITOR_CHECK_TERMINAL_ACTIVATION_SOURCE_ONLY=1 \
        CAPACITOR_DEBUG_APP_PATH="$TEST_DIR/CapacitorDebug.app" \
        SCRIPT_PATH="$SCRIPT_PATH" \
        OSASCRIPT_LOG="$osascript_log" \
        /bin/bash -lc 'source "$SCRIPT_PATH"; osascript() { printf "%s\n" "$*" > "$OSASCRIPT_LOG"; }; sleep() { :; }; activate_debug_app "4242 $CAPACITOR_DEBUG_APP_PATH/Contents/MacOS/Capacitor"'

    [ "$status" -eq 0 ]
    run grep -F -- "unix id is 4242" "$osascript_log"
    [ "$status" -eq 0 ]
}
