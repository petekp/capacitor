#!/bin/bash

# Run all tests locally
# Usage: ./scripts/dev/run-tests.sh [--quick]
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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

echo -e "${YELLOW}[1/6] Release Script Tests (bats)${NC}"
if command -v bats &> /dev/null; then
    if bats tests/release-scripts; then
        echo -e "${GREEN}✓ Release script tests passed${NC}"
    else
        echo -e "${RED}✗ Release script tests failed${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}⚠ bats not installed, skipping (brew install bats-core)${NC}"
fi
echo ""

echo -e "${YELLOW}[2/6] Rust Formatting${NC}"
if cargo fmt 2>&1; then
    echo -e "${GREEN}✓ Rust formatted${NC}"
else
    echo -e "${RED}✗ Rust formatting failed${NC}"
    FAILED=1
fi
echo ""

echo -e "${YELLOW}[3/6] Rust Tests${NC}"
if cargo test 2>&1; then
    echo -e "${GREEN}✓ Rust tests passed${NC}"
else
    echo -e "${RED}✗ Rust tests failed${NC}"
    FAILED=1
fi
echo ""

echo -e "${YELLOW}[4/6] Rust Linting${NC}"
if cargo clippy -- -D warnings 2>&1; then
    echo -e "${GREEN}✓ Clippy passed${NC}"
else
    echo -e "${RED}✗ Clippy failed${NC}"
    FAILED=1
fi
echo ""

echo -e "${YELLOW}[5/6] Swift Formatting${NC}"
if command -v swiftformat &> /dev/null; then
    if swiftformat apps/swift 2>&1; then
        echo -e "${GREEN}✓ Swift formatted${NC}"
    else
        echo -e "${RED}✗ Swift formatting failed${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}⚠ swiftformat not installed, skipping (brew install swiftformat)${NC}"
fi
echo ""

if [ "$QUICK" = false ]; then
    echo -e "${YELLOW}[6/6] Swift Tests${NC}"

    echo "Building Rust library for Swift tests..."
    cargo build -p capacitor-core --release
    install_name_tool -id "@rpath/libcapacitor_core.dylib" target/release/libcapacitor_core.dylib

    cd apps/swift
    echo "Building Swift package and staging libcapacitor_core.dylib for test runtime..."
    swift build
    SWIFT_BIN_PATH="$(swift build --show-bin-path)"
    cp ../../target/release/libcapacitor_core.dylib "$SWIFT_BIN_PATH/"

    if swift test 2>&1; then
        echo -e "${GREEN}✓ Swift tests passed${NC}"
    else
        echo -e "${RED}✗ Swift tests failed${NC}"
        FAILED=1
    fi
    cd "$PROJECT_ROOT"
else
    echo -e "${YELLOW}[6/6] Swift Tests${NC}"
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
