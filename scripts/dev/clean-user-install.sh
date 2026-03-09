#!/bin/bash
# Clean all Capacitor artifacts from user's system for fresh install testing
#
# This removes:
# - Installed app from /Applications
# - Hook binary from ~/.local/bin
# - All Capacitor data from ~/.capacitor
# - Hook configuration from ~/.claude/settings.json
#
# It does NOT remove:
# - ~/.claude/ directory (belongs to Claude Code)
# - Claude Code sessions or transcripts
#
# Usage: ./scripts/dev/clean-user-install.sh [--dry-run]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
    echo ""
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: ./scripts/dev/clean-user-install.sh [--dry-run]"
    exit 0
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Capacitor Clean Install Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "This will remove all Capacitor artifacts to simulate a first-time install."
echo ""

# Track what we'll clean
ITEMS_TO_CLEAN=()

# 1. Check for installed app
if [[ -d "/Applications/Capacitor.app" ]]; then
    ITEMS_TO_CLEAN+=("/Applications/Capacitor.app")
    echo -e "${YELLOW}Found:${NC} /Applications/Capacitor.app"
fi

# 2. Check for hook binary
if [[ -f "$HOME/.local/bin/capacitor-hook" ]]; then
    ITEMS_TO_CLEAN+=("$HOME/.local/bin/capacitor-hook")
    echo -e "${YELLOW}Found:${NC} ~/.local/bin/capacitor-hook"
fi


# 3. Check for capacitor data directory
if [[ -d "$HOME/.capacitor" ]]; then
    ITEMS_TO_CLEAN+=("$HOME/.capacitor")
    echo -e "${YELLOW}Found:${NC} ~/.capacitor/ ($(du -sh "$HOME/.capacitor" 2>/dev/null | cut -f1) of data)"
fi

# 4. Check for hooks in settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    if grep -q "capacitor-hook" "$SETTINGS_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Found:${NC} Capacitor hooks in ~/.claude/settings.json"
        ITEMS_TO_CLEAN+=("hooks-in-settings")
    fi
fi

# 5. Check for any running Capacitor processes
if pgrep -f "Capacitor" > /dev/null 2>&1; then
    echo -e "${YELLOW}Found:${NC} Running Capacitor process(es)"
    ITEMS_TO_CLEAN+=("running-process")
fi

# 6. Check for UserDefaults (setupComplete flag)
# UserDefaults may be stored under different bundle identifiers depending on version
for prefs in "$HOME/Library/Preferences/com.capacitor.app.plist" \
             "$HOME/Library/Preferences/com.capacitor.app.debug.plist" \
             "$HOME/Library/Preferences/Capacitor.plist"; do
    if [[ -f "$prefs" ]]; then
        echo -e "${YELLOW}Found:${NC} App preferences: $(basename "$prefs")"
        ITEMS_TO_CLEAN+=("$prefs")
    fi
done

echo ""

if [[ ${#ITEMS_TO_CLEAN[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ System is already clean - no Capacitor artifacts found${NC}"
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
            echo -n "Stopping Capacitor processes... "
            if [[ "$DRY_RUN" == "false" ]]; then
                pkill -f "Capacitor" 2>/dev/null || true
                sleep 1
            fi
            echo -e "${GREEN}done${NC}"
            ;;
        "hooks-in-settings")
            echo -n "Removing hooks from ~/.claude/settings.json... "
            if [[ "$DRY_RUN" == "false" ]]; then
                if command -v jq &> /dev/null; then
                    jq '
                        def is_capacitor_hook:
                            ((.hooks // []) | any(
                                (.url // "") == "http://127.0.0.1:7474/hook" or
                                ((.command // "") | contains("capacitor-hook"))
                            ));
                        if .hooks then
                            .hooks |= with_entries(
                                .value |= map(select(is_capacitor_hook | not)) |
                                select(.value | length > 0)
                            )
                        else
                            .
                        end
                    ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
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
echo "Install Capacitor from the DMG to test the onboarding flow."
