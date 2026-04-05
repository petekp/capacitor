#!/bin/bash

# Bump version across all project files
# Usage: ./bump-version.sh <major|minor|patch|X.Y.Z[-prerelease][+build]>
#
# Examples:
#   ./bump-version.sh patch     # 0.1.0 -> 0.1.1
#   ./bump-version.sh minor     # 0.1.0 -> 0.2.0
#   ./bump-version.sh major     # 0.1.0 -> 1.0.0
#   ./bump-version.sh 2.0.0     # Set explicit version

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"
CARGO_TOML="$PROJECT_ROOT/Cargo.toml"

if [ -z "$1" ]; then
    echo "Usage: $0 <major|minor|patch|X.Y.Z[-prerelease][+build]>"
    echo ""
    echo "Examples:"
    echo "  $0 patch     # 0.1.0 -> 0.1.1"
    echo "  $0 minor     # 0.1.0 -> 0.2.0"
    echo "  $0 major     # 0.1.0 -> 1.0.0"
    echo "  $0 2.0.0     # Set explicit version"
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo -e "${YELLOW}Current version: $CURRENT_VERSION${NC}"

CURRENT_VERSION_BASE="${CURRENT_VERSION%%-*}"
CURRENT_VERSION_BASE="${CURRENT_VERSION_BASE%%+*}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION_BASE"

case "$1" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        ;;
    patch)
        PATCH=$((PATCH + 1))
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        ;;
    *)
        if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([\-+][0-9A-Za-z.-]+)?$ ]]; then
            NEW_VERSION="$1"
        else
            echo -e "${RED}ERROR: Invalid version format. Use major|minor|patch or X.Y.Z[-prerelease][+build]${NC}"
            exit 1
        fi
        ;;
esac

echo -e "${GREEN}New version: $NEW_VERSION${NC}"
echo ""

echo -e "${YELLOW}Updating VERSION file...${NC}"
echo "$NEW_VERSION" > "$VERSION_FILE"
echo -e "${GREEN}✓ VERSION file updated${NC}"

echo -e "${YELLOW}Updating Cargo.toml workspace version...${NC}"
if [ -f "$CARGO_TOML" ]; then
    sed -i '' -E "s/^version = \"[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?\"/version = \"$NEW_VERSION\"/" "$CARGO_TOML"
    echo -e "${GREEN}✓ Cargo.toml updated${NC}"
else
    echo -e "${YELLOW}⚠ Cargo.toml not found, skipping${NC}"
fi

# Update App.swift fallback version (used when Info.plist isn't available in dev builds)
APP_SWIFT="$PROJECT_ROOT/apps/swift/Sources/Capacitor/App.swift"
if [ -f "$APP_SWIFT" ]; then
    echo -e "${YELLOW}Updating App.swift fallback version...${NC}"
    sed -i '' -E "s/return \"[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?\"  *\/\/ Ultimate fallback/return \"$NEW_VERSION\" \/\/ Ultimate fallback/" "$APP_SWIFT"
    # Alternative pattern without the comment (backwards compatibility)
    sed -i '' -E "s/return \"[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?\"\$/return \"$NEW_VERSION\"/" "$APP_SWIFT"
    echo -e "${GREEN}✓ App.swift fallback version updated${NC}"
fi

# Verify all version surfaces match
echo -e "${YELLOW}Verifying version sync...${NC}"
SYNC_OK=true
VERSION_FILE_CONTENT=$(cat "$VERSION_FILE" | tr -d '[:space:]')
CARGO_VERSION=$(grep -m1 '^version = ' "$CARGO_TOML" | sed -E 's/version = "(.*)"/\1/')
SWIFT_VERSION=$(grep -o 'return "[0-9][0-9.a-zA-Z-]*"' "$APP_SWIFT" | tail -1 | sed -E 's/return "(.*)"/\1/')

if [ "$VERSION_FILE_CONTENT" != "$NEW_VERSION" ]; then
    echo -e "${RED}✗ VERSION file mismatch: got '$VERSION_FILE_CONTENT'${NC}"
    SYNC_OK=false
fi
if [ "$CARGO_VERSION" != "$NEW_VERSION" ]; then
    echo -e "${RED}✗ Cargo.toml mismatch: got '$CARGO_VERSION'${NC}"
    SYNC_OK=false
fi
if [ "$SWIFT_VERSION" != "$NEW_VERSION" ]; then
    echo -e "${RED}✗ App.swift fallback mismatch: got '$SWIFT_VERSION'${NC}"
    SYNC_OK=false
fi
if [ "$SYNC_OK" = true ]; then
    echo -e "${GREEN}✓ All version surfaces in sync${NC}"
else
    echo -e "${RED}Version sync failed! Check the files above.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Version bumped to $NEW_VERSION${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Commit: git commit -am \"Bump version to $NEW_VERSION\""
echo "  3. Tag: git tag v$NEW_VERSION"
echo "  4. Build: ./scripts/release/build-distribution.sh"
echo "  5. Push: git push && git push --tags"
echo ""
