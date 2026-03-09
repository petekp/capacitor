#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"
BINDINGS_TMP_DIR="$(mktemp -d)"
BRIDGE_SWIFT="$SWIFT_DIR/Sources/Capacitor/Bridge/capacitor_core.swift"
BRIDGE_HEADER="$SWIFT_DIR/Sources/CapacitorCoreFFI/capacitor_coreFFI.h"
ORIGINAL_SWIFT="$(mktemp)"
ORIGINAL_HEADER="$(mktemp)"

cp "$BRIDGE_SWIFT" "$ORIGINAL_SWIFT"
cp "$BRIDGE_HEADER" "$ORIGINAL_HEADER"

cleanup() {
  cp "$ORIGINAL_SWIFT" "$BRIDGE_SWIFT"
  cp "$ORIGINAL_HEADER" "$BRIDGE_HEADER"
  rm -rf "$BINDINGS_TMP_DIR" "$ORIGINAL_SWIFT" "$ORIGINAL_HEADER"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

echo "Building release Rust dylib for Swift tests..."
cargo build -p capacitor-core --release
install_name_tool -id "@rpath/libcapacitor_core.dylib" target/release/libcapacitor_core.dylib

echo "Regenerating UniFFI Swift bindings..."
cargo run -p capacitor-core --bin uniffi-bindgen generate \
  --library target/release/libcapacitor_core.dylib \
  --language swift \
  --out-dir "$BINDINGS_TMP_DIR"
cp "$BINDINGS_TMP_DIR/capacitor_core.swift" "$SWIFT_DIR/Sources/Capacitor/Bridge/"
cp "$BINDINGS_TMP_DIR/capacitor_coreFFI.h" "$SWIFT_DIR/Sources/CapacitorCoreFFI/"

cd "$SWIFT_DIR"
echo "Building Swift package and staging libcapacitor_core.dylib..."
swift build
SWIFT_BIN_PATH="$(swift build --show-bin-path)"
cp ../../target/release/libcapacitor_core.dylib "$SWIFT_BIN_PATH/"

echo "Running Swift tests..."
swift test
