#!/bin/bash

# Verify a built app bundle before distribution
# Run this AFTER build-distribution.sh --skip-notarization to catch issues early
#
# Usage: ./verify-app-bundle.sh [path-to-app]
#        Defaults to apps/swift/Capacitor.app

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Architecture validation - Apple Silicon only
if [ "$(uname -m)" != "arm64" ]; then
    echo -e "${RED}Error: This project requires Apple Silicon (arm64).${NC}" >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi
APP_BUNDLE="${1:-$PROJECT_ROOT/apps/swift/Capacitor.app}"

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
[ -f "$APP_BUNDLE/Contents/MacOS/Capacitor" ] && pass "Executable exists" || fail "Executable missing"
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
if [ -f "$APP_BUNDLE/Contents/MacOS/Capacitor" ]; then
    RPATHS=$(otool -l "$APP_BUNDLE/Contents/MacOS/Capacitor" | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}')
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

RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/Capacitor_Capacitor.bundle"
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
pkill -f "Capacitor.app/Contents/MacOS/Capacitor" 2>/dev/null || true
sleep 0.5

# Launch the app and capture any immediate crash
echo "  Launching app from bundle (not via swift run)..."

# Launch the app in background (portable - no GNU timeout required)
LAUNCH_LOG=$(mktemp)
open "$APP_BUNDLE" 2>"$LAUNCH_LOG" &
OPEN_PID=$!

# Wait for app to start with retry loop (handles Gatekeeper checks, cold starts)
MAX_ATTEMPTS=6
ATTEMPT=1
APP_PID=""

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    sleep 1
    APP_PID=$(pgrep -f "Capacitor.app/Contents/MacOS/Capacitor" || echo "")
    if [ -n "$APP_PID" ]; then
        break
    fi
    echo "  Waiting for app to start... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    ATTEMPT=$((ATTEMPT + 1))
done

if [ -n "$APP_PID" ]; then
    pass "App launched successfully (PID: $APP_PID)"

    # Clean up - quit the app
    kill "$APP_PID" 2>/dev/null || true
else
    # Check for crash reports
    CRASH_REPORT=$(ls -t "$HOME/Library/Logs/DiagnosticReports/"*"Capacitor"* 2>/dev/null | head -1 || echo "")
    if [ -n "$CRASH_REPORT" ]; then
        fail "App CRASHED on launch! Check: $CRASH_REPORT"
    else
        fail "App did not stay running after ${MAX_ATTEMPTS}s (may have crashed silently)"
    fi
fi

# Clean up the open command if still running
kill "$OPEN_PID" 2>/dev/null || true
rm -f "$LAUNCH_LOG"

echo ""

# ============================================
# 6. Binary Dependencies Check
# ============================================
echo -e "${YELLOW}[6/6] Checking binary dependencies...${NC}"

# Check that all dylib dependencies can be resolved
MISSING_LIBS=$(otool -L "$APP_BUNDLE/Contents/MacOS/Capacitor" 2>/dev/null | grep "not found" || echo "")
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
