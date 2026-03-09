#!/bin/bash
# reset-for-testing.sh
#
# Resets Capacitor to a completely clean state for manual testing.
# Use this when you need to test onboarding, first-run experience,
# or verify behavior from a fresh install.
#
# What gets cleared:
#   - App UserDefaults (setupComplete, layout preferences, etc.)
#   - ~/.capacitor/ (session state, locks, file activity)
#   - Capacitor hook registrations in ~/.claude/settings.json
#
# What stays intact:
#   - Other ~/.claude/ config (Claude Code's own settings, other hooks)
#   - Hook binary (~/.local/bin/hud-hook)
#   - Source code and git state
#
# Usage: ./scripts/dev/reset-for-testing.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/load-runtime-env.sh"
CHANNEL="dev"
while [[ $# -gt 0 ]]; do
    case $1 in
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
        --help|-h)
            echo "Usage: reset-for-testing.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "      --alpha         Alias for --channel alpha"
            echo "      --channel NAME  Set runtime channel (dev|alpha|beta|prod)"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Capacitor - Complete Reset for Testing             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Stop the app
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Stopping Capacitor if running..."
pkill -f "Capacitor" 2>/dev/null && echo "  ✓ Killed running instance" || echo "  ✓ No instance running"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Clear UserDefaults
#
# IMPORTANT: macOS caches UserDefaults via cfprefsd. Using `defaults delete`
# alone doesn't work reliably—the cached values persist until the daemon
# refreshes. We must:
#   1. Delete the actual plist files from ~/Library/Preferences/
#   2. Kill cfprefsd to flush the cache (it auto-restarts)
#
# Different plist files exist depending on how the app was launched:
#   - Capacitor.plist         → `swift run` (uses executable name)
#   - com.capacitor.app.plist → Release build (uses bundle identifier)
#   - com.capacitor.app.debug.plist → Debug build
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Clearing app UserDefaults..."
rm -f ~/Library/Preferences/Capacitor.plist && echo "  ✓ Removed Capacitor.plist (swift run)" || true
rm -f ~/Library/Preferences/com.capacitor.app.plist && echo "  ✓ Removed com.capacitor.app.plist (release)" || true
rm -f ~/Library/Preferences/com.capacitor.app.debug.plist && echo "  ✓ Removed com.capacitor.app.debug.plist (debug)" || true

# Force cfprefsd to drop its cache. Without this, deleted prefs may reappear.
killall cfprefsd 2>/dev/null && echo "  ✓ Refreshed preferences cache" || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Clear runtime state directory
#
# ~/.capacitor/ is our namespace (sidecar architecture - we never write to
# ~/.claude/). Contains:
#   - runtime/app_snapshot.json: persisted runtime artifact for recovery/debugging
#   - runtime/: runtime service logs, tokens, and lock files
#   - config.json/projects.json: app preferences + pinned projects
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Clearing ~/.capacitor/ (runtime state)..."
if [[ -d "$HOME/.capacitor" ]]; then
    rm -rf "$HOME/.capacitor"
    echo "  ✓ Removed ~/.capacitor/"
else
    echo "  ✓ ~/.capacitor/ already clean"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Remove Capacitor hook registrations
#
# For a true fresh-install test, remove Capacitor hook registrations from
# ~/.claude/settings.json. This filters out both:
#   - Legacy wrapper script references (hud-state-tracker.sh)
#   - Current binary references (hud-hook)
#
# We do NOT uninstall the binary here—the app's onboarding flow will
# detect that hooks aren't configured and offer to add them.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Removing Capacitor hook registrations from settings.json..."
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    if command -v jq &>/dev/null; then
        # Filter out hook configs that contain "hud-hook" or "hud-state-tracker" in any command
        # Then remove any hook events that become empty arrays
        jq '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(
                        select(
                            .hooks == null or
                            (.hooks | map(.command // "" | (contains("hud-hook") or contains("hud-state-tracker"))) | any | not)
                        )
                    ) |
                    select(.value | length > 0)
                )
            else
                .
            end
        ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        echo "  ✓ Removed Capacitor hook registrations"
    else
        echo "  ⚠ jq not available, skipping settings.json cleanup"
        echo "    (Capacitor hooks will remain registered)"
    fi
else
    echo "  ✓ No settings.json to clean"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Remove installed hud-hook binary
#
# For true first-time experience testing, we remove the binary from ~/.local/bin.
# The app's onboarding flow should install it from the bundled copy.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "→ Removing installed hud-hook binary (for true first-time experience)..."
if [ -f "$HOME/.local/bin/hud-hook" ]; then
    rm "$HOME/.local/bin/hud-hook"
    echo "  ✓ Removed ~/.local/bin/hud-hook"
else
    echo "  ✓ ~/.local/bin/hud-hook already removed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Build and bundle hud-hook for development
#
# In release builds, hud-hook is bundled in Contents/Resources/. For dev builds,
# we copy it to the Swift build directory so Bundle.main can find it.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "→ Building hud-hook for development bundle..."
cd "$REPO_ROOT"
cargo build -p hud-hook --release 2>&1 | tail -3
echo "  ✓ hud-hook built"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Rebuild Swift app and bundle hud-hook
#
# Ensures we're testing the current code, not a stale build.
# Copy hud-hook to Swift build directory so Bundle.main can find it.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "→ Building Swift app..."
cd "$REPO_ROOT/apps/swift"
swift build 2>&1 | tail -3

# Copy hud-hook to Swift build directory (mimics release bundle structure)
SWIFT_DEBUG_DIR=$(swift build --show-bin-path)
cp "$REPO_ROOT/target/release/hud-hook" "$SWIFT_DEBUG_DIR/"
echo "  ✓ Swift build complete (hud-hook bundled)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Launch the app
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Reset Complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Launching Capacitor..."
echo ""

cd "$REPO_ROOT/apps/swift"
CAPACITOR_CHANNEL="$CHANNEL" swift run
