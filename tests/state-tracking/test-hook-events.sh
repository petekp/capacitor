#!/bin/bash

# Wrapper for the canonical hook event tests.
# This avoids duplicated, drifting expectations across test suites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec bash "$PROJECT_ROOT/scripts/test-hook-events.sh"
