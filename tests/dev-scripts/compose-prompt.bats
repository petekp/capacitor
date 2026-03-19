#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    TEST_HOME="$TEST_DIR/home"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p \
        "$TEST_DIR/scripts/relay" \
        "$TEST_DIR/out" \
        "$TEST_HOME/.claude/skills/manage-codex/references"

    cp "$PROJECT_ROOT/scripts/relay/compose-prompt.sh" "$TEST_DIR/scripts/relay/"
    chmod +x "$TEST_DIR/scripts/relay/compose-prompt.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_fixture() {
    local path="$1"

    mkdir -p "$(dirname "$path")"
    cat > "$path"
}

run_compose_prompt() {
    run env HOME="$TEST_HOME" "$TEST_DIR/scripts/relay/compose-prompt.sh" "$@"
}

@test "substitutes relay_root across assembled prompt when root is supplied" {
    local root_dir="$TEST_DIR/root & pipes|demo"

    mkdir -p "$root_dir"

    write_fixture "$TEST_DIR/header.md" <<'EOF'
# Header
Header root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/demo/SKILL.md" <<'EOF'
# Demo Skill
Skill root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/implement-template.md" <<'EOF'
# Template
Template root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/relay-protocol.md" <<'EOF'
# Relay Protocol
Protocol root: {relay_root}
EOF

    run_compose_prompt \
        --header "$TEST_DIR/header.md" \
        --skills "demo" \
        --template implement \
        --root "$root_dir" \
        --out "$TEST_DIR/out/prompt.md"

    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/out/prompt.md" ]
    grep -Fq "Header root: $root_dir" "$TEST_DIR/out/prompt.md"
    grep -Fq "Skill root: $root_dir" "$TEST_DIR/out/prompt.md"
    grep -Fq "Template root: $root_dir" "$TEST_DIR/out/prompt.md"
    grep -Fq "Protocol root: $root_dir" "$TEST_DIR/out/prompt.md"

    run grep -F "{relay_root}" "$TEST_DIR/out/prompt.md"
    [ "$status" -eq 1 ]
}

@test "fails closed when relay_root remains unresolved and root is omitted" {
    write_fixture "$TEST_DIR/header.md" <<'EOF'
# Header
No placeholders here.
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/implement-template.md" <<'EOF'
# Template
Template root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/relay-protocol.md" <<'EOF'
# Relay Protocol
No placeholders here either.
EOF

    run_compose_prompt \
        --header "$TEST_DIR/header.md" \
        --template implement \
        --out "$TEST_DIR/out/prompt.md"

    [ "$status" -ne 0 ]
    [[ "$output" == *"{relay_root}"* ]]
    [[ "$output" == *"implement-template.md"* ]]
}

@test "legacy templates without relay_root still compose without root" {
    write_fixture "$TEST_DIR/header.md" <<'EOF'
# Header
Legacy header.
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/implement-template.md" <<'EOF'
# Template
Legacy template.
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/relay-protocol.md" <<'EOF'
# Relay Protocol
Legacy protocol.
EOF

    run_compose_prompt \
        --header "$TEST_DIR/header.md" \
        --template implement \
        --out "$TEST_DIR/out/prompt.md"

    [ "$status" -eq 0 ]
    grep -Fq "Legacy header." "$TEST_DIR/out/prompt.md"
    grep -Fq "Legacy template." "$TEST_DIR/out/prompt.md"
    grep -Fq "Legacy protocol." "$TEST_DIR/out/prompt.md"
}
