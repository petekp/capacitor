#!/bin/bash

# Verify a built app bundle before distribution
# Run this AFTER build-distribution.sh --skip-notarization to catch issues early
#
# Usage: ./verify-app-bundle.sh [path-to-app]
#        Defaults to apps/swift/ClaudeHUD.app

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/apps/swift/ClaudeHUD.app}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Pre-Release App Bundle Verification${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Verifying: $APP_BUNDLE"
echo ""

ERRORS=0
WARNINGS=0

# Helper functions
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; ((ERRORS++)); }
warn() { echo -e "${YELLOW}!${NC} $1"; ((WARNINGS++)); }

# ============================================
# 1. Basic Structure
# ============================================
echo -e "${YELLOW}[1/6] Checking bundle structure...${NC}"

[ -d "$APP_BUNDLE" ] && pass "App bundle exists" || fail "App bundle not found"
[ -f "$APP_BUNDLE/Contents/MacOS/ClaudeHUD" ] && pass "Executable exists" || fail "Executable missing"
[ -f "$APP_BUNDLE/Contents/Info.plist" ] && pass "Info.plist exists" || fail "Info.plist missing"
[ -d "$APP_BUNDLE/Contents/Frameworks" ] && pass "Frameworks directory exists" || fail "Frameworks directory missing"
[ -d "$APP_BUNDLE/Contents/Resources" ] && pass "Resources directory exists" || fail "Resources directory missing"

echo ""

# ============================================
# 2. Framework Dependencies
# ============================================
echo -e "${YELLOW}[2/6] Checking framework dependencies...${NC}"

[ -f "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib" ] && pass "libhud_core.dylib present" || fail "libhud_core.dylib missing"
[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ] && pass "Sparkle.framework present" || fail "Sparkle.framework missing"

# Check dylib linkage
if [ -f "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib" ]; then
    INSTALL_NAME=$(otool -D "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib" | tail -1)
    if [[ "$INSTALL_NAME" == *"@rpath"* ]]; then
        pass "libhud_core.dylib has @rpath install_name"
    else
        fail "libhud_core.dylib install_name not @rpath: $INSTALL_NAME"
    fi
fi

# Check executable rpath
if [ -f "$APP_BUNDLE/Contents/MacOS/ClaudeHUD" ]; then
    RPATHS=$(otool -l "$APP_BUNDLE/Contents/MacOS/ClaudeHUD" | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}')
    if echo "$RPATHS" | grep -q "@executable_path/../Frameworks"; then
        pass "Executable has correct rpath"
    else
        fail "Executable missing @executable_path/../Frameworks rpath"
    fi
fi

echo ""

# ============================================
# 3. Resource Bundle (Critical for Bundle.module replacement)
# ============================================
echo -e "${YELLOW}[3/6] Checking resource bundle...${NC}"

RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/ClaudeHUD_ClaudeHUD.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    pass "SPM resource bundle present"

    # Check for critical resources
    if [ -f "$RESOURCE_BUNDLE/Contents/Resources/logomark.pdf" ] || [ -f "$RESOURCE_BUNDLE/logomark.pdf" ]; then
        pass "logomark.pdf found in resource bundle"
    else
        # Try to find it anywhere in the bundle
        LOGO_PATH=$(find "$RESOURCE_BUNDLE" -name "logomark.pdf" 2>/dev/null | head -1)
        if [ -n "$LOGO_PATH" ]; then
            pass "logomark.pdf found at: ${LOGO_PATH#$APP_BUNDLE/}"
        else
            fail "logomark.pdf NOT FOUND in resource bundle"
        fi
    fi

    # Check for Assets.car (compiled asset catalog)
    if [ -f "$RESOURCE_BUNDLE/Contents/Resources/Assets.car" ] || find "$RESOURCE_BUNDLE" -name "Assets.car" 2>/dev/null | head -1 | grep -q .; then
        pass "Assets.car (compiled assets) found"
    else
        warn "Assets.car not found (may be okay if assets are elsewhere)"
    fi
else
    fail "SPM resource bundle NOT FOUND at $RESOURCE_BUNDLE"
    echo "      This will cause Bundle.module crashes!"
fi

