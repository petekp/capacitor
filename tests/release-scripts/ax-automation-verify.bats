#!/usr/bin/env bats

# Tests for ax-automation-verify.sh
# Run with: bats tests/release-scripts/ax-automation-verify.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/ci" "$TEST_DIR/apps/swift" "$TEST_DIR/core"
    cp "$PROJECT_ROOT/scripts/ci/ax-automation-verify.sh" "$TEST_DIR/scripts/ci/"
    chmod +x "$TEST_DIR/scripts/ci/ax-automation-verify.sh"

    cat > "$TEST_DIR/scripts/ci/fake-non-demo-ax-smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

artifacts_dir=""
projects_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifacts-dir)
            artifacts_dir="$2"
            shift 2
            ;;
        --projects-file)
            projects_file="$2"
            shift 2
            ;;
        --skip-details)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

jq -er '.pinned_projects | length == 2' "$projects_file" >/dev/null
jq -er '.pinned_projects | length == 2' "$HOME/.capacitor/projects.json" >/dev/null
mkdir -p "$artifacts_dir"
printf '%s\n' '{"event":"runner.complete"}' > "$artifacts_dir/non-demo-ax-smoke-cards-fixture.log"
EOF
    chmod +x "$TEST_DIR/scripts/ci/fake-non-demo-ax-smoke.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "ax verifier seeds a two-project file when no projects.json exists" {
    run env \
        HOME="$TEST_DIR/home" \
        AX_AUTOMATION_SMOKE_SCRIPT="$TEST_DIR/scripts/ci/fake-non-demo-ax-smoke.sh" \
        /bin/bash -lc "cd '$TEST_DIR' && bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details --artifacts-dir '$TEST_DIR/artifacts'"

    [ "$status" -eq 0 ]
    [[ "$output" == *"runs_requested=1"* ]]
    [[ "$output" == *"runs_passed=1"* ]]
    [[ "$output" == *"first_failure_context=none"* ]]
}
