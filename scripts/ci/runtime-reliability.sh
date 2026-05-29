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
    CAPACITOR_ALLOW_BACKGROUND_DEBUG_APP=1 \
    CAPACITOR_SKIP_SETUP_VALIDATION=1 \
    bash scripts/ci/ax-automation-verify.sh \
    --runs 1 \
    --skip-details \
    --allow-untrusted \
    --artifacts-dir artifacts/ax-automation-verification/ci
}

case "${mode}" in
  ci)
    # Deterministic gates only. The AX automation lane is split out into its own
    # advisory (continue-on-error) job (`ax` mode below) so a flaky AX run cannot
    # shadow these deterministic gates under `set -e`.
    # (The projection-parity gate was removed here: the Hickey teardown deleted the
    # dead projection/observation_journal scaffold and its replay_diff parity test,
    # so there is no longer a projection read-model to assert parity against.)
    echo "Runtime reliability suite (pre-merge CI, deterministic gates)"
    run_guard
    run_replay_gate
    ;;
  ax)
    # Advisory AX automation lane. Builds its own release artifacts via
    # prepare_ax_verifier_build inside run_ax_verifier_ci.
    echo "Runtime reliability suite (AX automation, advisory)"
    run_ax_verifier_ci
    ;;
  *)
    echo "Usage: $0 [ci|ax]" >&2
    exit 2
    ;;
esac
