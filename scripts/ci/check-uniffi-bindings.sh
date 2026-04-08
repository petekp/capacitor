#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DYLIB_PATH="$PROJECT_ROOT/target/release/libcapacitor_core.dylib"
TMP_DIR="$(mktemp -d)"
FAILED=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$DYLIB_PATH" ]]; then
    echo "ERROR: $DYLIB_PATH is missing." >&2
    echo "Run 'cargo build -p capacitor-core --release' first." >&2
    exit 1
fi

cd "$PROJECT_ROOT"
cargo run -p capacitor-core --bin uniffi-bindgen generate \
    --library "$DYLIB_PATH" \
    --language swift \
    --out-dir "$TMP_DIR" >/dev/null

check_file() {
    local generated="$1"
    local tracked="$2"

    if ! cmp -s "$generated" "$tracked"; then
        echo "ERROR: tracked UniFFI binding is stale: $tracked" >&2
        diff -u "$tracked" "$generated" || true
        FAILED=1
    fi
}

check_file "$TMP_DIR/capacitor_core.swift" \
    "$PROJECT_ROOT/apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift"
check_file "$TMP_DIR/capacitor_coreFFI.h" \
    "$PROJECT_ROOT/apps/swift/Sources/Capacitor/Bridge/capacitor_coreFFI.h"
check_file "$TMP_DIR/capacitor_coreFFI.h" \
    "$PROJECT_ROOT/apps/swift/Sources/CapacitorCoreFFI/capacitor_coreFFI.h"

if [[ "$FAILED" -ne 0 ]]; then
    echo "Run ./scripts/dev/refresh-uniffi-bindings.sh and commit the refreshed outputs." >&2
    exit 1
fi

echo "UniFFI bindings are fresh."
