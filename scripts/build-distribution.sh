#!/bin/bash

# Build ClaudeHUD for distribution with code signing and notarization
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
#    xcrun notarytool store-credentials "ClaudeHUD" \
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
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"
APP_BUNDLE="$SWIFT_DIR/ClaudeHUD.app"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="ClaudeHUD"
BUNDLE_ID="com.claudehud.app"

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
echo -e "${GREEN}ClaudeHUD Distribution Build${NC}"
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

# Step 1: Build Rust library (release mode)
echo -e "${YELLOW}Step 1/7: Building Rust library...${NC}"
cd "$PROJECT_ROOT"
cargo build -p hud-core --release
echo -e "${GREEN}✓ Rust library built${NC}"
echo ""

# Step 2: Fix dylib install_name to use @rpath
echo -e "${YELLOW}Step 2/7: Fixing dylib install_name...${NC}"
DYLIB_PATH="$PROJECT_ROOT/target/release/libhud_core.dylib"
install_name_tool -id "@rpath/libhud_core.dylib" "$DYLIB_PATH"
echo -e "${GREEN}✓ Dylib install_name updated to @rpath${NC}"
echo ""

# Step 3: Build Swift app (release mode)
echo -e "${YELLOW}Step 3/7: Building Swift app...${NC}"
cd "$SWIFT_DIR"
swift build -c release
echo -e "${GREEN}✓ Swift app built${NC}"
echo ""

# Step 4: Create app bundle structure
echo -e "${YELLOW}Step 4/7: Creating app bundle...${NC}"

# Clean old bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$SWIFT_DIR/.build/release/ClaudeHUD" "$APP_BUNDLE/Contents/MacOS/ClaudeHUD"

# Copy dylib to Frameworks
cp "$DYLIB_PATH" "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"

# Copy Sparkle.framework to Frameworks
SPARKLE_FRAMEWORK="$SWIFT_DIR/.build/arm64-apple-macosx/release/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo -e "${GREEN}✓ Sparkle.framework copied${NC}"
else
    echo -e "${RED}ERROR: Sparkle.framework not found at $SPARKLE_FRAMEWORK${NC}"
    exit 1
fi

# Add rpath to executable to find dylib in Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/ClaudeHUD"

# Copy app icon if it exists
if [ -f "$PROJECT_ROOT/assets/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo -e "${GREEN}✓ App icon copied${NC}"
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
    <string>ClaudeHUD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudehud.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude HUD</string>
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
    <string>https://github.com/petekp/claude-hud/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>F9qGHLJ2ro5Q+mffrwkiQSGpkGD5+GCDnusHuRkXqrE=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
EOF

echo -e "${GREEN}✓ App bundle created${NC}"
echo ""

# Step 5: Code sign
echo -e "${YELLOW}Step 5/7: Code signing...${NC}"

# Sign the dylib first
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"

# Sign Sparkle.framework (must sign before the app bundle)
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --deep \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Sign the app bundle
ENTITLEMENTS_FILE="$SWIFT_DIR/.build/arm64-apple-macosx/release/ClaudeHUD-entitlement.plist"
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

# Step 6: Create distribution package
echo -e "${YELLOW}Step 6/7: Creating distribution package...${NC}"
mkdir -p "$DIST_DIR"
cd "$SWIFT_DIR"

# Create zip for distribution
ZIP_NAME="ClaudeHUD-v$VERSION-$(uname -m).zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

echo -e "${GREEN}✓ Distribution package created: $DIST_DIR/$ZIP_NAME${NC}"
echo ""

# Step 7: Notarization
if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Skipping notarization (--skip-notarization flag)${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 7/7: Notarizing...${NC}"
    echo ""
    echo "This will submit to Apple for notarization (takes 5-15 minutes)."
    echo ""
    echo "If this is your first time, you need to set up credentials:"
    echo "  xcrun notarytool store-credentials \"ClaudeHUD\" \\"
    echo "    --apple-id \"your@email.com\" \\"
    echo "    --team-id \"YOUR_TEAM_ID\" \\"
    echo "    --password \"app-specific-password\""
    echo ""

    # Submit for notarization
    xcrun notarytool submit "$DIST_DIR/$ZIP_NAME" \
        --keychain-profile "ClaudeHUD" \
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
echo "  gh release create v$VERSION '$DIST_DIR/$ZIP_NAME' --title 'Claude HUD v$VERSION' --notes 'Release v$VERSION'"
echo ""

if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Note: This build is NOT notarized. Users will see security warnings.${NC}"
    echo "To notarize, run without --skip-notarization flag."
    echo ""
fi
