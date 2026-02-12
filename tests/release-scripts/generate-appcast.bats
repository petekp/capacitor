#!/usr/bin/env bats

# Tests for generate-appcast.sh
# Run with: bats tests/release-scripts/generate-appcast.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/release" "$TEST_DIR/dist"
    cp "$PROJECT_ROOT/scripts/release/generate-appcast.sh" "$TEST_DIR/scripts/release/"
    chmod +x "$TEST_DIR/scripts/release/generate-appcast.sh"

    echo "1.2.3" > "$TEST_DIR/VERSION"

    ARCH="$(uname -m)"
    touch "$TEST_DIR/dist/Capacitor-v1.2.3-$ARCH.zip"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "generate-appcast creates appcast.xml with expected version and zip name" {
    if [ "$(uname -m)" != "arm64" ]; then
        skip "generate-appcast.sh requires arm64"
    fi

    run env CI=1 "$TEST_DIR/scripts/release/generate-appcast.sh"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/dist/appcast.xml" ]

    run grep -q "Version 1.2.3" "$TEST_DIR/dist/appcast.xml"
    [ "$status" -eq 0 ]
    run grep -q "Capacitor-v1.2.3-$(uname -m).zip" "$TEST_DIR/dist/appcast.xml"
    [ "$status" -eq 0 ]
}

@test "generate-appcast --sign falls back to unsigned output when sign_update fails" {
    if [ "$(uname -m)" != "arm64" ]; then
        skip "generate-appcast.sh requires arm64"
    fi

    mkdir -p "$TEST_DIR/apps/swift/.build/artifacts/sparkle/Sparkle/bin"
    cat > "$TEST_DIR/apps/swift/.build/artifacts/sparkle/Sparkle/bin/sign_update" <<'EOF'
#!/bin/bash
echo "mock signature failure" >&2
exit 7
EOF
    chmod +x "$TEST_DIR/apps/swift/.build/artifacts/sparkle/Sparkle/bin/sign_update"

    run env CI=1 "$TEST_DIR/scripts/release/generate-appcast.sh" --sign
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/dist/appcast.xml" ]
    [[ "$output" == *"Signed: No"* ]]

    run grep -q "sparkle:edSignature=" "$TEST_DIR/dist/appcast.xml"
    [ "$status" -eq 1 ]
}
