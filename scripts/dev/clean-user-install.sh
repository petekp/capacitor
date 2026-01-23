#!/bin/bash
# Clean all Claude HUD artifacts from user's system for fresh install testing
#
# This removes:
# - Installed app from /Applications
# - Hook binary from ~/.local/bin
# - All HUD data from ~/.capacitor
# - Hook configuration from ~/.claude/settings.json
#
# It does NOT remove:
# - ~/.claude/ directory (belongs to Claude Code)
# - Claude Code sessions or transcripts
#
# Usage: ./clean-user-install.sh [--dry-run]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Claude HUD Clean Install Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "This will remove all Claude HUD artifacts to simulate a first-time install."
echo ""

# Track what we'll clean
ITEMS_TO_CLEAN=()

# 1. Check for installed app
if [[ -d "/Applications/ClaudeHUD.app" ]]; then
    ITEMS_TO_CLEAN+=("/Applications/ClaudeHUD.app")
    echo -e "${YELLOW}Found:${NC} /Applications/ClaudeHUD.app"
fi

# 2. Check for hook binary
if [[ -f "$HOME/.local/bin/hud-hook" ]]; then
    ITEMS_TO_CLEAN+=("$HOME/.local/bin/hud-hook")
    echo -e "${YELLOW}Found:${NC} ~/.local/bin/hud-hook"
fi

# 3. Check for capacitor data directory
if [[ -d "$HOME/.capacitor" ]]; then
    ITEMS_TO_CLEAN+=("$HOME/.capacitor")
    echo -e "${YELLOW}Found:${NC} ~/.capacitor/ ($(du -sh "$HOME/.capacitor" 2>/dev/null | cut -f1) of data)"
fi

# 4. Check for hooks in settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    if grep -q "hud-hook" "$SETTINGS_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Found:${NC} HUD hooks in ~/.claude/settings.json"
        ITEMS_TO_CLEAN+=("hooks-in-settings")
    fi
fi

# 5. Check for any running ClaudeHUD processes
if pgrep -f "ClaudeHUD" > /dev/null 2>&1; then
    echo -e "${YELLOW}Found:${NC} Running ClaudeHUD process(es)"
    ITEMS_TO_CLEAN+=("running-process")
fi

# 6. Check for UserDefaults (setupComplete flag)
# UserDefaults may be stored under different bundle identifiers depending on version
for prefs in "$HOME/Library/Preferences/com.claudehud.app.plist" \
             "$HOME/Library/Preferences/ClaudeHUD.plist"; do
    if [[ -f "$prefs" ]]; then
        echo -e "${YELLOW}Found:${NC} App preferences: $(basename "$prefs")"
        ITEMS_TO_CLEAN+=("$prefs")
    fi
done

echo ""

if [[ ${#ITEMS_TO_CLEAN[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ System is already clean - no Claude HUD artifacts found${NC}"
    exit 0
fi

# Confirm before proceeding
if [[ "$DRY_RUN" == "false" ]]; then
    echo -e "${RED}This will permanently delete the items listed above.${NC}"
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# Perform cleanup
for item in "${ITEMS_TO_CLEAN[@]}"; do
    case "$item" in
        "running-process")
            echo -n "Stopping ClaudeHUD processes... "
            if [[ "$DRY_RUN" == "false" ]]; then
                pkill -f "ClaudeHUD" 2>/dev/null || true
                sleep 1
            fi
            echo -e "${GREEN}done${NC}"
            ;;
        "hooks-in-settings")
            echo -n "Removing hooks from ~/.claude/settings.json... "
            if [[ "$DRY_RUN" == "false" ]]; then
                # Use jq to remove all hooks that reference hud-hook
                if command -v jq &> /dev/null; then
                    # Remove the entire hooks object to start fresh
                    # (User can reconfigure via "Fix All" in the app)
                    jq 'del(.hooks)' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && \
                        mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
                else
                    echo -e "${YELLOW}skipped (jq not installed)${NC}"
                    continue
                fi
            fi
            echo -e "${GREEN}done${NC}"
            ;;
        */Library/Preferences/*.plist)
            # UserDefaults are cached by cfprefsd - must use defaults delete, not rm
            BUNDLE_ID=$(basename "$item" .plist)
            echo -n "Clearing UserDefaults for $BUNDLE_ID... "
            if [[ "$DRY_RUN" == "false" ]]; then
                defaults delete "$BUNDLE_ID" 2>/dev/null || true
                rm -f "$item" 2>/dev/null || true
            fi
            echo -e "${GREEN}done${NC}"
            ;;
        *)
            echo -n "Removing $item... "
            if [[ "$DRY_RUN" == "false" ]]; then
                rm -rf "$item"
            fi
            echo -e "${GREEN}done${NC}"
            ;;
    esac
done

# Restart cfprefsd to flush UserDefaults cache (it auto-restarts)
if [[ "$DRY_RUN" == "false" ]]; then
    echo -n "Flushing UserDefaults cache... "
    killall cfprefsd 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}done${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cleanup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Your system is now in a first-time user state."
echo "Install Claude HUD from the DMG to test the onboarding flow."
