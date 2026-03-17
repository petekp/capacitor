#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"

cd "$ROOT"

echo "== Structural guard =="
bash docs/plans/ax-automation-contract/guard.sh

echo
echo "== AX automation verification =="
bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details --allow-untrusted

echo
echo "== AX reliability follow-up =="
echo "[ ] bash scripts/ci/ax-automation-verify.sh --runs 3 --require-log-health"
echo "[ ] If AX trust is unavailable, capture the verifier output showing non-blocking skip labeling"
echo "[ ] Attach artifacts/ax-automation-verification/<timestamp>/summary.txt"
echo "[ ] Attach the first failing run directory if any run is red"
