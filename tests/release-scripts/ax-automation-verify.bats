#!/usr/bin/env bats

# Tests for ax-automation-verify.sh
# Run with: bats tests/release-scripts/ax-automation-verify.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/ci" "$TEST_DIR/apps/swift" "$TEST_DIR/core"
    cp "$PROJECT_ROOT/scripts/ci/ax-automation-verify.sh" "$TEST_DIR/scripts/ci/"
    chmod +x "$TEST_DIR/scripts/ci/ax-automation-verify.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "prepare_projects_file seeds a two-project file when no projects.json exists" {
    run env HOME="$TEST_DIR/home" /bin/bash -lc "
        source '$TEST_DIR/scripts/ci/ax-automation-verify.sh'
        prepared=\$(prepare_projects_file '$TEST_DIR/run')
        jq -er '.pinned_projects | length == 2' \"\$prepared\" >/dev/null
        printf '%s\n' \"\$prepared\"
    "

    [ "$status" -eq 0 ]
    [[ "$output" == *"$TEST_DIR/run/projects.seed.json"* ]]
}

@test "ensure_claude_cli_for_runtime can install a claude stub for CI-style setup checks" {
    run env \
        HOME="$TEST_DIR/home" \
        AX_VERIFY_CLAUDE_STUB_DIR="$TEST_DIR/claude-bin" \
        AX_VERIFY_FORCE_CLAUDE_STUB=1 \
        /bin/bash -lc "
            source '$TEST_DIR/scripts/ci/ax-automation-verify.sh'
            ensure_claude_cli_for_runtime
            test -x '$TEST_DIR/claude-bin/claude'
        "

    [ "$status" -eq 0 ]
}

@test "ideas seeding installs one primary-project idea and restores the original file" {
    mkdir -p "$TEST_DIR/home/.capacitor"
    printf '%s\n' '{"ideas":[{"projectPath":"/preserve","title":"keep"}]}' > "$TEST_DIR/home/.capacitor/ideas.json"

    run env HOME="$TEST_DIR/home" /bin/bash -lc "
        source '$TEST_DIR/scripts/ci/ax-automation-verify.sh'
        prepared_projects=\$(prepare_projects_file '$TEST_DIR/run')
        prepared_ideas=\$(prepare_ideas_file '$TEST_DIR/run' \"\$prepared_projects\")
        primary_path=\$(jq -r '.pinned_projects[0]' \"\$prepared_projects\")

        jq -er --arg p \"\$primary_path\" '.ideas | length == 1 and .[0].projectPath == \$p' \"\$prepared_ideas\" >/dev/null

        restore_mode=\$(install_runtime_ideas_file '$TEST_DIR/run' \"\$prepared_ideas\")
        jq -er --arg p \"\$primary_path\" '.ideas | length == 1 and .[0].projectPath == \$p' '$TEST_DIR/home/.capacitor/ideas.json' >/dev/null
        restore_runtime_ideas_file '$TEST_DIR/run' \"\$restore_mode\"

        restored=\$(cat '$TEST_DIR/home/.capacitor/ideas.json')
        [[ \"\$restored\" == '{\"ideas\":[{\"projectPath\":\"/preserve\",\"title\":\"keep\"}]}' ]]
    "

    [ "$status" -eq 0 ]
}

@test "method runner is a first-class phase with independent log classification" {
    mkdir -p "$TEST_DIR/artifacts"
    printf '%s\n' 'Timed out waiting 12.0s for AX identifier' > "$TEST_DIR/artifacts/non-demo-ax-smoke-method-runner-fixture.log"

    run env HOME="$TEST_DIR/home" /bin/bash -lc "
        source '$TEST_DIR/scripts/ci/ax-automation-verify.sh'
        skip_details=0
        phases=()
        while IFS= read -r phase; do
            phases+=(\"\$phase\")
        done < <(expected_phases)
        [[ \"\${phases[*]}\" == 'cards details method_runner' ]]

        phase_log=\$(collect_phase_log '$TEST_DIR/artifacts' method_runner)
        [[ \"\$phase_log\" == *'non-demo-ax-smoke-method-runner-fixture.log' ]]
        [[ \"\$(classify_phase_failure \"\$phase_log\")\" == 'timeout' ]]
    "

    [ "$status" -eq 0 ]
}

@test "allow-untrusted treats missing AX windows as an environmental skip" {
    run env HOME="$TEST_DIR/home" /bin/bash -lc "
        source '$TEST_DIR/scripts/ci/ax-automation-verify.sh'
        allow_untrusted=1
        reason=no_ax_windows
        if [[ \"\$allow_untrusted\" -eq 1 ]] && is_allowed_ax_environment_skip \"\$reason\"; then
            exit 0
        fi
        exit 1
    "

    [ "$status" -eq 0 ]
}
