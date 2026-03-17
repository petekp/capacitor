#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

failures=0

check_contains() {
  local label="$1"
  local path="$2"
  local pattern="$3"

  if grep -q -- "$pattern" "$path"; then
    echo "OK   ${label}"
  else
    echo "FAIL ${label}: missing pattern '${pattern}' in ${path}" >&2
    failures=$((failures + 1))
  fi
}

check_contains "verifier CLI exists" "scripts/ci/ax-automation-verify.sh" 'Usage: bash scripts/ci/ax-automation-verify.sh'
check_contains "verifier exposes log health" "scripts/ci/ax-automation-verify.sh" '--require-log-health'
check_contains "runtime reliability ci wires verifier" "scripts/ci/runtime-reliability.sh" 'ax-automation-verify.sh'
check_contains "runtime guard tracks verifier" "scripts/ci/runtime-reliability-guard.sh" 'AX verifier script keeps allow-untrusted mode'
check_contains "WindowAX diagnostics are source-owned" "apps/swift/Sources/Capacitor/Utilities/WindowAXDiagnostics.swift" '\[WindowAX\]'
check_contains "app lifecycle logs WindowAX" "apps/swift/Sources/Capacitor/App.swift" 'WindowAXDiagnostics.logApplicationDidBecomeActive'

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
