#!/bin/bash

# Build Capacitor for distribution with code signing and notarization
# Usage: ./build-distribution.sh [--skip-notarization]
#
# Prerequisites:
# - Apple Developer Program membership
# - Developer ID Application certificate installed in Keychain
# - App-specific password for notarization (stored in Keychain)
#
# First-time setup for notarization:
# 1. Generate app-specific password at appleid.apple.com
# 2. Store in Keychain:
#    xcrun notarytool store-credentials "Capacitor" \
#      --apple-id "your@email.com" \
#      --team-id "YOUR_TEAM_ID" \
#      --password "app-specific-password"

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
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
SWIFT_DIR="$PROJECT_ROOT/apps/swift"
APP_BUNDLE="$SWIFT_DIR/Capacitor.app"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="Capacitor"
BUNDLE_ID="com.capacitor.app"

# Read version from VERSION file
VERSION_FILE="$PROJECT_ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
BUILD_NUMBER=$(date +%Y%m%d%H%M)
echo -e "${GREEN}Version: $VERSION (build $BUILD_NUMBER)${NC}"

# Parse arguments
SKIP_NOTARIZATION=false
if [ "$1" = "--skip-notarization" ]; then
    SKIP_NOTARIZATION=true
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Capacitor Distribution Build${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Verify Developer ID certificate
echo -e "${YELLOW}Checking for Developer ID Application certificate...${NC}"
CERT_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1)

if [ -z "$CERT_LINE" ]; then
    echo -e "${RED}ERROR: No Developer ID Application certificate found!${NC}"
    echo ""
    echo "Please create one at:"
    echo "https://developer.apple.com/account/resources/certificates/list"
    echo ""
    echo "Select 'Developer ID Application' and follow the prompts."
    exit 1
fi

# Extract certificate hash (first field) and name (in quotes)
SIGNING_IDENTITY=$(echo "$CERT_LINE" | awk '{print $2}')
SIGNING_NAME=$(echo "$CERT_LINE" | awk -F'"' '{print $2}')

echo -e "${GREEN}✓ Found certificate: $SIGNING_NAME${NC}"
echo -e "${GREEN}  Identity: $SIGNING_IDENTITY${NC}"
echo ""

# Step 1: Build Rust libraries (release mode)
echo -e "${YELLOW}Step 1/8: Building Rust libraries...${NC}"
cd "$PROJECT_ROOT"
cargo build -p hud-core -p hud-hook --release
echo -e "${GREEN}✓ Rust libraries built (hud-core + hud-hook)${NC}"
echo ""

# Step 2: Regenerate UniFFI Swift bindings
echo -e "${YELLOW}Step 2/8: Regenerating UniFFI Swift bindings...${NC}"
DYLIB_PATH="$PROJECT_ROOT/target/release/libhud_core.dylib"
BINDINGS_DIR="$SWIFT_DIR/bindings"
BRIDGE_DIR="$SWIFT_DIR/Sources/Capacitor/Bridge"

cd "$PROJECT_ROOT/core/hud-core"
cargo run --bin uniffi-bindgen generate --library "$DYLIB_PATH" --language swift --out-dir "$BINDINGS_DIR" 2>&1

# Copy bindings to where Swift compiles from
cp "$BINDINGS_DIR/hud_core.swift" "$BRIDGE_DIR/"
echo -e "${GREEN}✓ UniFFI bindings regenerated and copied${NC}"
echo ""

# Step 3: Fix dylib install_name to use @rpath
echo -e "${YELLOW}Step 3/8: Fixing dylib install_name...${NC}"
install_name_tool -id "@rpath/libhud_core.dylib" "$DYLIB_PATH"
echo -e "${GREEN}✓ Dylib install_name updated to @rpath${NC}"
echo ""

# Step 4: Clean and build Swift app (release mode)
echo -e "${YELLOW}Step 4/8: Building Swift app...${NC}"
cd "$SWIFT_DIR"
rm -rf .build Capacitor.app 2>/dev/null || true
swift build -c release

# Get the actual build directory (portable across toolchain/layout changes)
SWIFT_BUILD_DIR=$(swift build --show-bin-path -c release)
echo -e "${GREEN}✓ Swift app built (at $SWIFT_BUILD_DIR)${NC}"
echo ""

# Step 5: Create app bundle structure
echo -e "${YELLOW}Step 5/8: Creating app bundle...${NC}"

# Clean old bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$SWIFT_BUILD_DIR/Capacitor" "$APP_BUNDLE/Contents/MacOS/Capacitor"

# Copy dylib to Frameworks
cp "$DYLIB_PATH" "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"

# Copy Sparkle.framework to Frameworks
SPARKLE_FRAMEWORK="$SWIFT_BUILD_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo -e "${GREEN}✓ Sparkle.framework copied${NC}"
else
    echo -e "${RED}ERROR: Sparkle.framework not found at $SPARKLE_FRAMEWORK${NC}"
    exit 1
fi

# Add rpath to executable to find dylib in Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/Capacitor"

