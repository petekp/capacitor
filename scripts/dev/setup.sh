#!/usr/bin/env bash
# setup.sh
#
# Alias for bootstrap.sh — the conventional name developers expect.
# Runs full environment setup and prints next steps.
#
# Usage: ./scripts/dev/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Run bootstrap
"$PROJECT_ROOT/scripts/bootstrap.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete! Next steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Start the app:"
echo "    ./scripts/dev/restart-app.sh"
echo ""
echo "  Key docs:"
echo "    CLAUDE.md              — Project context & commands"
echo "    .claude/docs/          — Architecture & workflows"
echo "    docs/                  — ADRs & release procedures"
echo ""
echo "  Pre-commit hooks are installed. Commits will run:"
echo "    • cargo fmt --check"
echo "    • cargo test"
echo ""
