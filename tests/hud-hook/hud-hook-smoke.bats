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

@test "hud-hook handle exits cleanly with empty input" {
    run "$HUD_HOOK_BIN" handle < /dev/null
    [ "$status" -eq 0 ]
}

@test "hud-hook cwd fails fast when runtime disabled" {
    run env CAPACITOR_CORE_ENABLED=0 "$HUD_HOOK_BIN" cwd /tmp 123 /dev/ttys001
    [ "$status" -eq 1 ]
    [[ "$output" == *"Core runtime disabled"* ]]
}
