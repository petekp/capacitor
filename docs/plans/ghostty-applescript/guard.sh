#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"

TARGETS=(
  "$ROOT/apps/swift/Sources"
  "$ROOT/apps/swift/Tests"
  "$ROOT/README.md"
  "$ROOT/.claude/docs/terminal-activation-ux-spec.md"
  "$ROOT/.claude/docs/debugging-guide.md"
  "$ROOT/.claude/docs/gotchas.md"
  "$ROOT/docs/PRE_RELEASE_CHECKLIST.md"
  "$ROOT/docs/ARCHITECTURE.md"
)

status=0

check_zero() {
  local label="$1"
  local pattern="$2"
  local count
  count=$( (rg -n "$pattern" "${TARGETS[@]}" || true) | wc -l | tr -d ' ' )
  if [[ "$count" != "0" ]]; then
    echo "FAIL  $label count=$count pattern=$pattern"
    status=1
  else
    echo "PASS  $label count=0"
  fi
}

echo "Ghostty AppleScript migration guard"

check_zero "ghostty_ax_reader" 'GhosttyAXReader'
check_zero "ghostty_ax_helpers" 'bestGhosttyTabMatch|ghosttyWindowTitleMatchesSession|resolveGhosttyAXRouting|activateGhosttyWithAXRouting'
check_zero "ghostty_ax_tokens" 'AXUIElement|kAX|AXPress|AXRaise|Accessibility tab targeting'
check_zero "ghostty_legacy_open_launch" 'open -a Ghostty\.app'
check_zero "ghostty_legacy_keystroke_launch" 'tell process "Ghostty"'

exit "$status"
