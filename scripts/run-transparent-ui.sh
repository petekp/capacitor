#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${ROOT_DIR}/scripts/transparent-ui-server.mjs"
UI_FILE="${ROOT_DIR}/docs/transparent-ui/capacitor-interfaces-explorer.html"

PORT="${PORT:-9133}"

node "${SERVER}" &
SERVER_PID=$!

cleanup() {
  if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}"
  fi
}
trap cleanup EXIT

open "${UI_FILE}"

echo "Transparent UI server running on http://localhost:${PORT}"
echo "Press Ctrl+C to stop."

wait "${SERVER_PID}"
