#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Architecture validation - Apple Silicon only
if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: This project requires Apple Silicon (arm64)." >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi

# Verify hook is in sync (warn only, don't block)
"$PROJECT_ROOT/scripts/sync-hooks.sh" 2>/dev/null || true

# Kill any existing Capacitor instances (graceful first, then force)
# Match the binary name at end of path to avoid killing unrelated processes
pkill -f '/Capacitor$' 2>/dev/null || true
sleep 0.3
# Force kill any stragglers
pkill -9 -f '/Capacitor$' 2>/dev/null || true
sleep 0.2

cd "$PROJECT_ROOT"
cargo build -p hud-core --release || { echo "Rust build failed"; exit 1; }

# Fix the dylib's install name so Swift can find it at runtime.
# Without this, the library embeds an absolute path that breaks when moved.
install_name_tool -id "@rpath/libhud_core.dylib" target/release/libhud_core.dylib

# Always regenerate UniFFI bindings to prevent checksum mismatch crashes
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift \
    --out-dir apps/swift/bindings/

# Copy bindings to Bridge directory
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/

cd "$PROJECT_ROOT/apps/swift"

# Get the actual build directory (portable across toolchain/layout changes)
SWIFT_DEBUG_DIR=$(swift build --show-bin-path)
mkdir -p "$SWIFT_DEBUG_DIR"
cp "$PROJECT_ROOT/target/release/libhud_core.dylib" "$SWIFT_DEBUG_DIR/"

# Copy hud-hook binary so Bundle.main can find it (matches release bundle structure)
if [ -f "$HOME/.local/bin/hud-hook" ]; then
    cp "$HOME/.local/bin/hud-hook" "$SWIFT_DEBUG_DIR/"
elif [ -f "$PROJECT_ROOT/target/release/hud-hook" ]; then
    cp "$PROJECT_ROOT/target/release/hud-hook" "$SWIFT_DEBUG_DIR/"
fi

swift build || { echo "Swift build failed"; exit 1; }

swift run 2>&1 &
echo "Capacitor started (PID: $!)"
