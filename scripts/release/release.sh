#!/bin/bash

# Full release workflow for Capacitor
# Usage: ./release.sh [version] [--skip-notarization] [--dry-run] [--alpha] [--channel <name>]
#
# Examples:
#   ./release.sh                    # Release current version
#   ./release.sh patch              # Bump patch, then release
#   ./release.sh 1.0.0              # Set version to 1.0.0, then release
#   ./release.sh --dry-run          # Build everything but don't push/release
#   ./release.sh patch --dry-run    # Bump and build, but don't push/release
#   ./release.sh --channel beta     # Build release artifacts for beta channel

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION_ARG=""
SKIP_NOTARIZATION=false
DRY_RUN=false
CHANNEL="alpha"

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-notarization)
            SKIP_NOTARIZATION=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --alpha)
            CHANNEL="alpha"
            shift
            ;;
        --channel)
            CHANNEL="${2:-$CHANNEL}"
            shift 2
            ;;
        --channel=*)
            CHANNEL="${1#*=}"
            shift
            ;;
        major|minor|patch|[0-9]*)
            VERSION_ARG="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Capacitor Release Workflow${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - Will not push or create release${NC}"
    echo ""
fi

if [ -n "$VERSION_ARG" ]; then
    echo -e "${YELLOW}Step 1/7: Bumping version...${NC}"
    "$SCRIPT_DIR/bump-version.sh" "$VERSION_ARG"
    echo ""
fi

VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
echo -e "${GREEN}Releasing version: $VERSION${NC}"
echo -e "${GREEN}Channel: $CHANNEL${NC}"
echo ""

echo -e "${YELLOW}Checking git status...${NC}"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    if [ -n "$VERSION_ARG" ]; then
        echo -e "${YELLOW}Committing version bump...${NC}"
        git add "$PROJECT_ROOT/VERSION" "$PROJECT_ROOT/Cargo.toml"
        git commit -m "Bump version to $VERSION"
        echo -e "${GREEN}✓ Version bump committed${NC}"
    else
        echo -e "${YELLOW}⚠ You have uncommitted changes. Consider committing them first.${NC}"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi
echo ""

BUILD_ARGS=()
if [ "$SKIP_NOTARIZATION" = true ]; then
    BUILD_ARGS+=(--skip-notarization)
fi
BUILD_ARGS+=(--channel "$CHANNEL")

DMG_ARGS=()
if [ "$SKIP_NOTARIZATION" = true ]; then
    DMG_ARGS+=(--skip-notarization)
fi

echo -e "${YELLOW}Step 2/7: Building distribution...${NC}"
"$SCRIPT_DIR/build-distribution.sh" "${BUILD_ARGS[@]}"
echo ""

echo -e "${YELLOW}Step 3/7: Creating DMG...${NC}"
"$SCRIPT_DIR/create-dmg.sh" "${DMG_ARGS[@]}"
echo ""

echo -e "${YELLOW}Step 4/7: Generating appcast...${NC}"
"$SCRIPT_DIR/generate-appcast.sh" --sign
echo ""

DIST_DIR="$PROJECT_ROOT/dist"
ARCH=$(uname -m)
ZIP_PATH="$DIST_DIR/Capacitor-v$VERSION-$ARCH.zip"
DMG_PATH="$DIST_DIR/Capacitor-v$VERSION-$ARCH.dmg"
APPCAST_PATH="$DIST_DIR/appcast.xml"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Step 5/7: Would tag release (DRY RUN)${NC}"
    echo "  git tag v$VERSION"
    echo ""

    echo -e "${YELLOW}Step 6/7: Would push (DRY RUN)${NC}"
    echo "  git push && git push --tags"
    echo ""

    echo -e "${YELLOW}Step 7/7: Would create GitHub release (DRY RUN)${NC}"
    echo "  gh release create v$VERSION \\"
    echo "    '$ZIP_PATH' \\"
    echo "    '$DMG_PATH' \\"
    echo "    '$APPCAST_PATH' \\"
    echo "    --title 'Capacitor v$VERSION' \\"
    echo "    --generate-notes"
    echo ""
else
    echo -e "${YELLOW}Step 5/7: Creating git tag...${NC}"
    if git rev-parse "v$VERSION" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Tag v$VERSION already exists, skipping${NC}"
    else
        git tag "v$VERSION"
        echo -e "${GREEN}✓ Tagged v$VERSION${NC}"
    fi
    echo ""

    echo -e "${YELLOW}Step 6/7: Pushing to remote...${NC}"
    git push
    git push --tags
    echo -e "${GREEN}✓ Pushed to remote${NC}"
    echo ""

    echo -e "${YELLOW}Step 7/7: Creating GitHub release...${NC}"

    RELEASE_FILES=("$ZIP_PATH" "$APPCAST_PATH")
    if [ -f "$DMG_PATH" ]; then
        RELEASE_FILES+=("$DMG_PATH")
    fi

    gh release create "v$VERSION" \
        "${RELEASE_FILES[@]}" \
        --title "Capacitor v$VERSION" \
        --generate-notes

    echo -e "${GREEN}✓ GitHub release created${NC}"
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Release Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Version: $VERSION"
echo ""
echo "Artifacts:"
echo "  - ZIP: $ZIP_PATH"
[ -f "$DMG_PATH" ] && echo "  - DMG: $DMG_PATH"
echo "  - Appcast: $APPCAST_PATH"
echo ""

if [ "$DRY_RUN" = false ]; then
    echo "Release URL: https://github.com/petekp/capacitor/releases/tag/v$VERSION"
    echo ""
fi

if [ "$SKIP_NOTARIZATION" = true ]; then
    echo -e "${YELLOW}Note: Artifacts are NOT notarized. Users will see security warnings.${NC}"
    echo ""
fi
