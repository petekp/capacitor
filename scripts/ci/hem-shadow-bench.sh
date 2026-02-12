#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"

raw_report_path="${1:-${CAPACITOR_BENCH_REPORT_PATH:-target/hem-shadow-bench-report.json}}"
if [[ "${raw_report_path}" = /* ]]; then
  report_path="${raw_report_path}"
else
  report_path="${workspace_root}/${raw_report_path}"
fi

report_dir="$(dirname "${report_path}")"
mkdir -p "${report_dir}"
if [[ ! -d "${report_dir}" ]]; then
  echo "Failed to prepare report directory: ${report_dir}" >&2
  exit 1
fi

export CAPACITOR_BENCH_REPORT_PATH="${report_path}"

# Workload profile (nightly default)
export CAPACITOR_BENCH_BURST_EVENTS="${CAPACITOR_BENCH_BURST_EVENTS:-1500}"
export CAPACITOR_BENCH_BURST_SESSIONS="${CAPACITOR_BENCH_BURST_SESSIONS:-32}"
export CAPACITOR_BENCH_REPLAY_SESSIONS="${CAPACITOR_BENCH_REPLAY_SESSIONS:-300}"
export CAPACITOR_BENCH_REPLAY_STARTUP_SAMPLES="${CAPACITOR_BENCH_REPLAY_STARTUP_SAMPLES:-1}"

# Absolute tail latency limits
export CAPACITOR_BENCH_MAX_SHADOW_BURST_P95_MS="${CAPACITOR_BENCH_MAX_SHADOW_BURST_P95_MS:-50}"
export CAPACITOR_BENCH_MAX_SHADOW_BURST_P99_MS="${CAPACITOR_BENCH_MAX_SHADOW_BURST_P99_MS:-90}"

# Relative delta limits
export CAPACITOR_BENCH_MAX_BURST_P95_DELTA_PCT="${CAPACITOR_BENCH_MAX_BURST_P95_DELTA_PCT:-35}"
export CAPACITOR_BENCH_MAX_BURST_P99_DELTA_PCT="${CAPACITOR_BENCH_MAX_BURST_P99_DELTA_PCT:-45}"
export CAPACITOR_BENCH_MAX_REPLAY_STARTUP_DELTA_PCT="${CAPACITOR_BENCH_MAX_REPLAY_STARTUP_DELTA_PCT:-40}"

# Anti-flake gates: minimum absolute deltas before percentage checks apply
export CAPACITOR_BENCH_MIN_BURST_P95_DELTA_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_BURST_P95_DELTA_MS_FOR_PCT_GATE:-4}"
export CAPACITOR_BENCH_MIN_BURST_P99_DELTA_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_BURST_P99_DELTA_MS_FOR_PCT_GATE:-5}"
export CAPACITOR_BENCH_MIN_REPLAY_STARTUP_DELTA_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_REPLAY_STARTUP_DELTA_MS_FOR_PCT_GATE:-110}"

# Anti-flake gates: minimum baseline latencies before percentage checks apply
export CAPACITOR_BENCH_MIN_BURST_P95_BASELINE_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_BURST_P95_BASELINE_MS_FOR_PCT_GATE:-20}"
export CAPACITOR_BENCH_MIN_BURST_P99_BASELINE_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_BURST_P99_BASELINE_MS_FOR_PCT_GATE:-25}"
export CAPACITOR_BENCH_MIN_REPLAY_STARTUP_BASELINE_MS_FOR_PCT_GATE="${CAPACITOR_BENCH_MIN_REPLAY_STARTUP_BASELINE_MS_FOR_PCT_GATE:-25}"

# Resource/write amplification limits
export CAPACITOR_BENCH_MAX_RSS_DELTA_PCT="${CAPACITOR_BENCH_MAX_RSS_DELTA_PCT:-35}"
export CAPACITOR_BENCH_MAX_CPU_DELTA_PCT="${CAPACITOR_BENCH_MAX_CPU_DELTA_PCT:-40}"
export CAPACITOR_BENCH_MAX_DB_DELTA_PCT="${CAPACITOR_BENCH_MAX_DB_DELTA_PCT:-35}"

echo "Running core replay benchmark harness"
echo "Report path: ${CAPACITOR_BENCH_REPORT_PATH}"

if [[ "${CAPACITOR_BENCH_DRY_RUN_ONLY:-0}" = "1" ]]; then
  echo "Dry run enabled; skipping cargo test."
  exit 0
fi

cargo test -p capacitor-core --test replay_diff -- --nocapture
