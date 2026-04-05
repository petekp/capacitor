#!/bin/bash
# Fix the Rust dylib's install name for Swift linking.
#
# cargo build produces a dylib with an absolute install name that breaks
# when the library is copied to the Swift build directory. This script
# rewrites it to @rpath so Swift resolves it via RPATH search paths.
#
# Usage: ./scripts/dev/fix-dylib.sh [--verify-only]
#
# This is the single source of truth for dylib fixup. CI, dev scripts,
# and restart scripts should all call this instead of inlining
# install_name_tool invocations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DYLIB="$PROJECT_ROOT/target/release/libcapacitor_core.dylib"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: Dylib not found at $DYLIB" >&2
    echo "Run 'cargo build -p capacitor-core --release' first." >&2
    exit 1
fi

CURRENT_NAME=$(otool -D "$DYLIB" | tail -1)
EXPECTED="@rpath/libcapacitor_core.dylib"

if [ "${1:-}" = "--verify-only" ]; then
    if [ "$CURRENT_NAME" = "$EXPECTED" ]; then
        echo "OK: dylib install name is correct ($EXPECTED)"
        exit 0
    else
        echo "FAIL: dylib install name is '$CURRENT_NAME', expected '$EXPECTED'" >&2
        exit 1
    fi
fi

if [ "$CURRENT_NAME" = "$EXPECTED" ]; then
    echo "Dylib install name already correct"
else
    install_name_tool -id "$EXPECTED" "$DYLIB"
    echo "Fixed dylib install name → $EXPECTED"
fi
