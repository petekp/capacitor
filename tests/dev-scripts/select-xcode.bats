#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT_PATH="$PROJECT_ROOT/scripts/ci/select-xcode.sh"

    mkdir -p "$TEST_DIR/bin"
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_xcrun_shim() {
    local good_developer_dir="$1"

    cat > "$TEST_DIR/bin/xcrun" <<EOF
#!/usr/bin/env bash
if [[ "\${DEVELOPER_DIR:-}" == "$good_developer_dir" ]]; then
    echo "\$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/xcrun"
}

@test "select-xcode skips stale candidates and selects one that can find clang" {
    local missing="$TEST_DIR/missing/Contents/Developer"
    local stale="$TEST_DIR/stale/Contents/Developer"
    local usable="$TEST_DIR/usable/Contents/Developer"

    mkdir -p "$stale" "$usable"
    write_xcrun_shim "$usable"

    run env \
        PATH="$TEST_DIR/bin:$PATH" \
        CAPACITOR_CI_XCODE_DRY_RUN=1 \
        CAPACITOR_CI_XCODE_USE_DEFAULT_CANDIDATES=0 \
        CAPACITOR_CI_XCODE_CANDIDATES="$stale:$usable" \
        "$SCRIPT_PATH" "$missing"

    [ "$status" -eq 0 ]
    [[ "$output" == "Would select Xcode: $usable" ]]
}

@test "select-xcode fails clearly when no candidate can find clang" {
    local stale="$TEST_DIR/stale/Contents/Developer"

    mkdir -p "$stale"
    write_xcrun_shim "$TEST_DIR/absent/Contents/Developer"

    run env \
        PATH="$TEST_DIR/bin:$PATH" \
        CAPACITOR_CI_XCODE_DRY_RUN=1 \
        CAPACITOR_CI_XCODE_USE_DEFAULT_CANDIDATES=0 \
        "$SCRIPT_PATH" "$stale"

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: no usable Xcode developer directory found"* ]]
    [[ "$output" == *"$stale"* ]]
}
