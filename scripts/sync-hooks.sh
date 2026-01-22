#!/bin/bash
# Sync hook scripts and binary from repo to installed location
# Prevents version mismatches between repo and installed hooks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_HOOK="$SCRIPT_DIR/hud-state-tracker.sh"
INSTALLED_HOOK="$HOME/.claude/scripts/hud-state-tracker.sh"
INSTALLED_BINARY="$HOME/.local/bin/hud-hook"

get_version() {
    grep -m1 "^# Claude HUD State Tracker Hook v" "$1" 2>/dev/null | sed 's/.*v//' | sed 's/ .*//' || echo "unknown"
}

if [[ ! -f "$REPO_HOOK" ]]; then
    echo "Error: Repo hook not found at $REPO_HOOK"
    exit 1
fi

REPO_VERSION=$(get_version "$REPO_HOOK")

echo "=== Claude HUD Hook Sync (v$REPO_VERSION) ==="
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

# Install/update wrapper script
echo ""
echo "Installing wrapper script..."
mkdir -p "$(dirname "$INSTALLED_HOOK")"

if [[ ! -f "$INSTALLED_HOOK" ]]; then
    cp "$REPO_HOOK" "$INSTALLED_HOOK"
    chmod +x "$INSTALLED_HOOK"
    echo "  ✓ Wrapper script installed"
else
    INSTALLED_VERSION=$(get_version "$INSTALLED_HOOK")

    if [[ "$REPO_VERSION" == "$INSTALLED_VERSION" ]]; then
        REPO_HASH=$(shasum -a 256 "$REPO_HOOK" | cut -d' ' -f1)
        INSTALLED_HASH=$(shasum -a 256 "$INSTALLED_HOOK" | cut -d' ' -f1)

        if [[ "$REPO_HASH" == "$INSTALLED_HASH" ]]; then
            echo "  ✓ Wrapper script v$REPO_VERSION is current"
        else
            echo "  ⚠ Wrapper script v$REPO_VERSION content differs"
            if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
                cp "$REPO_HOOK" "$INSTALLED_HOOK"
                chmod +x "$INSTALLED_HOOK"
                echo "  ✓ Wrapper script updated"
            else
                echo "  Run with --force to update"
            fi
        fi
    else
        echo "  ⚠ Wrapper script version mismatch (installed: v$INSTALLED_VERSION)"
        if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
            cp "$REPO_HOOK" "$INSTALLED_HOOK"
            chmod +x "$INSTALLED_HOOK"
            echo "  ✓ Wrapper script updated to v$REPO_VERSION"
        else
            echo "  Run with --force to update"
        fi
    fi
fi

echo ""
echo "Done!"
