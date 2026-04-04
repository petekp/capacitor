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

copy_hook_installer() {
    local repo="$1"
    mkdir -p "$repo/scripts/dev"
    cp "$PROJECT_ROOT/scripts/dev/install-pre-commit-hook.sh" "$repo/scripts/dev/"
}

@test "pre-commit reruns verifier with changed-only compatible layers" {
    run env TEST_DIR="$TEST_DIR" PATH="$TEST_DIR/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash -c 'cd "$TEST_DIR" && ./scripts/dev/pre-commit'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Formal verification failed"* ]]
    run grep -c -- '--layers 1 --changed-only' "$TEST_DIR/verify-invocations.log"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]

    run grep -c -- '--layers 1 --changed-only --json' "$TEST_DIR/verify-invocations.log"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "installed hook dispatches to the current worktree script" {
    WORKTREE_DIR="$TEST_DIR-worktree"
    copy_hook_installer "$TEST_DIR"

    git -C "$TEST_DIR" worktree add --detach "$WORKTREE_DIR" >/dev/null
    copy_hook_installer "$WORKTREE_DIR"

    cat > "$TEST_DIR/scripts/dev/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'base\n' >> "$(git rev-parse --show-toplevel)/hook-dispatch.log"
EOF
    chmod +x "$TEST_DIR/scripts/dev/pre-commit"

    cat > "$WORKTREE_DIR/scripts/dev/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'worktree\n' >> "$(git rev-parse --show-toplevel)/hook-dispatch.log"
EOF
    chmod +x "$WORKTREE_DIR/scripts/dev/pre-commit"

    run env WORKTREE_DIR="$WORKTREE_DIR" PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash -c 'cd "$WORKTREE_DIR" && ./scripts/dev/install-pre-commit-hook.sh'
    [ "$status" -eq 0 ]

    HOOK_PATH="$(git -C "$WORKTREE_DIR" rev-parse --git-path hooks/pre-commit)"

    run env WORKTREE_DIR="$WORKTREE_DIR" HOOK_PATH="$HOOK_PATH" PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash -c 'cd "$WORKTREE_DIR" && "$HOOK_PATH"'
    [ "$status" -eq 0 ]

    [ ! -f "$TEST_DIR/hook-dispatch.log" ]
    run cat "$WORKTREE_DIR/hook-dispatch.log"
    [ "$status" -eq 0 ]
    [ "$output" = "worktree" ]
}
