#!/bin/bash

# Test build script using Development certificate
# This verifies dylib bundling works before getting Developer ID cert

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"
APP_BUNDLE="$SWIFT_DIR/ClaudeHUD.app"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ClaudeHUD Test Build${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Use Development certificate for testing (use hash to avoid ambiguity)
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
SIGNING_NAME=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')
echo -e "${GREEN}✓ Using certificate: $SIGNING_NAME${NC}"
echo -e "${GREEN}  Identity: $SIGNING_IDENTITY${NC}"
echo ""

# Build Rust library
echo -e "${YELLOW}Building Rust library...${NC}"
cd "$PROJECT_ROOT"
cargo build -p hud-core --release
echo -e "${GREEN}✓ Rust library built${NC}"
echo ""

# Fix dylib install_name
echo -e "${YELLOW}Fixing dylib install_name...${NC}"
DYLIB_PATH="$PROJECT_ROOT/target/release/libhud_core.dylib"
install_name_tool -id "@rpath/libhud_core.dylib" "$DYLIB_PATH"
echo -e "${GREEN}✓ Dylib install_name updated${NC}"
echo ""

# Build Swift app
echo -e "${YELLOW}Building Swift app...${NC}"
cd "$SWIFT_DIR"
swift build -c release
echo -e "${GREEN}✓ Swift app built${NC}"
echo ""

# Create app bundle
echo -e "${YELLOW}Creating app bundle...${NC}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable and dylib
cp "$SWIFT_DIR/.build/release/ClaudeHUD" "$APP_BUNDLE/Contents/MacOS/ClaudeHUD"
cp "$DYLIB_PATH" "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"

# Add rpath to find dylib
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/ClaudeHUD"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeHUD</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudehud.app</string>
    <key>CFBundleName</key>
    <string>Claude HUD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0-test</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo -e "${GREEN}✓ App bundle created${NC}"
echo ""

# Code sign
echo -e "${YELLOW}Code signing (ad-hoc for testing)...${NC}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libhud_core.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
echo -e "${GREEN}✓ Signed${NC}"
echo ""

# Verify dylib linking
echo -e "${YELLOW}Verifying dylib linking...${NC}"
otool -L "$APP_BUNDLE/Contents/MacOS/ClaudeHUD" | grep libhud_core
echo -e "${GREEN}✓ Dylib correctly linked${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Test Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To test:"
echo "  open '$APP_BUNDLE'"
echo ""
echo "This is a test build with Development certificate."
echo "For distribution, run ./scripts/build-distribution.sh after getting Developer ID cert."
