#!/bin/bash

# Generate Sparkle appcast.xml for Capacitor
# Usage: ./generate-appcast.sh [--sign]
#
# The --sign flag will sign the appcast with EdDSA.
# Requires SPARKLE_PRIVATE_KEY_PATH environment variable or sparkle_private_key.pem in project root.

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
DIST_DIR="$PROJECT_ROOT/dist"
SWIFT_DIR="$PROJECT_ROOT/apps/swift"

SIGN_APPCAST=false
if [ "$1" = "--sign" ]; then
    SIGN_APPCAST=true
fi

VERSION_FILE="$PROJECT_ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

# Get build number from the built app (Sparkle compares sparkle:version against CFBundleVersion)
APP_PATH="$SWIFT_DIR/Capacitor.app"
if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
fi
if [ -z "$BUILD_NUMBER" ]; then
    echo -e "${RED}ERROR: Could not extract CFBundleVersion from $APP_PATH${NC}"
    echo "Make sure the app is built first: ./scripts/release/build-distribution.sh"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Generating Appcast for v$VERSION${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

ARCH=$(uname -m)
ZIP_NAME="Capacitor-v$VERSION-$ARCH.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

if [ ! -f "$ZIP_PATH" ]; then
    echo -e "${RED}ERROR: ZIP not found at $ZIP_PATH${NC}"
    echo "Run ./scripts/release/build-distribution.sh first"
    exit 1
fi

GITHUB_REPO="petekp/capacitor"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME"

FILE_SIZE=$(stat -f%z "$ZIP_PATH")

PUB_DATE=$(date -R)

echo -e "${YELLOW}Generating appcast.xml...${NC}"

SIGNATURE=""
ED_SIGNATURE=""
if [ "$SIGN_APPCAST" = true ]; then
    SPARKLE_BIN="$SWIFT_DIR/.build/artifacts/sparkle/Sparkle/bin"

    if [ -f "$SPARKLE_BIN/sign_update" ]; then
        echo -e "${YELLOW}Signing with Sparkle's sign_update tool...${NC}"
        SIGN_OUTPUT=$("$SPARKLE_BIN/sign_update" "$ZIP_PATH" 2>&1)
        if [ $? -eq 0 ]; then
            ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"$//')
            if [ -n "$ED_SIGNATURE" ]; then
                echo -e "${GREEN}✓ Signature generated${NC}"
            fi
        fi
    fi

    if [ -z "$ED_SIGNATURE" ]; then
        echo -e "${YELLOW}⚠ Could not generate signature. Appcast will be unsigned.${NC}"
        echo "  Make sure you've run 'swift package resolve' and have a key in keychain"
    fi
fi

SIGNATURE_ATTR=""
if [ -n "$ED_SIGNATURE" ]; then
    SIGNATURE_ATTR="sparkle:edSignature=\"$ED_SIGNATURE\""
fi

cat > "$DIST_DIR/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Capacitor Updates</title>
        <link>https://github.com/$GITHUB_REPO</link>
        <description>Most recent updates to Capacitor</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$FILE_SIZE"
                type="application/octet-stream"
                $SIGNATURE_ATTR
            />
            <description><![CDATA[
                <h2>Capacitor v$VERSION</h2>
                <p>See <a href="https://github.com/$GITHUB_REPO/releases/tag/v$VERSION">release notes</a> for details.</p>
            ]]></description>
        </item>
    </channel>
</rss>
EOF

echo -e "${GREEN}✓ Appcast generated: $DIST_DIR/appcast.xml${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Appcast Ready${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Appcast: $DIST_DIR/appcast.xml"
echo "Download URL: $DOWNLOAD_URL"
echo "Version: $VERSION (build $BUILD_NUMBER)"
echo "File size: $FILE_SIZE bytes"
if [ -n "$ED_SIGNATURE" ]; then
    echo "Signed: Yes (EdDSA)"
else
    echo "Signed: No"
fi
echo ""
echo "Upload both files to GitHub release:"
echo "  - $ZIP_PATH"
echo "  - $DIST_DIR/appcast.xml"
echo ""
