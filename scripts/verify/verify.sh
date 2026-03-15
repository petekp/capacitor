#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPO_ROOT="$DEFAULT_REPO_ROOT"
LAYERS="1,2,3"
JSON_OUTPUT=false
CHANGED_ONLY=false
RULE_GROUPS=""
EVOLVE=false
GRADE_ONLY=false
BOOTSTRAP=false
STATUS_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --layers)
      LAYERS="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --changed-only)
      CHANGED_ONLY=true
      shift
      ;;
    --groups)
      RULE_GROUPS="$2"
      shift 2
      ;;
    --evolve)
      EVOLVE=true
      shift
      ;;
    --grade)
      GRADE_ONLY=true
      shift
      ;;
    --bootstrap)
      BOOTSTRAP=true
      shift
      ;;
    --status)
      STATUS_MODE=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

VENV_DIR="${VENV_DIR:-$REPO_ROOT/.verifier/.venv}"
PYTHON_BIN="$VENV_DIR/bin/python"
FACTS_PATH="$REPO_ROOT/.verifier/facts/current.json"
STRUCTURAL_OUT="$REPO_ROOT/.verifier/reports/layer1.json"
BEHAVIORAL_OUT="$REPO_ROOT/.verifier/reports/layer2.json"
ELEGANCE_OUT="$REPO_ROOT/.verifier/reports/layer3.json"
FINAL_OUT="$REPO_ROOT/.verifier/reports/last-run.json"
SELECTED_PATHS_FILE="$REPO_ROOT/.verifier/reports/selected-paths.txt"

bootstrap_scaffold() {
  mkdir -p "$REPO_ROOT/.verifier/specs" "$REPO_ROOT/.verifier/facts" "$REPO_ROOT/.verifier/reports"

  if [[ ! -f "$REPO_ROOT/.verifier/structural.yaml" ]]; then
    cat > "$REPO_ROOT/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership: []
boundaries: []
patterns: []
migration: []
YAML
  fi

  if [[ ! -f "$REPO_ROOT/.verifier/elegance.yaml" ]]; then
    cat > "$REPO_ROOT/.verifier/elegance.yaml" <<'YAML'
thresholds:
  cyclomatic_complexity: 10
  nesting_depth: 4
  function_length: 60
  file_length: 600
  parameter_count: 6
weights:
  cyclomatic_complexity: 5
  nesting_depth: 5
  function_length: 5
  file_length: 5
  parameter_count: 5
  craft: 5
minimum_grade: B
exclude:
  - "target/*"
  - "apps/swift/.build/*"
  - "apps/swift/Sources/Capacitor/Bridge/*"
YAML
  fi

  for spec in HookServerLifecycle TerminalActivationCoordinator SessionProjectionHysteresis; do
    if [[ ! -f "$REPO_ROOT/.verifier/specs/${spec}.tla" ]]; then
      touch "$REPO_ROOT/.verifier/specs/${spec}.tla"
    fi
    if [[ ! -f "$REPO_ROOT/.verifier/specs/${spec}.cfg" ]]; then
      cat > "$REPO_ROOT/.verifier/specs/${spec}.cfg" <<'CFG'
INIT Init
NEXT Next
INVARIANT TypeInvariant
CFG
    fi
  done
}

if [[ "$BOOTSTRAP" == true ]]; then
  bootstrap_scaffold
  "$SCRIPT_DIR/install-deps.sh"
  if [[ "$JSON_OUTPUT" == true ]]; then
    printf '{"bootstrapped":true,"repo_root":"%s"}\n' "$REPO_ROOT"
  else
    echo "Formal verifier bootstrapped at $REPO_ROOT/.verifier"
  fi
  exit 0
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Verifier dependencies are missing. Run scripts/verify/verify.sh --bootstrap first." >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/.verifier/reports" "$REPO_ROOT/.verifier/facts"

