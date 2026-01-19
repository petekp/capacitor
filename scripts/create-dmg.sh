#!/bin/bash

# Create DMG installer for Claude HUD
# Usage: ./create-dmg.sh [--skip-notarization]
#
# Prerequisites:
# - App bundle must exist at apps/swift/ClaudeHUD.app
# - Developer ID Application certificate for signing
# - Notarization credentials (unless --skip-notarization)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"
APP_BUNDLE="$SWIFT_DIR/ClaudeHUD.app"
DIST_DIR="$PROJECT_ROOT/dist"

SKIP_NOTARIZATION=false
if [ "$1" = "--skip-notarization" ]; then
    SKIP_NOTARIZATION=true
fi

VERSION_FILE="$PROJECT_ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Creating DMG for Claude HUD v$VERSION${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}ERROR: App bundle not found at $APP_BUNDLE${NC}"
    echo "Run ./scripts/build-distribution.sh first"
    exit 1
fi

CERT_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1)
if [ -z "$CERT_LINE" ]; then
    echo -e "${RED}ERROR: No Developer ID Application certificate found!${NC}"
    exit 1
fi
SIGNING_IDENTITY=$(echo "$CERT_LINE" | awk '{print $2}')
echo -e "${GREEN}✓ Using certificate: $(echo "$CERT_LINE" | awk -F'"' '{print $2}')${NC}"
echo ""

mkdir -p "$DIST_DIR"

DMG_NAME="ClaudeHUD-v$VERSION-$(uname -m).dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
VOLUME_NAME="Claude HUD"
TEMP_DIR=$(mktemp -d)

echo -e "${YELLOW}Step 1/4: Preparing DMG contents...${NC}"
cp -R "$APP_BUNDLE" "$TEMP_DIR/"
ln -s /Applications "$TEMP_DIR/Applications"
echo -e "${GREEN}✓ Contents prepared${NC}"
echo ""

echo -e "${YELLOW}Step 2/4: Creating DMG...${NC}"
rm -f "$DMG_PATH"

if [ -f "$PROJECT_ROOT/assets/dmg-background.png" ]; then
    mkdir -p "$TEMP_DIR/.background"
    cp "$PROJECT_ROOT/assets/dmg-background.png" "$TEMP_DIR/.background/background.png"

    hdiutil create -volname "$VOLUME_NAME" \
        -srcfolder "$TEMP_DIR" \
        -ov -format UDRW \
        "$DMG_PATH.tmp"

    DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_PATH.tmp" | egrep '^/dev/' | sed 1q | awk '{print $1}')

    echo '
       tell application "Finder"
         tell disk "'$VOLUME_NAME'"
           open
           set current view of container window to icon view
           set toolbar visible of container window to false
           set statusbar visible of container window to false
           set the bounds of container window to {400, 100, 1060, 500}
           set viewOptions to the icon view options of container window
           set arrangement of viewOptions to not arranged
           set icon size of viewOptions to 128
           set background picture of viewOptions to file ".background:background.png"
           set position of item "ClaudeHUD.app" of container window to {180, 170}
           set position of item "Applications" of container window to {480, 170}
           close
           open
           update without registering applications
           delay 2
         end tell
       end tell
    ' | osascript

    sync
    hdiutil detach "$DEVICE" -quiet

    hdiutil convert "$DMG_PATH.tmp" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$DMG_PATH.tmp"
else
    hdiutil create -volname "$VOLUME_NAME" \
        -srcfolder "$TEMP_DIR" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH"
fi

rm -rf "$TEMP_DIR"
echo -e "${GREEN}✓ DMG created${NC}"
echo ""

echo -e "${YELLOW}Step 3/4: Signing DMG...${NC}"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"
echo -e "${GREEN}✓ DMG signed${NC}"
echo ""

if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Skipping notarization (--skip-notarization flag)${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 4/4: Notarizing DMG...${NC}"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "ClaudeHUD" \
        --wait

    echo ""
    echo -e "${YELLOW}Stapling notarization ticket...${NC}"
    xcrun stapler staple "$DMG_PATH"
    echo -e "${GREEN}✓ Notarization complete${NC}"
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}DMG Created!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "DMG: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | awk '{print $1}')"
echo ""
echo "To verify: spctl -a -t open --context context:primary-signature '$DMG_PATH'"
echo ""

if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Note: This DMG is NOT notarized. Users will see security warnings.${NC}"
    echo ""
fi