# Also check for app icon
if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    pass "AppIcon.icns present"
else
    warn "AppIcon.icns not found (app will work but have generic icon)"
fi

echo ""

# ============================================
# 4. Code Signing
# ============================================
echo -e "${YELLOW}[4/6] Checking code signing...${NC}"

if codesign -v "$APP_BUNDLE" 2>/dev/null; then
    pass "App bundle signature valid"

    # Check for Developer ID
    SIGNING_INFO=$(codesign -dvvv "$APP_BUNDLE" 2>&1 | grep "Authority" | head -1)
    if echo "$SIGNING_INFO" | grep -q "Developer ID"; then
        pass "Signed with Developer ID"
    else
        warn "Not signed with Developer ID (may fail Gatekeeper)"
    fi
else
    fail "App bundle signature INVALID or missing"
fi

# Check hardened runtime
CODESIGN_FLAGS=$(codesign -dvvv "$APP_BUNDLE" 2>&1 | grep "flags" || echo "")
if echo "$CODESIGN_FLAGS" | grep -q "runtime"; then
    pass "Hardened runtime enabled"
else
    warn "Hardened runtime not detected (required for notarization)"
fi

echo ""

# ============================================
# 5. Launch Test (Critical!)
# ============================================
echo -e "${YELLOW}[5/6] Testing app launch...${NC}"

# Kill any existing instance
pkill -f "ClaudeHUD.app/Contents/MacOS/ClaudeHUD" 2>/dev/null || true
sleep 0.5

# Launch the app and capture any immediate crash
echo "  Launching app from bundle (not via swift run)..."

# Use open with wait to detect immediate crashes
LAUNCH_LOG=$(mktemp)
if timeout 5 open -W "$APP_BUNDLE" 2>"$LAUNCH_LOG" &
then
    OPEN_PID=$!
    sleep 3

    # Check if the process is still running
    APP_PID=$(pgrep -f "ClaudeHUD.app/Contents/MacOS/ClaudeHUD" || echo "")

    if [ -n "$APP_PID" ]; then
        pass "App launched successfully (PID: $APP_PID)"

        # Clean up - quit the app
        kill "$APP_PID" 2>/dev/null || true
    else
        # Check for crash
        if [ -f "$HOME/Library/Logs/DiagnosticReports/"*"ClaudeHUD"* ]; then
            LATEST_CRASH=$(ls -t "$HOME/Library/Logs/DiagnosticReports/"*"ClaudeHUD"* 2>/dev/null | head -1)
            fail "App CRASHED on launch! Check: $LATEST_CRASH"
        else
            fail "App did not stay running (may have crashed silently)"
        fi
    fi

    # Kill the open command if still waiting
    kill "$OPEN_PID" 2>/dev/null || true
else
    fail "Failed to launch app"
fi

rm -f "$LAUNCH_LOG"

echo ""

# ============================================
# 6. Binary Dependencies Check
# ============================================
echo -e "${YELLOW}[6/6] Checking binary dependencies...${NC}"

# Check that all dylib dependencies can be resolved
MISSING_LIBS=$(otool -L "$APP_BUNDLE/Contents/MacOS/ClaudeHUD" 2>/dev/null | grep "not found" || echo "")
if [ -z "$MISSING_LIBS" ]; then
    pass "All executable dependencies resolvable"
else
    fail "Missing libraries: $MISSING_LIBS"
fi

# Check the Rust dylib dependencies
if [ -f "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib" ]; then
    DYLIB_MISSING=$(otool -L "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib" 2>/dev/null | grep "not found" || echo "")
    if [ -z "$DYLIB_MISSING" ]; then
        pass "All libhud_core.dylib dependencies resolvable"
    else
        fail "libhud_core.dylib missing deps: $DYLIB_MISSING"
    fi
fi

echo ""

# ============================================
# Summary
# ============================================
echo -e "${GREEN}========================================${NC}"
if [ $ERRORS -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}All checks passed! Safe to release.${NC}"
    else
        echo -e "${YELLOW}$WARNINGS warning(s), but no blocking errors.${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"
    exit 0
else
    echo -e "${RED}$ERRORS error(s) found! DO NOT RELEASE.${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
fi
