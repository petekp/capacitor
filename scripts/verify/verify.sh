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
if [[ -n "${JSON_PYTHON:-}" ]]; then
  JSON_PYTHON="$JSON_PYTHON"
elif [[ -x "$PYTHON_BIN" ]]; then
  # Keep helper scripts on the same interpreter as the verifier toolchain.
  JSON_PYTHON="$PYTHON_BIN"
else
  JSON_PYTHON="python3"
fi

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

SELECTED_SCOPE="full"
FORCE_FULL_FOR_VERIFIER_CHANGE=false
EXTRACT_STATUS=0
EXTRACT_ERROR=""
OVERALL_STATUS=0

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

mkdir -p "$REPO_ROOT/.verifier/reports" "$REPO_ROOT/.verifier/facts"

create_error_payload() {
  local out_path="$1"
  local message="$2"
  local layer_scope="${3:-$SELECTED_SCOPE}"
  "$JSON_PYTHON" - <<'PY' "$out_path" "$message" "$layer_scope"
import json
import pathlib
import sys
from datetime import datetime, timezone

out_path = pathlib.Path(sys.argv[1])
message = sys.argv[2]
selected_scope = sys.argv[3]
payload = {
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "passed": False,
    "status": "error",
    "violations": [],
    "violation_count": 0,
    "error_count": 0,
    "warning_count": 0,
    "execution_error": message,
    "selected_scope": selected_scope,
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

promote_output() {
  local temp_path="$1"
  local final_path="$2"
  mkdir -p "$(dirname "$final_path")"
  mv "$temp_path" "$final_path"
}

validate_json_file() {
  local path="$1"
  "$JSON_PYTHON" - <<'PY' "$path"
import json
import pathlib
import sys

json.loads(pathlib.Path(sys.argv[1]).read_text())
PY
}

run_command_with_fail_closed_output() {
  local layer="$1"
  local final_out="$2"
  shift 2
  local -a command=("$@")

  local tmp_out="$TMP_DIR/layer${layer}.json"
  local layer_log="$TMP_DIR/layer${layer}.log"
  rm -f "$tmp_out" "$layer_log"

  if [[ "$EXTRACT_STATUS" -ne 0 ]]; then
    create_error_payload "$tmp_out" "$EXTRACT_ERROR"
    promote_output "$tmp_out" "$final_out"
    OVERALL_STATUS=1
    return
  fi

  if [[ ! -x "$PYTHON_BIN" ]]; then
    create_error_payload "$tmp_out" "Verifier dependencies are missing. Run scripts/verify/verify.sh --bootstrap first."
    promote_output "$tmp_out" "$final_out"
    OVERALL_STATUS=1
    return
  fi

  if "${command[@]}" >"$layer_log" 2>&1; then
    if [[ ! -s "$tmp_out" ]]; then
      create_error_payload "$tmp_out" "Layer ${layer} completed without producing output."
      OVERALL_STATUS=1
    elif ! validate_json_file "$tmp_out" >/dev/null 2>&1; then
      create_error_payload "$tmp_out" "Layer ${layer} produced invalid JSON output."
      OVERALL_STATUS=1
    fi
  else
    if [[ ! -s "$tmp_out" ]] || ! validate_json_file "$tmp_out" >/dev/null 2>&1; then
      local message
      message="$(tr '\n' ' ' < "$layer_log" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
      if [[ -z "$message" ]]; then
        message="Layer ${layer} failed without producing output."
      fi
      create_error_payload "$tmp_out" "$message"
    fi
    OVERALL_STATUS=1
  fi

  promote_output "$tmp_out" "$final_out"
}

if [[ "$CHANGED_ONLY" == true ]]; then
  git -C "$REPO_ROOT" diff --name-only HEAD > "$SELECTED_PATHS_FILE" || true
  git -C "$REPO_ROOT" diff --cached --name-only >> "$SELECTED_PATHS_FILE" || true
  git -C "$REPO_ROOT" ls-files --others --exclude-standard >> "$SELECTED_PATHS_FILE" || true
  sort -u "$SELECTED_PATHS_FILE" -o "$SELECTED_PATHS_FILE" || true

  if grep -Eq '^(scripts/verify/|\.verifier/)' "$SELECTED_PATHS_FILE"; then
    FORCE_FULL_FOR_VERIFIER_CHANGE=true
    SELECTED_SCOPE="full_due_to_verifier_change"
  else
    SELECTED_SCOPE="changed_only"
  fi
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

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

"$JSON_PYTHON" - <<'PY' "$REPO_ROOT" "$SELECTED_PATHS_FILE" "$STRUCTURAL_CONFIG" "$ELEGANCE_CONFIG" "$CANONICAL_CLAIMS_PATH" "$LEDGER_PATH" "$SPECS_DIR" "$BOOTSTRAP_MANIFEST" "$RUN_MANIFEST_PATH" "$SCRIPT_DIR"
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

from pipeline import build_base_run_manifest, build_config_hashes, build_tool_versions, git_commit, git_dirty, write_manifest
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

TMP_FACTS="$TMP_DIR/current.json"
if [[ ! -x "$PYTHON_BIN" ]]; then
  EXTRACT_STATUS=1
  EXTRACT_ERROR="Verifier dependencies are missing. Run scripts/verify/verify.sh --bootstrap first."
else
  extract_args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/extract-facts.py"
    --repo-root "$REPO_ROOT"
    --out "$TMP_FACTS"
    --run-manifest "$RUN_MANIFEST_PATH"
  )
  if [[ "$CHANGED_ONLY" == true && "$FORCE_FULL_FOR_VERIFIER_CHANGE" == false ]]; then
    extract_args+=(--changed-only)
  fi

  if "${extract_args[@]}" >"$TMP_DIR/extract.log" 2>&1; then
    promote_output "$TMP_FACTS" "$FACTS_PATH"
  else
    EXTRACT_STATUS=1
    EXTRACT_ERROR="$(tr '\n' ' ' < "$TMP_DIR/extract.log" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
    if [[ -z "$EXTRACT_ERROR" ]]; then
      EXTRACT_ERROR="Fact extraction failed."
    fi
  fi
fi

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
    --out "$TMP_DIR/layer1.json"
  )
  if [[ "$CHANGED_ONLY" == true && "$FORCE_FULL_FOR_VERIFIER_CHANGE" == false ]]; then
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
  run_command_with_fail_closed_output "1" "$STRUCTURAL_OUT" "${args[@]}"
}

