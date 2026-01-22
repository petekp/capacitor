#!/bin/bash

# State Tracking Test Suite Runner
# Runs all tests for the Claude Code session state tracking system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

log_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

run_suite() {
    local name="$1"
    local command="$2"

    ((TOTAL_SUITES++))
    echo -e "${YELLOW}Running:${NC} $name"

    if eval "$command"; then
        echo -e "${GREEN}✓ $name passed${NC}"
        ((PASSED_SUITES++))
    else
        echo -e "${RED}✗ $name failed${NC}"
        ((FAILED_SUITES++))
    fi
    echo ""
}

# ============================================
# Main
# ============================================

log_header "State Tracking Test Suite"

echo "Project root: $PROJECT_ROOT"
echo "Script dir: $SCRIPT_DIR"
echo ""

# Make test scripts executable
chmod +x "$SCRIPT_DIR/test-hook-events.sh" 2>/dev/null || true

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR:${NC} jq is required but not installed"
    echo "Install with: brew install jq"
    exit 1
fi

if ! command -v cargo &> /dev/null; then
    echo -e "${RED}ERROR:${NC} cargo is required but not installed"
    exit 1
fi

echo "Prerequisites OK"
echo ""

# ============================================
# Run Test Suites
# ============================================

log_header "Shell Script Tests"

if [ -f "$SCRIPT_DIR/test-hook-events.sh" ]; then
    run_suite "Hook Event Tests" "$SCRIPT_DIR/test-hook-events.sh"
fi
echo -e "${YELLOW}Note:${NC} Lock directories are owned by Claude Code; HUD validates lock parsing via Rust unit tests."
echo ""

log_header "Rust Unit Tests"

cd "$PROJECT_ROOT"
run_suite "hud-core sessions tests" "cargo test -p hud-core sessions::tests -- --nocapture"

# ============================================
# Summary
# ============================================

log_header "Test Summary"

echo "Total test suites: $TOTAL_SUITES"
echo -e "Passed: ${GREEN}$PASSED_SUITES${NC}"
echo -e "Failed: ${RED}$FAILED_SUITES${NC}"
echo ""

if [ $FAILED_SUITES -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
