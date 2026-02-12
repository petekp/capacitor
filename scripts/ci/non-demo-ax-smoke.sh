#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"

projects_file="${CAPACITOR_PROJECTS_FILE:-$HOME/.capacitor/projects.json}"
skip_details_phase=0

usage() {
    cat <<'USAGE'
Usage: bash scripts/ci/non-demo-ax-smoke.sh [options]

Runs non-demo AX smoke coverage against the debug build:
1) Stable profile: card interactions + layout toggles.
2) Frontier profile: details navigation flow.

Options:
  --projects-file <path>  Override projects json (default: ~/.capacitor/projects.json)
  --skip-details          Skip the frontier/details phase.
  --help                  Show this help text.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --projects-file)
        [[ $# -ge 2 ]] || { echo "--projects-file requires a value" >&2; exit 1; }
        projects_file="$2"
        shift 2
        ;;
    --skip-details)
        skip_details_phase=1
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

require_cmd jq
require_cmd swift

if [[ ! -f "$projects_file" ]]; then
    echo "Projects file not found: $projects_file" >&2
    exit 1
fi

slug_for_path() {
    local path="$1"
    local base slug
    base="$(basename "$path")"
    slug="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^[:alnum:]]+/-/g; s/^-+//; s/-+$//')"
    if [[ -z "$slug" ]]; then
        slug="project"
    fi
    printf '%s\n' "$slug"
}

first_path=""
second_path=""
assistant_path=""
capacitor_path=""

while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    if [[ -z "$first_path" ]]; then
        first_path="$path"
    elif [[ -z "$second_path" && "$path" != "$first_path" ]]; then
        second_path="$path"
    fi

    case "$(basename "$path")" in
    assistant-ui)
        assistant_path="$path"
        ;;
    capacitor)
        capacitor_path="$path"
        ;;
    esac
done < <(jq -r '.pinned_projects[]? // empty' "$projects_file")

primary_path="${assistant_path:-$first_path}"
secondary_path="${capacitor_path:-$second_path}"

if [[ -z "$secondary_path" || "$secondary_path" == "$primary_path" ]]; then
    secondary_path="$second_path"
fi

if [[ -z "$primary_path" || -z "$secondary_path" || "$primary_path" == "$secondary_path" ]]; then
    echo "Need at least two distinct pinned projects in: $projects_file" >&2
    exit 1
fi

primary_slug="$(slug_for_path "$primary_path")"
secondary_slug="$(slug_for_path "$secondary_path")"

card_primary_id="ax.project-card.${primary_slug}"
card_secondary_id="ax.project-card.${secondary_slug}"
details_primary_id="ax.project-details.${primary_slug}"
details_secondary_id="ax.project-details.${secondary_slug}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_dir="${workspace_root}/artifacts/manual-testing"
mkdir -p "$artifact_dir"

cards_scenario="${artifact_dir}/non-demo-ax-smoke-cards-${timestamp}.json"
details_scenario="${artifact_dir}/non-demo-ax-smoke-details-${timestamp}.json"
cards_log="${artifact_dir}/non-demo-ax-smoke-cards-${timestamp}.log"
details_log="${artifact_dir}/non-demo-ax-smoke-details-${timestamp}.log"

cat >"$cards_scenario" <<JSON
{
  "steps": [
    { "type": "wait", "duration": 1.2 },
    { "type": "key", "chord": "cmd+1" },
    { "type": "wait", "duration": 0.8 },
    { "type": "click", "identifier": "${card_primary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "click", "identifier": "${card_secondary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "key", "chord": "cmd+2" },
    { "type": "wait", "duration": 1.0 },
    { "type": "click", "identifier": "${card_primary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "click", "identifier": "${card_secondary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "key", "chord": "cmd+1" },
    { "type": "wait", "duration": 1.5 }
  ]
}
JSON

cat >"$details_scenario" <<JSON
{
  "steps": [
    { "type": "wait", "duration": 1.2 },
    { "type": "key", "chord": "cmd+1" },
    { "type": "wait", "duration": 1.0 },
    { "type": "click", "identifier": "${details_primary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "click", "identifier": "ax.nav.back-projects", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.0 },
    { "type": "click", "identifier": "${details_secondary_id}", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.2 },
    { "type": "click", "identifier": "ax.nav.back-projects", "timeout": 12.0, "visible": true },
    { "type": "wait", "duration": 1.5 }
  ]
}
JSON

echo "Non-demo AX smoke"
echo "Workspace: $workspace_root"
echo "Projects file: $projects_file"
echo "Target 1: $primary_path ($card_primary_id)"
echo "Target 2: $secondary_path ($card_secondary_id)"
echo "Cards scenario: $cards_scenario"
echo "Details scenario: $details_scenario"

echo ""
echo "[phase 1] Stable profile card smoke"
bash "${workspace_root}/scripts/dev/restart-app.sh" --alpha --swift-only
swift "${workspace_root}/scripts/ax/ax_runner.swift" \
    --bundle-id com.capacitor.app.debug \
    --scenario "$cards_scenario" \
    --click-mode visible | tee "$cards_log"

if [[ "$skip_details_phase" -eq 1 ]]; then
    echo ""
    echo "Skipped details phase (--skip-details)."
    echo "Cards log: $cards_log"
    exit 0
fi

echo ""
echo "[phase 2] Frontier profile details smoke"
bash "${workspace_root}/scripts/dev/restart-app.sh" --alpha --frontier --swift-only
swift "${workspace_root}/scripts/ax/ax_runner.swift" \
    --bundle-id com.capacitor.app.debug \
    --scenario "$details_scenario" \
    --click-mode visible | tee "$details_log"

echo ""
echo "Non-demo AX smoke complete."
echo "Cards log:   $cards_log"
echo "Details log: $details_log"
