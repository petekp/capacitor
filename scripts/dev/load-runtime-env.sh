#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${CAPACITOR_RUNTIME_ENV_FILE:-$PROJECT_ROOT/scripts/dev/capacitor-ingest.local}"

CAPACITOR_RUNTIME_ENV_VARS=(
  CAPACITOR_FEEDBACK_API_URL
  CAPACITOR_TELEMETRY_URL
  CAPACITOR_INGEST_KEY
  CAPACITOR_TELEMETRY_DISABLED
  CAPACITOR_TELEMETRY_INCLUDE_PATHS
)

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

for var_name in "${CAPACITOR_RUNTIME_ENV_VARS[@]}"; do
  var_value="${!var_name-}"
  if [[ -n "$var_value" ]]; then
    export "$var_name=$var_value"
    launchctl setenv "$var_name" "$var_value" 2>/dev/null || true
  else
    unset "$var_name" 2>/dev/null || true
    launchctl unsetenv "$var_name" 2>/dev/null || true
  fi
done