if [[ "$CHANGED_ONLY" == true ]]; then
  git -C "$REPO_ROOT" diff --name-only HEAD > "$SELECTED_PATHS_FILE" || true
  git -C "$REPO_ROOT" diff --cached --name-only >> "$SELECTED_PATHS_FILE" || true
  git -C "$REPO_ROOT" ls-files --others --exclude-standard >> "$SELECTED_PATHS_FILE" || true
  sort -u "$SELECTED_PATHS_FILE" -o "$SELECTED_PATHS_FILE" || true
else
  : > "$SELECTED_PATHS_FILE"
fi

if [[ "$GRADE_ONLY" == true ]]; then
  LAYERS="3"
fi

"$PYTHON_BIN" "$SCRIPT_DIR/extract-facts.py" \
  --repo-root "$REPO_ROOT" \
  --out "$FACTS_PATH" \
  $([[ "$CHANGED_ONLY" == true ]] && printf -- '--changed-only')

run_layer1() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/check-structural.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --config "$REPO_ROOT/.verifier/structural.yaml"
    --out "$STRUCTURAL_OUT"
  )
  if [[ "$CHANGED_ONLY" == true ]]; then
    args+=(--paths-file "$SELECTED_PATHS_FILE")
  fi
  if [[ -n "$RULE_GROUPS" ]]; then
    args+=(--groups "$RULE_GROUPS")
  fi
  if [[ "$STATUS_MODE" == true ]]; then
    args+=(--status)
  fi
  if [[ "$EVOLVE" == true ]]; then
    args+=(--evolve)
  fi
  "${args[@]}"
}

run_layer2() {
  "$PYTHON_BIN" "$SCRIPT_DIR/verify-behavioral.py" \
    --repo-root "$REPO_ROOT" \
    --facts "$FACTS_PATH" \
    --specs-dir "$REPO_ROOT/.verifier/specs" \
    --out "$BEHAVIORAL_OUT"
}

run_layer3() {
  "$PYTHON_BIN" "$SCRIPT_DIR/audit-elegance.py" \
    --repo-root "$REPO_ROOT" \
    --facts "$FACTS_PATH" \
    --config "$REPO_ROOT/.verifier/elegance.yaml" \
    --out "$ELEGANCE_OUT"
}

STATUS=0
IFS=',' read -r -a LAYER_LIST <<< "$LAYERS"
for layer in "${LAYER_LIST[@]}"; do
  case "$layer" in
    1) run_layer1 || STATUS=$? ;;
    2) run_layer2 || STATUS=$? ;;
    3) run_layer3 || STATUS=$? ;;
    *)
      echo "Unsupported layer: $layer" >&2
      exit 2
      ;;
  esac
done

"$PYTHON_BIN" - <<'PY' "$STRUCTURAL_OUT" "$BEHAVIORAL_OUT" "$ELEGANCE_OUT" "$FINAL_OUT" "$LAYERS" "$REPO_ROOT"
import json
import pathlib
import sys
from datetime import datetime, timezone

layer_paths = {
    "1": pathlib.Path(sys.argv[1]),
    "2": pathlib.Path(sys.argv[2]),
    "3": pathlib.Path(sys.argv[3]),
}
final_out = pathlib.Path(sys.argv[4])
layers = [layer.strip() for layer in sys.argv[5].split(",") if layer.strip()]
repo_root = sys.argv[6]
results = {}
passed = True
for layer in layers:
    path = layer_paths[layer]
    if path.exists():
        payload = json.loads(path.read_text())
    else:
        payload = {"passed": True, "violations": []}
    results[layer] = payload
    passed = passed and payload.get("passed", False)

report = {
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "repo_root": repo_root,
    "layers": layers,
    "passed": passed,
    "layer_results": results,
    "violation_count": sum(len(results[layer].get("violations", [])) for layer in results),
}
final_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

if [[ "$JSON_OUTPUT" == true ]]; then
  cat "$FINAL_OUT"
fi

exit "$STATUS"
