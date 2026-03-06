#!/bin/bash
set -euo pipefail

# cd to repo root (script lives at scripts/ci/)
cd "$(dirname "$0")/../.."

# Terminal Activation Simplification Guard
# Run: ./scripts/ci/terminal-simplification-guard.sh
# Status: ./scripts/ci/terminal-simplification-guard.sh --status

STATUS_MODE=false
if [ "${1:-}" = "--status" ]; then
  STATUS_MODE=true
fi

ERRORS=0
SWIFT_SRC="apps/swift/Sources/Capacitor"
SWIFT_TESTS="apps/swift/Tests/CapacitorTests"
RUST_SRC="core/capacitor-core/src"

# --- Ratchet checks ---
check_ratchet() {
  local pattern="$1"
  local budget="$2"
  local label="$3"
  local search_path="${4:-$SWIFT_SRC}"
  local count
  count=$({ grep -rE "$pattern" "$search_path" 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "$count" -gt "$budget" ]; then
    if [ "$STATUS_MODE" = true ]; then
      echo "OVER: $label — $count/$budget (+$((count - budget)))"
    else
      echo "FAIL: $label — found $count (budget: $budget)"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "OK:   $label — $count/$budget"
  fi
}

# P1: Keystroke simulation (Cmd+T, keystroke, key code 36)
check_ratchet 'keystroke.*command down|key code 36' 2 "P1: keystroke simulation"

# P2: open -na (dock icon spawning)
check_ratchet 'open -na' 0 "P2: open -na dock icon"

# P3: Cancellation-unsafe try? await Task.sleep
check_ratchet 'try\? await.*Task\.sleep' 0 "P3: cancellation-unsafe sleep"

# P4: Pre-activation poll (recentLaunchPending)
check_ratchet 'recentLaunchPending' 0 "P4: pre-activation poll"

# P5: Multi-terminal fallback (S-010: eliminated)
check_ratchet 'iTermRunning|terminalApp.*[Ff]allback|Terminal\.app' 0 "P5: multi-terminal fallback"

# P6: Dead ActivationConfig model
check_ratchet 'ActivationConfig|ScenarioBehavior|ActivationStrategy|ShellScenario' 0 "P6: dead ActivationConfig"

# P7: Rust resolver in hot path (S-010: eliminated)
check_ratchet 'resolveActivationDecision' 0 "P7: Rust resolver in hot path"

# P8: Managed TTY state tracking
check_ratchet 'managedClientTty' 0 "P8: managed TTY state"

# P9: Orphan detection / bookmark system
check_ratchet 'orphan|bookmarkWasCleared|lastMatchedGhosttyTabIndex|tryBookmarkedGhosttyTab' 0 "P9: orphan detection"

# P10: Old Rust activate/ module
check_ratchet_lines() {
  local filepath="$1"
  local budget="$2"
  local label="$3"
  if [ ! -f "$filepath" ]; then
    echo "OK:   $label — file deleted (budget: $budget lines)"
    return
  fi
  local count
  count=$(wc -l < "$filepath" | tr -d ' ')
  if [ "$count" -gt "$budget" ]; then
    if [ "$STATUS_MODE" = true ]; then
      echo "OVER: $label — $count/$budget lines (+$((count - budget)))"
    else
      echo "FAIL: $label — $count lines (budget: $budget)"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "OK:   $label — $count/$budget lines"
  fi
}

check_ratchet_lines "$RUST_SRC/activate/mod.rs" 178 "P10: old Rust activate/ module"

# --- Denylist checks ---
check_denylist() {
  local pattern="$1"
  local label="$2"
  local search_path="${3:-$SWIFT_SRC}"
  local count
  count=$({ grep -rE "$pattern" "$search_path" 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    echo "FAIL: $label — denylist pattern found ($count matches)"
    ERRORS=$((ERRORS + 1))
  else
    echo "OK:   $label — clean"
  fi
}

# Populated as slices complete:
check_denylist 'ActivationConfig' "S-001: ActivationConfig references"
# check_denylist 'mod activate;' "S-002: old activate module" "$RUST_SRC"
# check_denylist 'keystroke.*command down' "S-003: keystroke simulation"
check_denylist 'open -na' "S-003: open -na"
check_denylist 'recentLaunchPending' "S-004: pre-activation poll"
check_denylist 'preActivationPollOverride' "S-004: pre-activation poll override"
check_denylist 'iTermRunning' "S-005: multi-terminal fallback"
check_denylist 'lastMatchedGhosttyTabIndex' "S-007: bookmark system"
check_denylist 'tryBookmarkedGhosttyTab' "S-007: bookmark method"
check_denylist 'bookmarkWasCleared' "S-007: orphan detection"
check_denylist 'activateByTtyAction' "S-010: multi-terminal dispatch"
check_denylist 'discoverTerminalOwningTTY' "S-010: TTY discovery"
check_denylist 'activateITermSession' "S-010: iTerm activation"
check_denylist 'activateTerminalAppSession' "S-010: Terminal.app activation"
check_denylist 'resolveActivationDecision[^O]' "S-010: Rust resolver method"
check_denylist 'launchNewTerminalAction' "S-010: old action dispatch"

# --- Deletion target checks ---
check_deleted() {
  local filepath="$1"
  local label="$2"
  if [ -e "$filepath" ]; then
    if [ "$STATUS_MODE" = true ]; then
      echo "PEND: $label — still exists"
    else
      echo "FAIL: $label should have been deleted"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "OK:   $label — deleted"
  fi
}

# Populated as slices complete:
check_deleted "apps/swift/Sources/Capacitor/Models/ActivationConfig.swift" "S-001: ActivationConfig.swift"
# check_deleted "core/capacitor-core/src/activate/mod.rs" "S-002: activate/mod.rs"

# --- Summary ---
echo ""
if [ "$STATUS_MODE" = true ]; then
  echo "Status complete (non-enforcing mode)"
  exit 0
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS guard violations"
  exit 1
else
  echo "All guards pass"
  exit 0
fi
