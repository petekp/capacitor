#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"
cd "${workspace_root}"

mode="${1:-ci}"

run_guard() {
  echo ""
  echo "[runtime-reliability] reliability guard"
  bash scripts/ci/runtime-reliability-guard.sh --status
}

run_replay_gate() {
  echo ""
  echo "[runtime-reliability] replay gate"
  bash scripts/ci/session-state-gate.sh
}

run_ax_verifier_ci() {
  echo ""
  echo "[runtime-reliability] ax automation verifier (ci)"
  bash scripts/ci/ax-automation-verify.sh \
    --runs 1 \
    --skip-details \
    --allow-untrusted \
    --artifacts-dir artifacts/ax-automation-verification/ci
}

run_ax_verifier_nightly() {
  echo ""
  echo "[runtime-reliability] ax automation verifier (nightly)"
  bash scripts/ci/ax-automation-verify.sh \
    --runs 3 \
    --require-log-health \
    --allow-untrusted \
    --artifacts-dir artifacts/ax-automation-verification/nightly
}

run_projection_parity_gate() {
  echo ""
  echo "[runtime-reliability] projection parity gate"
  cargo test -p capacitor-core --test replay_diff replay_diff_projection_read_model_matches_runtime_snapshot
}

case "${mode}" in
  ci)
    echo "Runtime reliability suite (pre-merge CI)"
    run_guard
    run_replay_gate
    run_ax_verifier_ci
    run_projection_parity_gate
    ;;
  nightly)
    echo "Runtime reliability suite (nightly schedule)"
    run_guard
    run_replay_gate
    run_ax_verifier_nightly
    run_projection_parity_gate
    ;;
  *)
    echo "Usage: $0 [ci|nightly]" >&2
    exit 2
    ;;
esac
