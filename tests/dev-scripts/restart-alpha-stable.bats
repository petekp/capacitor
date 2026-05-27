#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT_DIR="$TEST_DIR/scripts/dev"

    mkdir -p "$SCRIPT_DIR"
    cp "$PROJECT_ROOT/scripts/dev/restart-alpha-stable.sh" "$SCRIPT_DIR/"
    chmod +x "$SCRIPT_DIR/restart-alpha-stable.sh"

    cat > "$SCRIPT_DIR/restart-app.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'CAPACITOR_CHANNEL=%s\n' "${CAPACITOR_CHANNEL:-}"
printf 'CAPACITOR_PROFILE=%s\n' "${CAPACITOR_PROFILE:-}"
printf 'CAPACITOR_FEATURES_ENABLED=%s\n' "${CAPACITOR_FEATURES_ENABLED:-}"
printf 'CAPACITOR_FEATURES_DISABLED=%s\n' "${CAPACITOR_FEATURES_DISABLED:-}"
printf 'ARGS=%s\n' "$*"
EOF
    chmod +x "$SCRIPT_DIR/restart-app.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "restart-alpha-stable injects the Task-first feature overrides for the recommended flow" {
    run env -i \
        HOME="$TEST_DIR/home" \
        PATH="$PATH" \
        /bin/bash "$SCRIPT_DIR/restart-alpha-stable.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"CAPACITOR_FEATURES_ENABLED=projectDetails,ideaCapture,llmFeatures"* ]]
    [[ "$output" == *"ARGS=--channel alpha --profile stable"* ]]
}

@test "restart-alpha-stable strips forced-on features from conflicting disables" {
    run env -i \
        HOME="$TEST_DIR/home" \
        PATH="$PATH" \
        CAPACITOR_FEATURES_DISABLED="projectDetails,ideaCapture,llmFeatures" \
        /bin/bash "$SCRIPT_DIR/restart-alpha-stable.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"CAPACITOR_FEATURES_ENABLED=projectDetails,ideaCapture,llmFeatures"* ]]
    # All forced-on flags must be stripped from the disabled list.
    [[ "$output" == *"CAPACITOR_FEATURES_DISABLED="* ]]
}

@test "restart-alpha-stable handles FEATURES_DISABLED with only forced-on features" {
    run env -i \
        HOME="$TEST_DIR/home" \
        PATH="$PATH" \
        CAPACITOR_FEATURES_DISABLED="projectDetails,ideaCapture,llmFeatures" \
        /bin/bash "$SCRIPT_DIR/restart-alpha-stable.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"CAPACITOR_FEATURES_ENABLED=projectDetails,ideaCapture,llmFeatures"* ]]
    # All disabled flags stripped — result should be empty.
    [[ "$output" == *"CAPACITOR_FEATURES_DISABLED="* ]]
}
