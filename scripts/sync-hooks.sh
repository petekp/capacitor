#!/bin/bash
# Sync hud-hook binary from repo to installed location
# The binary is called directly by Claude Code hooks (no wrapper script needed)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

# Check/build binary
echo "Checking binary..."
NEED_BUILD=false

if [[ ! -f "$REPO_ROOT/target/release/hud-hook" ]]; then
    NEED_BUILD=true
    echo "  Binary not built yet"
elif [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
    NEED_BUILD=true
    echo "  Force rebuild requested"
fi

if [[ "$NEED_BUILD" == "true" ]]; then
    echo "  Building hud-hook binary..."
    (cd "$REPO_ROOT" && cargo build -p hud-hook --release)
    echo "  ✓ Binary built"
fi

# Install binary
echo ""
echo "Installing binary..."
mkdir -p "$(dirname "$INSTALLED_BINARY")"

if [[ -f "$INSTALLED_BINARY" ]]; then
    REPO_BINARY_HASH=$(shasum -a 256 "$REPO_ROOT/target/release/hud-hook" 2>/dev/null | cut -d' ' -f1 || echo "none")
    INSTALLED_BINARY_HASH=$(shasum -a 256 "$INSTALLED_BINARY" 2>/dev/null | cut -d' ' -f1 || echo "none")

    if [[ "$REPO_BINARY_HASH" == "$INSTALLED_BINARY_HASH" ]]; then
        echo "  ✓ Binary is current"
    else
        cp "$REPO_ROOT/target/release/hud-hook" "$INSTALLED_BINARY"
        chmod +x "$INSTALLED_BINARY"
        # Ad-hoc codesign required for macOS to allow execution
        codesign -s - -f "$INSTALLED_BINARY" 2>/dev/null || true
        echo "  ✓ Binary updated"
    fi
else
    cp "$REPO_ROOT/target/release/hud-hook" "$INSTALLED_BINARY"
    chmod +x "$INSTALLED_BINARY"
    # Ad-hoc codesign required for macOS to allow execution
    codesign -s - -f "$INSTALLED_BINARY" 2>/dev/null || true
    echo "  ✓ Binary installed to $INSTALLED_BINARY"
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
        echo "  ⚠ Binary killed by macOS (SIGKILL) - re-codesigning..."
        codesign -s - -f "$INSTALLED_BINARY" 2>/dev/null
        verify_binary "$INSTALLED_BINARY"
        if [[ $? -eq 0 ]]; then
            echo "  ✓ Binary health check passed after codesign"
        else
            echo "  ✗ FATAL: Binary still fails after codesign"
            echo "    Try: xattr -c $INSTALLED_BINARY"
            exit 1
        fi
        ;;
    2)
        echo "  ✗ FATAL: Binary not executable"
        exit 1
        ;;
esac

echo ""
echo "Done! The hud-hook binary is ready."
echo ""
echo "To configure Claude Code hooks, run the app and use the 'Fix All' button,"
echo "or manually add hooks to ~/.claude/settings.json pointing to:"
echo "  $INSTALLED_BINARY handle"
