#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=""
FACTS=""
SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --facts)
      FACTS="$2"
      shift 2
      ;;
    --spec)
      SPEC="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$REPO_ROOT" || -z "$FACTS" || -z "$SPEC" ]]; then
  echo "Usage: $0 --repo-root <path> --facts <path> --spec <spec.tla>" >&2
  exit 2
fi

if ! command -v apalache-mc >/dev/null 2>&1; then
  echo "apalache-mc is not installed. Run scripts/verify/verify.sh --bootstrap first." >&2
  exit 1
fi

SPEC_PATH="$(cd "$REPO_ROOT" && python3 - <<'PY' "$SPEC"
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).resolve())
PY
)"
SPEC_DIR="$(dirname "$SPEC_PATH")"
SPEC_NAME="$(basename "$SPEC_PATH" .tla)"
CFG_PATH="${SPEC_DIR}/${SPEC_NAME}.cfg"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

GENERATED_CFG="$TMP_DIR/${SPEC_NAME}.cfg"
cp "$CFG_PATH" "$GENERATED_CFG"

case "$SPEC_NAME" in
  HookServerLifecycle)
    MAX_FAILURES="$(python3 - <<'PY' "$FACTS"
import json
import pathlib
import sys
facts = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(facts.get("constants", {}).get("hook_server_max_consecutive_failures", 3))
PY
)"
    printf '\nCONSTANTS MaxConsecutiveFailures = %s\n' "$MAX_FAILURES" >> "$GENERATED_CFG"
    ;;
  SessionProjectionHysteresis)
    EMPTY_THRESHOLD="$(python3 - <<'PY' "$FACTS"
import json
import pathlib
import sys
facts = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(facts.get("constants", {}).get("session_empty_snapshot_commit_threshold", 2))
PY
)"
    IDLE_THRESHOLD="$(python3 - <<'PY' "$FACTS"
import json
import pathlib
import sys
facts = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(facts.get("constants", {}).get("session_idle_commit_threshold", 2))
PY
)"
    printf '\nCONSTANTS EmptyThreshold = %s\nCONSTANTS IdleThreshold = %s\n' "$EMPTY_THRESHOLD" "$IDLE_THRESHOLD" >> "$GENERATED_CFG"
    ;;
esac

apalache-mc check --config="$GENERATED_CFG" --out-dir="$TMP_DIR/out" "$SPEC_PATH" >/tmp/apalache.log 2>&1 || {
  cat /tmp/apalache.log
  exit 1
}
