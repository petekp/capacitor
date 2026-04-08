#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/relay" "$TEST_DIR/bin"
    cp "$PROJECT_ROOT/scripts/relay/dispatch.sh" "$TEST_DIR/scripts/relay/"
    chmod +x "$TEST_DIR/scripts/relay/dispatch.sh"

    cat > "$TEST_DIR/prompt.md" <<'EOF'
# Prompt
Ship the feature.
EOF
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "dispatch executes a custom backend whose executable path contains spaces" {
    local backend_dir="$TEST_DIR/custom backend"
    local backend_path="$backend_dir/worker.sh"
    mkdir -p "$backend_dir"

    cat > "$backend_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'prompt=%s\noutput=%s\n' "$1" "$2" > "$2"
EOF
    chmod +x "$backend_path"

    run "$TEST_DIR/scripts/relay/dispatch.sh" \
        --prompt "$TEST_DIR/prompt.md" \
        --output "$TEST_DIR/result.txt" \
        --backend "$backend_path"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/result.txt" ]
    grep -Fq "prompt=$TEST_DIR/prompt.md" "$TEST_DIR/result.txt"
    grep -Fq "output=$TEST_DIR/result.txt" "$TEST_DIR/result.txt"
}

@test "dispatch still supports custom backend command strings with flags" {
    cat > "$TEST_DIR/bin/fake-backend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
flag="$1"
shift
printf 'flag=%s\nprompt=%s\noutput=%s\n' "$flag" "$1" "$2" > "$2"
EOF
    chmod +x "$TEST_DIR/bin/fake-backend"

    run env PATH="$TEST_DIR/bin:$PATH" "$TEST_DIR/scripts/relay/dispatch.sh" \
        --prompt "$TEST_DIR/prompt.md" \
        --output "$TEST_DIR/result.txt" \
        --backend "fake-backend --ephemeral"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/result.txt" ]
    grep -Fq "flag=--ephemeral" "$TEST_DIR/result.txt"
    grep -Fq "prompt=$TEST_DIR/prompt.md" "$TEST_DIR/result.txt"
    grep -Fq "output=$TEST_DIR/result.txt" "$TEST_DIR/result.txt"
}
