#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <swift-test-filter>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILTER="$1"
STAMP_PATH="$REPO_ROOT/apps/swift/.build/.capacitor-proof-ready"
RUST_LIB="$REPO_ROOT/target/release/libcapacitor_core.dylib"

mkdir -p "$(dirname "$STAMP_PATH")"

if [[ ! -f "$STAMP_PATH" || ! -f "$RUST_LIB" || "$RUST_LIB" -nt "$STAMP_PATH" ]]; then
  cargo build -p capacitor-core --release
  install_name_tool -id "@rpath/libcapacitor_core.dylib" "$RUST_LIB"

  pushd "$REPO_ROOT/apps/swift" >/dev/null
  swift build
  SWIFT_BIN_PATH="$(swift build --show-bin-path)"
  cp "$RUST_LIB" "$SWIFT_BIN_PATH/"
  popd >/dev/null

  touch "$STAMP_PATH"
fi

swift test --package-path "$REPO_ROOT/apps/swift" --filter "$FILTER"
