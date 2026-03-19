#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLAN_DIR="$ROOT/docs/historical/orchestrator-next-slices"
VERIFY="$ROOT/scripts/verify/verify.sh"
REPORT_ONLY=false

if [[ "${1:-}" == "--status" ]]; then
  REPORT_ONLY=true
fi

required_files=(
  "$PLAN_DIR/AGENT_EXECUTION_PLAYBOOK.md"
  "$PLAN_DIR/CHARTER.md"
  "$PLAN_DIR/DECISIONS.md"
  "$PLAN_DIR/SLICES.yaml"
  "$PLAN_DIR/MAP.csv"
  "$PLAN_DIR/RATCHETS.yaml"
  "$PLAN_DIR/TRANSLATION_GUIDE.md"
  "$PLAN_DIR/HANDOFF.md"
  "$PLAN_DIR/SHIP_CHECKLIST.md"
  "$PLAN_DIR/guard.sh"
  "$ROOT/docs/historical/UBIQUITOUS_LANGUAGE.md"
)

echo "== Control-plane artifacts =="
for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing required artifact: $file" >&2
    exit 1
  fi
  echo "present: ${file#$ROOT/}"
done

echo
echo "== Baseline verifier groups =="
verifier_args=(--repo-root "$ROOT" --layers 1 --groups runtime-boundary,delegation-loop-validation)
if [[ "$REPORT_ONLY" == true ]]; then
  verifier_args+=(--report-only)
fi
"$VERIFY" "${verifier_args[@]}"

echo
echo "== Ratchets =="

count_matches() {
  local pattern="$1"
  shift
  local count
  count=$(rg -n "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ')
  printf '%s' "${count:-0}"
}

check_budget() {
  local label="$1"
  local actual="$2"
  local budget="$3"

  echo "$label: $actual / $budget"
  if (( actual > budget )); then
    echo "Budget exceeded for $label" >&2
    exit 1
  fi
}

workstreams_manager_count=$(count_matches '\bWorkstreamsManager\b' "$ROOT/apps/swift/Sources" "$ROOT/apps/swift/Tests")
workstreams_panel_count=$(count_matches '\bWorkstreamsPanel\b' "$ROOT/apps/swift/Sources" "$ROOT/apps/swift/Tests")
workstreams_flag_count=$(count_matches 'featureFlags\.workstreams|case workstreams|\bworkstreams\b' "$ROOT/apps/swift/Sources" "$ROOT/apps/swift/Tests")
migration_marker_count=$(count_matches 'TODO\(migration\)|FIXME\(migration\)' "$PLAN_DIR")

check_budget "WorkstreamsManager references" "$workstreams_manager_count" 15
check_budget "WorkstreamsPanel references" "$workstreams_panel_count" 2
check_budget "Legacy workstreams flag references" "$workstreams_flag_count" 15
check_budget "Migration placeholder markers" "$migration_marker_count" 0

echo
echo "Guard status: ok"