# Copy app icon if it exists
if [ -f "$PROJECT_ROOT/assets/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo -e "${GREEN}✓ App icon copied${NC}"
fi

# Copy SPM resource bundle (contains logomark.pdf and other assets)
RESOURCE_BUNDLE="$SWIFT_BUILD_DIR/Capacitor_Capacitor.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo -e "${GREEN}✓ Resource bundle copied${NC}"
else
    echo -e "${YELLOW}Warning: Resource bundle not found at $RESOURCE_BUNDLE${NC}"
fi

# Copy hud-hook binary (for auto-installation on first run)
HUD_HOOK_BINARY="$PROJECT_ROOT/target/release/hud-hook"
if [ -f "$HUD_HOOK_BINARY" ]; then
    cp "$HUD_HOOK_BINARY" "$APP_BUNDLE/Contents/Resources/hud-hook"
    echo -e "${GREEN}✓ hud-hook binary copied${NC}"
else
    echo -e "${RED}ERROR: hud-hook binary not found at $HUD_HOOK_BINARY${NC}"
    exit 1
fi

# Copy Info.plist (using variables for version)
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Capacitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.capacitor.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Capacitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>SUFeedURL</key>
    <string>https://github.com/petekp/capacitor/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>F9qGHLJ2ro5Q+mffrwkiQSGpkGD5+GCDnusHuRkXqrE=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
EOF

echo -e "${GREEN}✓ App bundle created${NC}"
echo ""

# Step 6: Code sign
echo -e "${YELLOW}Step 6/8: Code signing...${NC}"

# Sign the dylib first
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"

# Sign the hud-hook binary (critical for Gatekeeper approval when copied to ~/.local/bin)
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE/Contents/Resources/hud-hook"

# Sign Sparkle.framework (must sign before the app bundle)
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --deep \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Sign the app bundle
ENTITLEMENTS_FILE="$SWIFT_BUILD_DIR/Capacitor-entitlement.plist"
if [ -f "$ENTITLEMENTS_FILE" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS_FILE" \
        "$APP_BUNDLE"
else
    # Sign without entitlements if file doesn't exist
    codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        "$APP_BUNDLE"
fi

echo -e "${GREEN}✓ Code signing complete${NC}"
echo ""

# Verify signature
echo -e "${YELLOW}Verifying signature...${NC}"
codesign -dvvv "$APP_BUNDLE" 2>&1 | grep "Authority"
echo -e "${GREEN}✓ Signature verified${NC}"
echo ""

# Step 7: Create distribution package
echo -e "${YELLOW}Step 7/8: Creating distribution package...${NC}"
mkdir -p "$DIST_DIR"
cd "$SWIFT_DIR"

# Remove extended attributes that would break code signature on extraction
# (._* AppleDouble files appear when extracting if these aren't stripped)
xattr -cr "$APP_BUNDLE"

# Also strip from Sparkle.framework which has deeply nested resource forks
find "$APP_BUNDLE" -name "._*" -delete 2>/dev/null || true
echo -e "${GREEN}✓ Extended attributes and AppleDouble files stripped${NC}"

# Create zip for distribution
# --norsrc and --noextattr prevent resource forks/extended attributes from being archived
ZIP_NAME="Capacitor-v$VERSION-$(uname -m).zip"
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

echo -e "${GREEN}✓ Distribution package created: $DIST_DIR/$ZIP_NAME${NC}"
echo ""

# Step 8: Notarization
if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Skipping notarization (--skip-notarization flag)${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 8/8: Notarizing...${NC}"
    echo ""
    echo "This will submit to Apple for notarization (takes 5-15 minutes)."
    echo ""
    echo "If this is your first time, you need to set up credentials:"
    echo "  xcrun notarytool store-credentials \"Capacitor\" \\"
    echo "    --apple-id \"your@email.com\" \\"
    echo "    --team-id \"YOUR_TEAM_ID\" \\"
    echo "    --password \"app-specific-password\""
    echo ""

    # Submit for notarization
    xcrun notarytool submit "$DIST_DIR/$ZIP_NAME" \
        --keychain-profile "Capacitor" \
        --wait

    # Staple the notarization ticket
    echo ""
    echo -e "${YELLOW}Stapling notarization ticket...${NC}"
    xcrun stapler staple "$APP_BUNDLE"

    # Recreate zip with stapled app
    rm "$DIST_DIR/$ZIP_NAME"
    ditto -c -k --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

    echo -e "${GREEN}✓ Notarization complete and stapled${NC}"
    echo ""
fi

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Distribution package: $DIST_DIR/$ZIP_NAME"
echo ""
echo "To test locally:"
echo "  open '$APP_BUNDLE'"
echo ""
echo "To upload to GitHub:"
echo "  gh release create v$VERSION '$DIST_DIR/$ZIP_NAME' --title 'Capacitor v$VERSION' --notes 'Release v$VERSION'"
echo ""

if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Note: This build is NOT notarized. Users will see security warnings.${NC}"
    echo "To notarize, run without --skip-notarization flag."
    echo ""
fi
