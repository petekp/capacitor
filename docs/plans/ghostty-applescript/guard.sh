#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VERIFY="$ROOT/scripts/verify/verify.sh"

ARGS=(--repo-root "$ROOT" --layers 1 --groups ghostty-applescript)
if [[ "${1:-}" == "--status" ]]; then
  ARGS+=(--report-only)
fi

"$VERIFY" "${ARGS[@]}"
