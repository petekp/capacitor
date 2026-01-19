#!/bin/bash

# Run all tests locally
# Usage: ./scripts/run-tests.sh [--quick]
#
# Options:
#   --quick    Skip Swift tests (faster, no Rust build needed)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

QUICK=false
if [ "$1" = "--quick" ]; then
    QUICK=true
fi

cd "$PROJECT_ROOT"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Running All Tests${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

FAILED=0

echo -e "${YELLOW}[1/4] Version Bump Tests (bats)${NC}"
if command -v bats &> /dev/null; then
    if bats tests/release-scripts/bump-version.bats; then
        echo -e "${GREEN}✓ Version bump tests passed${NC}"
    else
        echo -e "${RED}✗ Version bump tests failed${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}⚠ bats not installed, skipping (brew install bats-core)${NC}"
fi
echo ""

echo -e "${YELLOW}[2/4] Rust Tests${NC}"
if cargo test 2>&1; then
    echo -e "${GREEN}✓ Rust tests passed${NC}"
else
    echo -e "${RED}✗ Rust tests failed${NC}"
    FAILED=1
fi
echo ""

echo -e "${YELLOW}[3/4] Rust Linting${NC}"
if cargo clippy -- -D warnings 2>&1; then
    echo -e "${GREEN}✓ Clippy passed${NC}"
else
    echo -e "${RED}✗ Clippy failed${NC}"
    FAILED=1
fi
echo ""

if [ "$QUICK" = false ]; then
    echo -e "${YELLOW}[4/4] Swift Tests${NC}"

    echo "Building Rust library for Swift tests..."
    cargo build -p hud-core --release
    install_name_tool -id "@rpath/libhud_core.dylib" target/release/libhud_core.dylib

    cd apps/swift
    if swift test 2>&1; then
        echo -e "${GREEN}✓ Swift tests passed${NC}"
    else
        echo -e "${RED}✗ Swift tests failed${NC}"
        FAILED=1
    fi
    cd "$PROJECT_ROOT"
else
    echo -e "${YELLOW}[4/4] Swift Tests${NC}"
    echo -e "${YELLOW}⚠ Skipped (--quick mode)${NC}"
fi
echo ""

echo -e "${CYAN}========================================${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
echo -e "${CYAN}========================================${NC}"
