#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    RUNTIME_STATE_FILE="$(mktemp)"
}

teardown() {
    rm -f "$RUNTIME_STATE_FILE"
}

@test "restart-app --help is available and documents profile flag" {
    run env \
        CAPACITOR_RUNTIME_STATE_FILE="$RUNTIME_STATE_FILE" \
        CAPACITOR_RUNTIME_STATE_PERSIST=0 \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: restart-app.sh [OPTIONS]"* ]]
    [[ "$output" == *"--profile <stable|frontier>"* ]]
}

@test "restart-app rejects invalid profile before build steps" {
    run env \
        CAPACITOR_RUNTIME_STATE_FILE="$RUNTIME_STATE_FILE" \
        CAPACITOR_RUNTIME_STATE_PERSIST=0 \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh" --profile nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid profile"* ]]
}

@test "restart-app blocks non-alpha channel in enforced dev mode" {
    run env \
        CAPACITOR_RUNTIME_STATE_FILE="$RUNTIME_STATE_FILE" \
        CAPACITOR_RUNTIME_STATE_PERSIST=0 \
        CAPACITOR_ENFORCE_ALPHA_ONLY=1 \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh" --channel beta --profile stable
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to launch non-alpha channel 'beta'"* ]]
}

@test "restart wrappers expose restart-app help path" {
    run "$PROJECT_ROOT/scripts/dev/restart-alpha-stable.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: restart-app.sh [OPTIONS]"* ]]

    run "$PROJECT_ROOT/scripts/dev/restart-alpha-frontier.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: restart-app.sh [OPTIONS]"* ]]

    run "$PROJECT_ROOT/scripts/dev/restart-current.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: restart-app.sh [OPTIONS]"* ]]
}

@test "restart-app help documents runtime default precedence" {
    run env \
        CAPACITOR_RUNTIME_STATE_FILE="$RUNTIME_STATE_FILE" \
        CAPACITOR_RUNTIME_STATE_PERSIST=0 \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Defaults come from:"* ]]
    [[ "$output" == *"alpha + stable"* ]]
    [[ "$output" == *"$RUNTIME_STATE_FILE"* ]]
}
