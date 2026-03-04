#!/usr/bin/env bash
# terminal-abstraction-guard.sh — CI ratchet guard for the terminal abstraction migration.
# Each ratchet enforces a maximum count of a specific anti-pattern in the orchestrator.
# Budgets decrease as slices are completed. Target: all reach 0.
set -euo pipefail

LAUNCHER="apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift"
FAILED=0

check_ratchet() {
    local label="$1"
    local pattern="$2"
    local budget="$3"
    local file="$4"

    if [ ! -f "$file" ]; then
        echo "SKIP: $label — file not found: $file"
        return
    fi

    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || true)

    if [ "$count" -gt "$budget" ]; then
        echo "FAIL: $label — found $count (budget $budget)"
        FAILED=1
    elif [ "$count" -eq 0 ] && [ "$budget" -eq 0 ]; then
        echo "DONE: $label — eliminated"
    elif [ "$count" -le "$budget" ]; then
        echo " OK : $label — $count / $budget"
    fi
}

echo "=== Terminal Abstraction Guard ==="
echo ""

# Ratchet 1: Hardcoded Ghostty bundle ID in orchestrator
check_ratchet \
    "Ghostty bundle ID in orchestrator" \
    'com\.mitchellh\.ghostty' \
    0 \
    "$LAUNCHER"

# Ratchet 2: Hardcoded "Ghostty" string literals in orchestrator
check_ratchet \
    "Hardcoded \"Ghostty\" in orchestrator" \
    '"Ghostty"' \
    0 \
    "$LAUNCHER"

# Ratchet 3: Hardcoded open -a Ghostty in orchestrator
check_ratchet \
    "open -a Ghostty in orchestrator" \
    'open -a Ghostty' \
    0 \
    "$LAUNCHER"

# Ratchet 4: Slow AppleScript activation
check_ratchet \
    "Slow AppleScript tell...activate" \
    'tell application.*to activate' \
    0 \
    "$LAUNCHER"

# Ratchet 5: Inline Ghostty AX logic in orchestrator
check_ratchet \
    "activateGhosttyWithAXRouting in orchestrator" \
    'activateGhosttyWithAXRouting' \
    0 \
    "$LAUNCHER"

# Ratchet 6: isGhosttyRunningInternal in orchestrator
check_ratchet \
    "isGhosttyRunningInternal in orchestrator" \
    'isGhosttyRunningInternal' \
    0 \
    "$LAUNCHER"

echo ""
if [ "$FAILED" -eq 1 ]; then
    echo "GUARD FAILED — ratchet budget exceeded"
    exit 1
else
    echo "GUARD PASSED"
fi
