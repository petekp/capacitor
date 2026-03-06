#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"
cd "${workspace_root}"

mode="${1:-ci}"
report_path="${2:-${CAPACITOR_BENCH_REPORT_PATH:-target/hem-shadow-bench-report.json}}"

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

run_soak_bench() {
  echo ""
  echo "[runtime-reliability] hem shadow soak bench"
  bash scripts/ci/hem-shadow-bench.sh "${report_path}"
}

case "${mode}" in
  ci)
    echo "Runtime reliability suite (pre-merge CI)"
    run_guard
    run_replay_gate
    ;;
  nightly)
    echo "Runtime reliability suite (nightly)"
    run_guard
    run_replay_gate
    run_soak_bench
    ;;
  *)
    echo "Usage: $0 [ci|nightly] [report-path]" >&2
    exit 2
    ;;
esac
