#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DYLIB_PATH="$PROJECT_ROOT/target/release/libcapacitor_core.dylib"
TMP_DIR="$(mktemp -d)"

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
cargo run --release -p capacitor-core --bin uniffi-bindgen generate \
    --library "$DYLIB_PATH" \
    --language swift \
    --out-dir "$TMP_DIR"

cp "$TMP_DIR/capacitor_core.swift" "$PROJECT_ROOT/apps/swift/Sources/Capacitor/Bridge/"
cp "$TMP_DIR/capacitor_coreFFI.h" "$PROJECT_ROOT/apps/swift/Sources/Capacitor/Bridge/"
cp "$TMP_DIR/capacitor_coreFFI.h" "$PROJECT_ROOT/apps/swift/Sources/CapacitorCoreFFI/"

echo "Refreshed tracked UniFFI bindings from $DYLIB_PATH"
