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

run_projection_parity_gate() {
  echo ""
  echo "[runtime-reliability] projection parity gate"

  # Zero-test guard: `cargo test <filter>` exits 0 even when the filter matches
  # NO tests (it just prints "running 0 tests" / "0 passed; 0 failed"). If the
  # named test is ever renamed or deleted (e.g. when PR #57 merges), this gate
  # would silently pass as a no-op green and stop protecting projection parity.
  # We capture the run output and assert exactly one test executed and passed,
  # failing loudly otherwise so the drift is caught at review time.
  local test_name="replay_diff_projection_read_model_matches_runtime_snapshot"
  local output
  if ! output="$(cargo test -p capacitor-core --test replay_diff "$test_name" 2>&1)"; then
    echo "$output"
    echo "[runtime-reliability] projection parity gate FAILED: '$test_name' did not pass" >&2
    return 1
  fi
  echo "$output"

  # Assert the named test actually ran (guards against a rename/deletion turning
  # this into a silent no-op). cargo prints e.g. "1 passed; 0 failed" on success
  # and "0 passed; 0 failed" when the filter matched nothing.
  if ! grep -Eq '[[:space:]]1 passed;[[:space:]]*0 failed' <<<"$output"; then
    echo "[runtime-reliability] projection parity gate FAILED: expected exactly 1 passing test for filter '$test_name'." >&2
    echo "[runtime-reliability] The filter likely matched zero tests (rename/deletion). Update this gate to the new test name." >&2
    return 1
  fi
}

case "${mode}" in
  ci)
    # Deterministic gates only. The AX automation lane is split out into its own
    # advisory (continue-on-error) job (`ax` mode below) so a flaky AX run cannot
    # shadow the deterministic projection-parity gate under `set -e`.
    echo "Runtime reliability suite (pre-merge CI, deterministic gates)"
    run_guard
    run_replay_gate
    run_projection_parity_gate
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
