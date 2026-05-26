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

prepare_ax_verifier_build() {
  echo ""
  echo "[runtime-reliability] prepare ax verifier build"
  cargo build -p capacitor-core -p hud-hook --release
}

run_ax_verifier_ci() {
  echo ""
  echo "[runtime-reliability] ax automation verifier (ci)"
  prepare_ax_verifier_build
  local deterministic_projects_source="$workspace_root/artifacts/ax-automation-verification/ci/projects.force-seed.json"
  rm -f "$deterministic_projects_source"
  CAPACITOR_PROJECTS_FILE="${CAPACITOR_PROJECTS_FILE:-$deterministic_projects_source}" \
    CAPACITOR_SKIP_SETUP_VALIDATION=1 \
    bash scripts/ci/ax-automation-verify.sh \
    --runs 1 \
    --skip-details \
    --allow-untrusted \
    --artifacts-dir artifacts/ax-automation-verification/ci
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
  *)
    echo "Usage: $0 [ci]" >&2
    exit 2
    ;;
esac
