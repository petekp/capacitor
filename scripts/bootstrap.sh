#!/usr/bin/env bash
# bootstrap.sh
#
# One-command setup for Capacitor development environment. Validates macOS,
# installs missing toolchains, builds the Rust core with proper linking,
# generates Swift bindings, and builds the app.
#
# Safe to run multiple times—checks before installing anything.
#
# Usage: ./scripts/bootstrap.sh
# After:  ./scripts/dev/restart-app.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Capacitor Bootstrap ==="

# -----------------------------------------------------------------------------
# Architecture validation
# This project targets Apple Silicon only. Building on Intel or under Rosetta
# produces non-functional artifacts.
# -----------------------------------------------------------------------------

if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: This project requires Apple Silicon (arm64)." >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi

# -----------------------------------------------------------------------------
# Platform validation
# SwiftUI features (Observable macro, etc.) require macOS 14+
# -----------------------------------------------------------------------------

version=$(sw_vers -productVersion | cut -d. -f1)
if (( version < 14 )); then
    echo "Error: Requires macOS 14+" >&2
    exit 1
fi
echo "macOS $version detected"

# -----------------------------------------------------------------------------
# Xcode CLI tools
# Provides clang, swift, and other build essentials. The --install command
# opens a GUI dialog—we exit so the user can complete it, then re-run.
# -----------------------------------------------------------------------------

if ! xcode-select -p &>/dev/null; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo "Re-run this script after installation completes."
    exit 1
fi
echo "Xcode CLI tools found"

# -----------------------------------------------------------------------------
# Rust toolchain
# Standard rustup installation. The -y flag accepts defaults non-interactively.
# We source cargo/env immediately so the rest of this script can use cargo.
# -----------------------------------------------------------------------------

if ! command -v rustc &>/dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
echo "Rust $(rustc --version | cut -d' ' -f2) found"

# -----------------------------------------------------------------------------
# Build Rust core
# -----------------------------------------------------------------------------

echo "Building Rust core..."
cd "$PROJECT_ROOT"
cargo build -p hud-core --release

# Fix the dylib's install name so Swift can find it at runtime.
# Without this, the library embeds an absolute path that breaks when the
# app is moved or distributed. @rpath tells the linker to search the
# executable's runtime library paths instead.
install_name_tool -id "@rpath/libhud_core.dylib" target/release/libhud_core.dylib

# -----------------------------------------------------------------------------
# UniFFI bindings
# Generates Swift code from the compiled Rust library. Must regenerate after
# any Rust API changes to avoid "UniFFI API checksum mismatch" crashes.
# The bindings go to two places: where uniffi writes them (bindings/) and
# where SPM expects them (Sources/Capacitor/Bridge/).
# -----------------------------------------------------------------------------

echo "Generating UniFFI bindings..."
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift --out-dir apps/swift/bindings
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/

# -----------------------------------------------------------------------------
# Build Swift app
# -----------------------------------------------------------------------------

echo "Building Swift app..."
cd apps/swift
swift build

# Get the actual build directory (portable across toolchain/layout changes)
SWIFT_DEBUG_DIR=$(swift build --show-bin-path)

# -----------------------------------------------------------------------------
# Pre-commit hooks
# Ensures formatting and tests run before each commit. Symlinks to the repo
# script so updates propagate automatically.
# -----------------------------------------------------------------------------

echo "Installing pre-commit hooks..."
cd "$PROJECT_ROOT"
ln -sf ../../scripts/dev/pre-commit .git/hooks/pre-commit

# -----------------------------------------------------------------------------
# Copy dylib to debug build directory
# Swift's debug build looks for the dylib at @loader_path (next to the
# executable). Without this copy, the app crashes on launch with:
# "Library not loaded: @rpath/libhud_core.dylib"
# -----------------------------------------------------------------------------

cp "$PROJECT_ROOT/target/release/libhud_core.dylib" "$SWIFT_DEBUG_DIR/"

echo ""
echo "=== Bootstrap complete! ==="
echo "Run: ./scripts/dev/restart-app.sh"
