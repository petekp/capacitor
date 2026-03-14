#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"
STATUS_MODE=false

if [[ "${1:-}" == "--status" ]]; then
  STATUS_MODE=true
fi

ERRORS=0

count_matches() {
  local pattern="$1"
  shift
  (rg -n "$pattern" "$@" || true) | wc -l | tr -d ' '
}

check_ratchet() {
  local label="$1"
  local pattern="$2"
  local budget="$3"
  shift 3
  local count
  count=$(count_matches "$pattern" "$@")

  if [[ "$count" -gt "$budget" ]]; then
    if [[ "$STATUS_MODE" == true ]]; then
      echo "OVER  $label count=$count budget=$budget"
    else
      echo "FAIL  $label count=$count budget=$budget pattern=$pattern"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "OK    $label count=$count budget=$budget"
  fi
}

ACTIVE_DOCS=(
  "$ROOT/.claude/docs/terminal-activation-ux-spec.md"
  "$ROOT/docs/ARCHITECTURE.md"
)

SOURCE_AND_TESTS=(
  "$ROOT/apps/swift/Sources"
  "$ROOT/apps/swift/Tests"
)

echo "Terminal host adapters migration guard"

check_ratchet \
  "shared_host_driver_class" \
  'final class ScriptedTerminalDriver' \
  0 \
  "${SOURCE_AND_TESTS[@]}"

check_ratchet \
  "shared_host_driver_registry_refs" \
  'private let iTerm: ScriptedTerminalDriver|private let terminal: ScriptedTerminalDriver|iTerm = ScriptedTerminalDriver|terminal = ScriptedTerminalDriver' \
  0 \
  "$ROOT/apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift"

check_ratchet \
  "shared_host_driver_log_labels" \
  '\[ScriptedTerminalDriver\]' \
  0 \
  "${SOURCE_AND_TESTS[@]}" \
  "${ACTIVE_DOCS[@]}"

check_ratchet \
  "combined_host_driver_case" \
  'case \.iTerm, \.terminal' \
  0 \
  "$ROOT/apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift"

check_ratchet \
  "ghostty_biased_fallback_copy" \
  "Couldn['’]t activate Ghostty\\." \
  0 \
  "${SOURCE_AND_TESTS[@]}" \
  "${ACTIVE_DOCS[@]}"

if [[ "$ERRORS" -gt 0 ]]; then
  echo
  echo "FAILED: $ERRORS guard violations"
  exit 1
fi

echo
echo "All host-adapter guard checks are within budget"
