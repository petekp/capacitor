#!/bin/bash

# Bump version across all project files
# Usage: ./bump-version.sh <major|minor|patch|X.Y.Z>
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
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_ROOT/VERSION"
CARGO_TOML="$PROJECT_ROOT/Cargo.toml"

if [ -z "$1" ]; then
    echo "Usage: $0 <major|minor|patch|X.Y.Z>"
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

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$1" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IFS='.' read -r MAJOR MINOR PATCH <<< "$1"
        else
            echo -e "${RED}ERROR: Invalid version format. Use major|minor|patch or X.Y.Z${NC}"
            exit 1
        fi
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
echo -e "${GREEN}New version: $NEW_VERSION${NC}"
echo ""

echo -e "${YELLOW}Updating VERSION file...${NC}"
echo "$NEW_VERSION" > "$VERSION_FILE"
echo -e "${GREEN}✓ VERSION file updated${NC}"

echo -e "${YELLOW}Updating Cargo.toml workspace version...${NC}"
if [ -f "$CARGO_TOML" ]; then
    sed -i '' "s/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/version = \"$NEW_VERSION\"/" "$CARGO_TOML"
    echo -e "${GREEN}✓ Cargo.toml updated${NC}"
else
    echo -e "${YELLOW}⚠ Cargo.toml not found, skipping${NC}"
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
echo "  4. Build: ./scripts/build-distribution.sh"
echo "  5. Push: git push && git push --tags"
echo ""
