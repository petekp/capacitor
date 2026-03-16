#!/usr/bin/env bats

# Tests for the pre-commit hook.
# Run with: bats tests/release-scripts/pre-commit.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/dev" "$TEST_DIR/scripts/verify" "$TEST_DIR/fake-bin"
    cp "$PROJECT_ROOT/scripts/dev/pre-commit" "$TEST_DIR/scripts/dev/"
    chmod +x "$TEST_DIR/scripts/dev/pre-commit"

    cat > "$TEST_DIR/scripts/verify/verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

printf '%s\n' "$*" >> "$PROJECT_ROOT/verify-invocations.log"

if [[ "$*" == *"--layers 1,2,3"* && "$*" == *"--changed-only"* ]]; then
  echo "Layer 2 does not support path-scoped runs. Use --layers 1,3 or drop --changed-only." >&2
  exit 2
fi

if [[ "$*" == *"--json"* ]]; then
  printf '{"layer_results":{"1":{"status":"failed"}}}\n'
  exit 0
fi

echo "synthetic verifier failure" >&2
exit 1
EOF
    chmod +x "$TEST_DIR/scripts/verify/verify.sh"

    cat > "$TEST_DIR/fake-bin/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_DIR/fake-bin/cargo"

    cat > "$TEST_DIR/fake-bin/swiftformat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_DIR/fake-bin/swiftformat"

    git -C "$TEST_DIR" init -q
    git -C "$TEST_DIR" config user.email "pre-commit-tests@example.com"
    git -C "$TEST_DIR" config user.name "Pre-commit Tests"
    printf '# Fixture\n' > "$TEST_DIR/README.md"
    git -C "$TEST_DIR" add README.md
    git -C "$TEST_DIR" commit -qm "fixture"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "pre-commit reruns verifier with changed-only compatible layers" {
    run env TEST_DIR="$TEST_DIR" PATH="$TEST_DIR/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash -c 'cd "$TEST_DIR" && ./scripts/dev/pre-commit'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Formal verification failed"* ]]
    [[ "$output" != *"Layer 2 does not support path-scoped runs"* ]]

    run grep -c -- '--layers 1,3 --changed-only' "$TEST_DIR/verify-invocations.log"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]

    run grep -c -- '--layers 1,3 --changed-only --json' "$TEST_DIR/verify-invocations.log"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}
