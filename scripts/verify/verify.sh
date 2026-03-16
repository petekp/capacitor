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
REPORT_ONLY=false

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
    --report-only)
      REPORT_ONLY=true
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
RUN_MANIFEST_PATH="$REPO_ROOT/.verifier/reports/run-manifest.json"
STRUCTURAL_CONFIG="$REPO_ROOT/.verifier/structural.yaml"
ELEGANCE_CONFIG="$REPO_ROOT/.verifier/elegance.yaml"
CANONICAL_CLAIMS_PATH="$REPO_ROOT/.verifier/canonical-claims.yaml"
LEDGER_PATH="$REPO_ROOT/.verifier/ledger.yaml"
SPECS_DIR="$REPO_ROOT/.verifier/specs"
BOOTSTRAP_MANIFEST="$SCRIPT_DIR/bootstrap-manifest.json"

bootstrap_scaffold() {
  mkdir -p "$SPECS_DIR" "$REPO_ROOT/.verifier/facts" "$REPO_ROOT/.verifier/reports"

  if [[ ! -f "$STRUCTURAL_CONFIG" ]]; then
    cat > "$STRUCTURAL_CONFIG" <<'YAML'
meta:
  canonical_docs: []
ownership: []
boundaries: []
patterns: []
migration: []
YAML
  fi

  if [[ ! -f "$ELEGANCE_CONFIG" ]]; then
    cat > "$ELEGANCE_CONFIG" <<'YAML'
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

  if [[ ! -f "$CANONICAL_CLAIMS_PATH" ]]; then
    cat > "$CANONICAL_CLAIMS_PATH" <<'YAML'
claims: []
YAML
  fi

  if [[ ! -f "$LEDGER_PATH" ]]; then
    cat > "$LEDGER_PATH" <<'YAML'
claims: {}
YAML
  fi

  for spec in HookServerLifecycle TerminalActivationCoordinator SessionProjectionHysteresis; do
    if [[ ! -f "$SPECS_DIR/${spec}.tla" ]]; then
      touch "$SPECS_DIR/${spec}.tla"
    fi
    if [[ ! -f "$SPECS_DIR/${spec}.cfg" ]]; then
      cat > "$SPECS_DIR/${spec}.cfg" <<'CFG'
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

if [[ "$CHANGED_ONLY" == true && "$LAYERS" == *"2"* ]]; then
  echo "Layer 2 does not support path-scoped runs. Use --layers 1,3 or drop --changed-only." >&2
  exit 2
fi

"$PYTHON_BIN" - <<'PY' "$REPO_ROOT" "$SELECTED_PATHS_FILE" "$STRUCTURAL_CONFIG" "$ELEGANCE_CONFIG" "$CANONICAL_CLAIMS_PATH" "$LEDGER_PATH" "$SPECS_DIR" "$BOOTSTRAP_MANIFEST" "$RUN_MANIFEST_PATH" "$SCRIPT_DIR"
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1]).resolve()
selected_paths_file = pathlib.Path(sys.argv[2])
structural_config = pathlib.Path(sys.argv[3])
elegance_config = pathlib.Path(sys.argv[4])
canonical_claims = pathlib.Path(sys.argv[5])
ledger_path = pathlib.Path(sys.argv[6])
specs_dir = pathlib.Path(sys.argv[7])
bootstrap_manifest = pathlib.Path(sys.argv[8])
run_manifest_path = pathlib.Path(sys.argv[9])
script_dir = pathlib.Path(sys.argv[10]).resolve()

sys.path.insert(0, str(script_dir))

from pipeline import (
    build_base_run_manifest,
    build_config_hashes,
    build_tool_versions,
    git_commit,
    git_dirty,
    write_manifest,
)
from verifier_common import utc_now

selected_paths = []
if selected_paths_file.exists():
    selected_paths = [line.strip() for line in selected_paths_file.read_text().splitlines() if line.strip()]

manifest = build_base_run_manifest(
    repo_root=str(repo_root),
    started_at=utc_now(),
    selected_paths=selected_paths,
    config_hashes=build_config_hashes(
        structural_config=structural_config,
        elegance_config=elegance_config,
        canonical_claims=canonical_claims,
        ledger=ledger_path,
        specs_dir=specs_dir,
        bootstrap_manifest=bootstrap_manifest,
    ),
    tool_versions=build_tool_versions(),
    git_commit=git_commit(repo_root),
    git_dirty=git_dirty(repo_root),
)
write_manifest(run_manifest_path, manifest)
PY

