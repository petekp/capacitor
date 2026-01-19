#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

pkill -x ClaudeHUD 2>/dev/null || true
sleep 0.3

cd "$PROJECT_ROOT"
cargo build -p hud-core --release || { echo "Rust build failed"; exit 1; }

cd "$PROJECT_ROOT/apps/swift"
swift build || { echo "Swift build failed"; exit 1; }

swift run 2>&1 &
echo "ClaudeHUD started (PID: $!)"
