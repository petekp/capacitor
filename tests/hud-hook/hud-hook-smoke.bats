#!/usr/bin/env bats

# Smoke tests for the hud-hook binary.
# Run with: bats tests/hud-hook/hud-hook-smoke.bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HUD_HOOK_BIN="$PROJECT_ROOT/target/release/hud-hook"
}

@test "hud-hook --help shows usage" {
    run "$HUD_HOOK_BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"hud-hook"* ]]
}

@test "hud-hook serve starts and responds to health check" {
    # Start server on a random high port
    local port=17474
    "$HUD_HOOK_BIN" serve --port "$port" &
    local server_pid=$!
    trap "kill $server_pid 2>/dev/null; wait $server_pid 2>/dev/null" EXIT

    # Wait for server to become ready
    for i in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    run curl -sf "http://127.0.0.1:$port/health"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"ok"'* ]]

    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null || true
    trap - EXIT
}

@test "hud-hook cwd fails fast when runtime disabled" {
    run env CAPACITOR_CORE_ENABLED=0 "$HUD_HOOK_BIN" cwd /tmp 123 /dev/ttys001
    [ "$status" -eq 1 ]
    [[ "$output" == *"Core runtime disabled"* ]]
}