run_layer2() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/verify-behavioral.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --specs-dir "$SPECS_DIR"
    --canonical-claims "$CANONICAL_CLAIMS_PATH"
    --run-manifest "$RUN_MANIFEST_PATH"
    --out "$TMP_DIR/layer2.json"
  )
  if [[ "$REPORT_ONLY" == true ]]; then
    args+=(--report-only)
  fi
  run_command_with_fail_closed_output "2" "$BEHAVIORAL_OUT" "${args[@]}"
}

run_layer3() {
  local args=(
    "$PYTHON_BIN" "$SCRIPT_DIR/audit-elegance.py"
    --repo-root "$REPO_ROOT"
    --facts "$FACTS_PATH"
    --config "$ELEGANCE_CONFIG"
    --run-manifest "$RUN_MANIFEST_PATH"
    --out "$TMP_DIR/layer3.json"
  )
  # Layer 3 (elegance) always uses changed-only scoping when available.
  # Elegance is per-file — a verifier config change doesn't affect an unchanged
  # file's complexity. Full-scope escalation only applies to Layer 1 (structural).
  if [[ "$CHANGED_ONLY" == true && -f "$SELECTED_PATHS_FILE" ]]; then
    args+=(--paths-file "$SELECTED_PATHS_FILE")
  fi
  if [[ "$REPORT_ONLY" == true ]]; then
    args+=(--report-only)
  fi
  run_command_with_fail_closed_output "3" "$ELEGANCE_OUT" "${args[@]}"
}

IFS=',' read -r -a LAYER_LIST <<< "$LAYERS"
for layer in "${LAYER_LIST[@]}"; do
  case "$layer" in
    1) run_layer1 ;;
    2) run_layer2 ;;
    3) run_layer3 ;;
    *)
      echo "Unsupported layer: $layer" >&2
      exit 2
      ;;
  esac
done

"$JSON_PYTHON" - <<'PY' "$STRUCTURAL_OUT" "$BEHAVIORAL_OUT" "$ELEGANCE_OUT" "$FINAL_OUT" "$LAYERS" "$REPO_ROOT" "$RUN_MANIFEST_PATH" "$SCRIPT_DIR" "$SELECTED_SCOPE"
import json
import pathlib
import sys
from datetime import datetime, timezone

repo_root = pathlib.Path(sys.argv[6]).resolve()
script_dir = pathlib.Path(sys.argv[8]).resolve()
selected_scope = sys.argv[9]
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
report["selected_scope"] = selected_scope
final_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

if [[ "$JSON_OUTPUT" == true ]]; then
  cat "$FINAL_OUT"
fi

if [[ "$REPORT_ONLY" == true ]]; then
  exit 0
fi

"$JSON_PYTHON" - <<'PY' "$FINAL_OUT"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if payload.get("passed") else 1)
PY
