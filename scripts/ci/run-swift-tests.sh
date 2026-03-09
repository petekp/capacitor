#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"

cd "$PROJECT_ROOT"

echo "Building release Rust dylib for Swift tests..."
cargo build -p capacitor-core --release
install_name_tool -id "@rpath/libcapacitor_core.dylib" target/release/libcapacitor_core.dylib

cd "$SWIFT_DIR"
echo "Building Swift package and staging libcapacitor_core.dylib..."
swift build
SWIFT_BIN_PATH="$(swift build --show-bin-path)"
cp ../../target/release/libcapacitor_core.dylib "$SWIFT_BIN_PATH/"

echo "Running Swift tests..."
swift test
