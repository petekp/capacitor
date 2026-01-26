#!/bin/bash
# Sync hud-hook binary from repo to installed location
# The binary is called directly by Claude Code hooks (no wrapper script needed)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Architecture validation - Apple Silicon only
if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: This project requires Apple Silicon (arm64)." >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi
INSTALLED_BINARY="$HOME/.local/bin/hud-hook"

# Verify binary actually runs (not just exists)
# Returns: 0 = works, 1 = needs codesign, 2 = fatal
verify_binary() {
    local binary="$1"

    if [[ ! -x "$binary" ]]; then
        return 2
    fi

    # Send empty JSON and check exit code
    local exit_code
    echo '{}' | "$binary" handle 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 137 ]]; then
        # SIGKILL - macOS killed unsigned binary
        return 1
    elif [[ $exit_code -eq 0 ]]; then
        return 0
    else
        # Other error - might still work for real events
        return 0
    fi
}

echo "=== Claude HUD Hook Binary Sync ==="
echo ""

# Determine binary source: app bundle (preferred) or repo build (dev fallback)
# Priority order:
#   1. /Applications/Capacitor.app (system-wide install)
#   2. ~/Applications/Capacitor.app (user install)
#   3. $REPO_ROOT/target/release/hud-hook (dev build)
echo "Finding binary source..."
SOURCE_BINARY=""
SOURCE_TYPE=""

APP_LOCATIONS=(
    "/Applications/Capacitor.app/Contents/Resources/hud-hook"
    "$HOME/Applications/Capacitor.app/Contents/Resources/hud-hook"
)

for app_binary in "${APP_LOCATIONS[@]}"; do
    if [[ -f "$app_binary" ]]; then
        SOURCE_BINARY="$app_binary"
        SOURCE_TYPE="app bundle"
        echo "  Found installed app: $(dirname "$(dirname "$(dirname "$app_binary")")")"
        break
    fi
done

# Fallback to repo build for development
if [[ -z "$SOURCE_BINARY" ]]; then
    REPO_BINARY="$REPO_ROOT/target/release/hud-hook"

    # Check/build binary
    NEED_BUILD=false

    if [[ ! -f "$REPO_BINARY" ]]; then
        NEED_BUILD=true
        echo "  Binary not built yet (no installed app found)"
    elif [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
        NEED_BUILD=true
        echo "  Force rebuild requested"
    fi

    if [[ "$NEED_BUILD" == "true" ]]; then
        echo "  Building hud-hook binary..."
        (cd "$REPO_ROOT" && cargo build -p hud-hook --release)
        echo "  ✓ Binary built"
    fi

    SOURCE_BINARY="$REPO_BINARY"
    SOURCE_TYPE="repo build"
    echo "  Using dev build: $REPO_BINARY"
fi

# Install binary (symlink to avoid macOS code signature issues)
# Copying adhoc-signed binaries can trigger SIGKILL from Gatekeeper.
# Symlinks point to the original signed binary, bypassing this issue.
echo ""
echo "Installing binary (symlink to $SOURCE_TYPE)..."
mkdir -p "$(dirname "$INSTALLED_BINARY")"

if [[ -L "$INSTALLED_BINARY" ]]; then
    # Existing symlink - check if it points to the right place
    CURRENT_TARGET=$(readlink "$INSTALLED_BINARY" 2>/dev/null || echo "")
    if [[ "$CURRENT_TARGET" == "$SOURCE_BINARY" ]]; then
        echo "  ✓ Symlink is current"
    else
        rm -f "$INSTALLED_BINARY"
        ln -s "$SOURCE_BINARY" "$INSTALLED_BINARY"
        echo "  ✓ Symlink updated (was: $CURRENT_TARGET)"
    fi
elif [[ -f "$INSTALLED_BINARY" ]]; then
    # Regular file exists - replace with symlink
    rm -f "$INSTALLED_BINARY"
    ln -s "$SOURCE_BINARY" "$INSTALLED_BINARY"
    echo "  ✓ Replaced file with symlink"
else
    ln -s "$SOURCE_BINARY" "$INSTALLED_BINARY"
    echo "  ✓ Symlink created: $INSTALLED_BINARY -> $SOURCE_BINARY"
fi

# Verify binary actually works
echo ""
echo "Verifying binary..."
verify_binary "$INSTALLED_BINARY"
case $? in
    0)
        echo "  ✓ Binary health check passed"
        ;;
    1)
        echo "  ⚠ Binary killed by macOS (SIGKILL)"
        echo "    This shouldn't happen with symlinks. Trying to codesign source..."
        codesign -s - -f "$SOURCE_BINARY" 2>/dev/null || true
        verify_binary "$INSTALLED_BINARY"
        if [[ $? -eq 0 ]]; then
            echo "  ✓ Binary health check passed after codesign"
        else
            echo "  ✗ FATAL: Binary still fails after codesign"
            echo "    Try: xattr -cr $SOURCE_BINARY"
            exit 1
        fi
        ;;
    2)
        echo "  ✗ FATAL: Binary not executable"
        echo "    Check that the symlink target exists: $SOURCE_BINARY"
        exit 1
        ;;
esac

echo ""
echo "Done! The hud-hook binary is ready."
echo ""
echo "To configure Claude Code hooks, run the app and use the 'Fix All' button,"
echo "or manually add hooks to ~/.claude/settings.json pointing to:"
echo "  $INSTALLED_BINARY handle"
