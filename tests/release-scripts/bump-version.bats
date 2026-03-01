#!/usr/bin/env bats

# Tests for bump-version.sh
# Run with: bats tests/release-scripts/bump-version.bats
# Install bats: brew install bats-core

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # Create a mock project structure
    mkdir -p "$TEST_DIR/scripts"
    cp "$PROJECT_ROOT/scripts/release/bump-version.sh" "$TEST_DIR/scripts/"

    # Create mock VERSION file
    echo "1.2.3" > "$TEST_DIR/VERSION"

    # Create mock Cargo.toml
    cat > "$TEST_DIR/Cargo.toml" << 'EOF'
[workspace]
members = ["core"]

[workspace.package]
version = "1.2.3"
EOF

    # Patch the script to use TEST_DIR as PROJECT_ROOT
    sed -i '' "s|PROJECT_ROOT=\"\$(cd \"\$SCRIPT_DIR/../..\" && pwd)\"|PROJECT_ROOT=\"$TEST_DIR\"|" "$TEST_DIR/scripts/bump-version.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

run_bump_and_assert_version() {
    local bump="$1"
    local expected="$2"

    run "$TEST_DIR/scripts/bump-version.sh" "$bump"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/VERSION")" = "$expected" ]
}

@test "shows usage when no argument provided" {
    run "$TEST_DIR/scripts/bump-version.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "patch bump increments patch version" {
    run_bump_and_assert_version patch "1.2.4"
}

@test "minor bump increments minor and resets patch" {
    run_bump_and_assert_version minor "1.3.0"
}

@test "major bump increments major and resets minor and patch" {
    run_bump_and_assert_version major "2.0.0"
}

@test "explicit version sets exact version" {
    run_bump_and_assert_version "5.0.0" "5.0.0"
}

@test "updates Cargo.toml workspace version" {
    run "$TEST_DIR/scripts/bump-version.sh" patch
    [ "$status" -eq 0 ]
    run grep 'version = "1.2.4"' "$TEST_DIR/Cargo.toml"
    [ "$status" -eq 0 ]
}

@test "rejects invalid version format" {
    for input in "invalid" "1.2"; do
        run "$TEST_DIR/scripts/bump-version.sh" "$input"
        [ "$status" -eq 1 ]
        [[ "$output" == *"Invalid version format"* ]]
    done
}

@test "handles version 0.0.0 correctly" {
    echo "0.0.0" > "$TEST_DIR/VERSION"
    run "$TEST_DIR/scripts/bump-version.sh" patch
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/VERSION")" = "0.0.1" ]
}

@test "fails gracefully when VERSION file missing" {
    rm "$TEST_DIR/VERSION"
    run "$TEST_DIR/scripts/bump-version.sh" patch
    [ "$status" -eq 1 ]
    [[ "$output" == *"VERSION file not found"* ]]
}
