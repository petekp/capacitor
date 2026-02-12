#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CAPACITOR_ENFORCE_ALPHA_ONLY=1
exec "$SCRIPT_DIR/restart-app.sh" "$@"