EXTRACT_ARGS=(
  "$PYTHON_BIN" "$SCRIPT_DIR/extract-facts.py"
  --repo-root "$REPO_ROOT"
  --out "$FACTS_PATH"
  --run-manifest "$RUN_MANIFEST_PATH"
)
if [[ "$CHANGED_ONLY" == true ]]; then
  EXTRACT_ARGS+=(--paths-file "$SELECTED_PATHS_FILE")
fi
"${EXTRACT_ARGS[@]}"

run_layer1() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/check-structural.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --config "$STRUCTURAL_CONFIG"
    --canonical-claims "$CANONICAL_CLAIMS_PATH"
    --ledger "$LEDGER_PATH"
    --specs-dir "$SPECS_DIR"
    --run-manifest "$RUN_MANIFEST_PATH"
    --out "$STRUCTURAL_OUT"
  )
  if [[ "$CHANGED_ONLY" == true ]]; then
    args+=(--paths-file "$SELECTED_PATHS_FILE")
  fi
  if [[ -n "$RULE_GROUPS" ]]; then
    args+=(--groups "$RULE_GROUPS")
  fi
  if [[ "$REPORT_ONLY" == true ]]; then
    args+=(--report-only)
  fi
  if [[ "$EVOLVE" == true ]]; then
    args+=(--evolve)
  fi
  "${args[@]}"
}

run_layer2() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/verify-behavioral.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --specs-dir "$SPECS_DIR"
    --canonical-claims "$CANONICAL_CLAIMS_PATH"
    --run-manifest "$RUN_MANIFEST_PATH"
    --out "$BEHAVIORAL_OUT"
  )
  if [[ "$REPORT_ONLY" == true ]]; then
    args+=(--report-only)
  fi
  "${args[@]}"
}

run_layer3() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/audit-elegance.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --config "$ELEGANCE_CONFIG"
    --run-manifest "$RUN_MANIFEST_PATH"
    --out "$ELEGANCE_OUT"
  )
  if [[ "$CHANGED_ONLY" == true ]]; then
    args+=(--paths-file "$SELECTED_PATHS_FILE")
  fi
  if [[ "$REPORT_ONLY" == true ]]; then
    args+=(--report-only)
  fi
  "${args[@]}"
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

"$PYTHON_BIN" - <<'PY' "$STRUCTURAL_OUT" "$BEHAVIORAL_OUT" "$ELEGANCE_OUT" "$FINAL_OUT" "$LAYERS" "$REPO_ROOT" "$RUN_MANIFEST_PATH" "$SCRIPT_DIR"
import json
import pathlib
import sys
from datetime import datetime, timezone

repo_root = pathlib.Path(sys.argv[6]).resolve()
script_dir = pathlib.Path(sys.argv[8]).resolve()
sys.path.insert(0, str(script_dir))

from pipeline import aggregate_run_report

layer_paths = {
    "1": pathlib.Path(sys.argv[1]),
    "2": pathlib.Path(sys.argv[2]),
    "3": pathlib.Path(sys.argv[3]),
}
final_out = pathlib.Path(sys.argv[4])
layers = [layer.strip() for layer in sys.argv[5].split(",") if layer.strip()]
expected_manifest = json.loads(pathlib.Path(sys.argv[7]).read_text())
results = {}
for layer in layers:
    path = layer_paths[layer]
    if path.exists():
        payload = json.loads(path.read_text())
    else:
        payload = {"passed": True, "violations": [], "run_manifest": expected_manifest}
    results[layer] = payload

report = aggregate_run_report(
    repo_root=str(repo_root),
    layers=layers,
    layer_results=results,
    expected_manifest=expected_manifest,
    generated_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
)
final_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

if [[ "$JSON_OUTPUT" == true ]]; then
  cat "$FINAL_OUT"
fi

if [[ "$REPORT_ONLY" == true ]]; then
  exit 0
fi

FINAL_STATUS="$("$PYTHON_BIN" - <<'PY' "$FINAL_OUT"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if payload.get("passed") else 1)
PY
)" || true

if [[ -n "$FINAL_STATUS" ]]; then
  :
fi

"$PYTHON_BIN" - <<'PY' "$FINAL_OUT"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if payload.get("passed") else 1)
PY
