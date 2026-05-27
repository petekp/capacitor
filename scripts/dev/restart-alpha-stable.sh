#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CAPACITOR_ENFORCE_ALPHA_ONLY=1
# New Task-first product loop behavior: the Swift feature flag is still named
# ideaCapture for legacy reasons, but this is the Task capture front door.
FORCED_FEATURES="projectDetails,ideaCapture,llmFeatures"
if [[ -n "${CAPACITOR_FEATURES_ENABLED:-}" ]]; then
    export CAPACITOR_FEATURES_ENABLED="${CAPACITOR_FEATURES_ENABLED},${FORCED_FEATURES}"
else
    export CAPACITOR_FEATURES_ENABLED="$FORCED_FEATURES"
fi
# Strip forced-on features from the disabled list so enabled always wins.
if [[ -n "${CAPACITOR_FEATURES_DISABLED:-}" ]]; then
    CAPACITOR_FEATURES_DISABLED=$(printf '%s' "$CAPACITOR_FEATURES_DISABLED" \
        | tr ',' '\n' \
        | { grep -vE '^(projectDetails|ideaCapture|llmFeatures)$' || true; } \
        | paste -sd, -)
    export CAPACITOR_FEATURES_DISABLED
fi
exec "$SCRIPT_DIR/restart-app.sh" --channel alpha --profile stable "$@"
