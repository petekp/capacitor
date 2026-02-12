#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"
cd "${workspace_root}"

echo "Session State Reliability Gate v1"
echo "Workspace: ${workspace_root}"

run_blocking() {
  local label="$1"
  shift
  echo ""
  echo "[P0 blocking] ${label}"
  "$@"
}

run_non_blocking() {
  local label="$1"
  shift
  echo ""
  echo "[P1/P2 triage] ${label}"
  if "$@"; then
    echo "[P1/P2 triage] PASS: ${label}"
  else
    echo "[P1/P2 triage] FAIL (triage required): ${label}" >&2
    TRIAGE_FAILURES=$((TRIAGE_FAILURES + 1))
  fi
}

TRIAGE_FAILURES=0

run_blocking \
  "SS-P0-1 hook mapping integrity" \
  cargo test -p hud-hook --test session_state_mapping_gate session_state_mapping_gate_ss_p0

run_blocking \
  "SS-P0-2 replay-diff determinism" \
  cargo test -p capacitor-core --test replay_diff replay_diff_corpus_matches_expected_and_is_deterministic

run_blocking \
  "Core reducer baseline suite" \
  cargo test -p capacitor-core reduce

run_blocking \
  "Core query baseline suite" \
  cargo test -p capacitor-core query

run_non_blocking \
  "Replay-diff hook event type compatibility" \
  cargo test -p capacitor-core --test replay_diff replay_diff_hook_event_type_deserialization_is_stable

run_non_blocking \
  "Replay-diff mutation variant compatibility" \
  cargo test -p capacitor-core --test replay_diff replay_diff_project_mutation_variant_deserializes

echo ""
echo "Session state gate complete."
if [[ "${TRIAGE_FAILURES}" -gt 0 ]]; then
  echo "Non-blocking triage failures: ${TRIAGE_FAILURES}" >&2
  echo "Release may proceed only with documented triage + risk acceptance for these failures." >&2
else
  echo "No triage failures detected in optional P1/P2 checks."
fi
