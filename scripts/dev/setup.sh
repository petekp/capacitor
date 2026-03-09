#!/usr/bin/env bash
# Canonical local setup entrypoint for Capacitor development.
# Safe to re-run. It verifies local prerequisites, builds the Rust core,
# regenerates UniFFI bindings, builds the Swift package, installs the repo
# pre-commit hook, and stages the release dylib for local runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'USAGE'
Usage: ./scripts/dev/setup.sh

Bootstraps the local Capacitor development environment:
  - validates Apple Silicon + macOS 14+
  - verifies Xcode command line tools
  - verifies Rust toolchain
  - optionally installs SwiftFormat via Homebrew
  - builds capacitor-core in release mode
  - regenerates UniFFI Swift bindings
  - builds the Swift package
  - installs the repo pre-commit hook
  - stages libcapacitor_core.dylib into the Swift build directory

After setup, use:
  ./scripts/dev/restart-alpha-stable.sh
USAGE
    exit 0
fi

echo "=== Capacitor Setup ==="

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: This project requires Apple Silicon (arm64)." >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 14 )); then
    echo "Error: Capacitor requires macOS 14+." >&2
    exit 1
fi
echo "macOS ${macos_major} detected"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo "Re-run this script after installation completes."
    exit 1
fi
echo "Xcode CLI tools found"

if ! command -v rustc >/dev/null 2>&1; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
fi
echo "Rust $(rustc --version | cut -d' ' -f2) found"

if ! command -v swiftformat >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "Installing SwiftFormat..."
        brew install swiftformat
    else
        echo "Warning: swiftformat not found. Install with: brew install swiftformat" >&2
    fi
else
    echo "SwiftFormat found"
fi

echo "Building Rust core..."
cd "$PROJECT_ROOT"
cargo build -p capacitor-core --release
install_name_tool -id "@rpath/libcapacitor_core.dylib" target/release/libcapacitor_core.dylib

echo "Generating UniFFI bindings..."
BINDINGS_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$BINDINGS_TMP_DIR"' EXIT
cargo run -p capacitor-core --bin uniffi-bindgen generate \
    --library target/release/libcapacitor_core.dylib \
    --language swift \
    --out-dir "$BINDINGS_TMP_DIR"
cp "$BINDINGS_TMP_DIR/capacitor_core.swift" apps/swift/Sources/Capacitor/Bridge/
cp "$BINDINGS_TMP_DIR/capacitor_coreFFI.h" apps/swift/Sources/CapacitorCoreFFI/

echo "Building Swift package..."
cd "$PROJECT_ROOT/apps/swift"
swift build
SWIFT_DEBUG_DIR="$(swift build --show-bin-path)"

echo "Installing pre-commit hook..."
cd "$PROJECT_ROOT"
ln -sf ../../scripts/dev/pre-commit .git/hooks/pre-commit

cp "$PROJECT_ROOT/target/release/libcapacitor_core.dylib" "$SWIFT_DEBUG_DIR/"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete! Next steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Start the app:"
echo "    ./scripts/dev/restart-alpha-stable.sh"
echo ""
echo "  Key docs:"
echo "    CLAUDE.md              — Project context & commands"
echo "    .claude/docs/          — Local runbooks for coding agents"
echo "    docs/README.md         — Active docs index"
echo ""
echo "  Pre-commit hooks are installed. Commits will run:"
echo "    • cargo fmt --check"
echo "    • cargo test"
echo ""
