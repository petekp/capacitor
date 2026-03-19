#!/usr/bin/env bash
# update-pipeline.sh - Deterministic state mutation for .pipeline/state.json
#
# Usage:
#   ./scripts/pipeline/update-pipeline.sh --event init_pipeline --mission-id <id>
#   ./scripts/pipeline/update-pipeline.sh --event phase_added --phase-id <id> --phase-type <triage|align|execute> --skill-version <version> [--adapter-id <id> --adapter-version <version>]
#   ./scripts/pipeline/update-pipeline.sh --event phase_started --phase-id <id>
#   ./scripts/pipeline/update-pipeline.sh --event child_checkpoint --phase-id <id>
#   ./scripts/pipeline/update-pipeline.sh --event artifact_recorded --phase-id <id> --artifact-id <name> --artifact-path <path> --artifact-role <input|output>
#   ./scripts/pipeline/update-pipeline.sh --event phase_completed --phase-id <id>
#   ./scripts/pipeline/update-pipeline.sh --event gate_passed --phase-id <id> --summary <text>
#   ./scripts/pipeline/update-pipeline.sh --event gate_failed --phase-id <id> --summary <text>
#   ./scripts/pipeline/update-pipeline.sh --event superseded --phase-id <id> --summary <text>
#   ./scripts/pipeline/update-pipeline.sh --event artifact_drift_detected --phase-id <id> --summary <text>
#   ./scripts/pipeline/update-pipeline.sh --event pipeline_completed
#   ./scripts/pipeline/update-pipeline.sh --event mission_activated --mission-path <path>
#   ./scripts/pipeline/update-pipeline.sh --event constraint_set_activated --constraint-path <path>
#   ./scripts/pipeline/update-pipeline.sh --validate
#   ./scripts/pipeline/update-pipeline.sh --rebuild

set -euo pipefail

EVENT=""
MISSION_ID=""
PHASE_ID=""
PHASE_TYPE=""
SKILL_VERSION=""
ADAPTER_ID=""
ADAPTER_VERSION=""
ARTIFACT_ID=""
ARTIFACT_PATH=""
ARTIFACT_ROLE=""
MISSION_PATH=""
CONSTRAINT_PATH=""
SUMMARY=""
VALIDATE=false
REBUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) EVENT="$2"; shift 2 ;;
    --mission-id) MISSION_ID="$2"; shift 2 ;;
    --phase-id) PHASE_ID="$2"; shift 2 ;;
    --phase-type) PHASE_TYPE="$2"; shift 2 ;;
    --skill-version) SKILL_VERSION="$2"; shift 2 ;;
    --adapter-id) ADAPTER_ID="$2"; shift 2 ;;
    --adapter-version) ADAPTER_VERSION="$2"; shift 2 ;;
    --artifact-id) ARTIFACT_ID="$2"; shift 2 ;;
    --artifact-path) ARTIFACT_PATH="$2"; shift 2 ;;
    --artifact-role) ARTIFACT_ROLE="$2"; shift 2 ;;
    --mission-path) MISSION_PATH="$2"; shift 2 ;;
    --constraint-path) CONSTRAINT_PATH="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --validate) VALIDATE=true; shift ;;
    --rebuild) REBUILD=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if $VALIDATE && [[ -n "$EVENT" ]]; then
  echo "ERROR: --validate cannot be combined with --event" >&2
  exit 1
fi

if $VALIDATE && $REBUILD; then
  echo "ERROR: --validate and --rebuild are mutually exclusive" >&2
  exit 1
fi

if $REBUILD && [[ -n "$EVENT" ]]; then
  echo "ERROR: --rebuild cannot be combined with --event" >&2
  exit 1
fi

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "ERROR: update-pipeline.sh must run inside a git repository" >&2
  exit 1
fi

PIPELINE_ROOT_REL=".pipeline"
PIPELINE_ROOT_ABS="$REPO_ROOT/$PIPELINE_ROOT_REL"
STATE_FILE="$PIPELINE_ROOT_ABS/state.json"
EVENTS_FILE="$PIPELINE_ROOT_ABS/events.ndjson"
MISSION_DIR="$PIPELINE_ROOT_ABS/mission"
PHASES_DIR="$PIPELINE_ROOT_ABS/phases"

python3 - "$STATE_FILE" "$EVENTS_FILE" "$MISSION_DIR" "$PHASES_DIR" "$PIPELINE_ROOT_ABS" "$PIPELINE_ROOT_REL" "$REPO_ROOT" "$EVENT" "$MISSION_ID" "$PHASE_ID" "$PHASE_TYPE" "$SKILL_VERSION" "$ARTIFACT_ID" "$ARTIFACT_PATH" "$ARTIFACT_ROLE" "$MISSION_PATH" "$CONSTRAINT_PATH" "$ADAPTER_ID" "$ADAPTER_VERSION" "$SUMMARY" "$VALIDATE" "$REBUILD" <<'PY'
import copy
import json
import hashlib
import os
import shutil
import sys
from datetime import datetime, timezone


state_file = sys.argv[1]
events_file = sys.argv[2]
mission_dir = sys.argv[3]
phases_dir = sys.argv[4]
pipeline_root_abs = sys.argv[5]
pipeline_root_rel = sys.argv[6]
repo_root = sys.argv[7]
event = sys.argv[8]
mission_id = sys.argv[9]
phase_id = sys.argv[10]
phase_type = sys.argv[11]
skill_version = sys.argv[12]
artifact_id = sys.argv[13]
artifact_path = sys.argv[14]
artifact_role = sys.argv[15]
mission_path = sys.argv[16]
constraint_path = sys.argv[17]
adapter_id = sys.argv[18]
adapter_version = sys.argv[19]
summary = sys.argv[20]
validate_mode = sys.argv[21] == "true"
rebuild_mode = sys.argv[22] == "true"

VALID_PHASE_TYPES = {"triage", "align", "execute"}
VALID_PHASE_STATUSES = {"pending", "in_progress", "completed", "superseded"}
VALID_ARTIFACT_ROLES = {"input", "output"}
VALID_GATE_STATUSES = {"passed", "failed"}
VALID_CHILD_TERMINAL_STATUSES = {"complete", "failed", "cancelled"}
VALID_TERMINAL_PHASE_STATUSES = {"completed", "superseded"}
VALID_PIPELINE_STATUSES = {"active", "complete"}
TERMINAL_GUARDED_EVENTS = {
    "phase_added",
    "phase_started",
    "artifact_recorded",
    "mission_activated",
    "constraint_set_activated",
    "child_checkpoint",
    "gate_passed",
    "gate_failed",
    "phase_completed",
    "superseded",
    "artifact_drift_detected",
    "pipeline_completed",
}
STALE_CHILD_THRESHOLD_SECONDS = 30 * 60
STATE_JSON_BUDGET_BYTES = 2048


def utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp_value(value):
    if not isinstance(value, str) or not value:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_timestamp(value, description):
    parsed = parse_timestamp_value(value)
    if parsed is None:
        print(f"ERROR: {description} must be a valid ISO-8601 timestamp", file=sys.stderr)
        sys.exit(1)
    return parsed


def require_cli_string(value, flag_name, required_message):
    if not isinstance(value, str) or value == "":
        print(f"ERROR: {required_message}", file=sys.stderr)
        sys.exit(1)
    if not value.strip():
        print(f"ERROR: {flag_name} must be a non-empty, non-whitespace string", file=sys.stderr)
        sys.exit(1)
    return value


def load_json(path, description, require_object=False):
    try:
        with open(path) as fh:
            payload = json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: {description} {path} not found", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {description} {path} is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(1)
    if require_object and not isinstance(payload, dict):
        print(f"ERROR: {description} must be a JSON object: {path}", file=sys.stderr)
        sys.exit(1)
    return payload


def render_json(payload):
    return json.dumps(payload, separators=(",", ":")) + "\n"


def render_json_size(payload):
    return len(render_json(payload).encode("utf-8"))


def write_json_atomic(path, payload):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(render_json(payload))
    os.replace(tmp, path)


def write_text_atomic(path, content):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, path)


def load_events(path):
    if not os.path.exists(path):
        return []
    records = []
    with open(path) as fh:
        for line_no, line in enumerate(fh, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError as exc:
                print(f"ERROR: {path}:{line_no} is not valid JSON: {exc}", file=sys.stderr)
                sys.exit(1)
            if not isinstance(record, dict):
                print(f"ERROR: {path}:{line_no} must be a JSON object", file=sys.stderr)
                sys.exit(1)
            records.append(record)
    return records


def append_event(path, record):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")))
        fh.write("\n")


def normalize_rel_path(path):
    return path.replace(os.sep, "/")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8192), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_repo_file(path, description):
    if not path:
        print(f"ERROR: {description} is required", file=sys.stderr)
        sys.exit(1)
    if not isinstance(path, str) or not path.strip():
        print(f"ERROR: {description} must be a non-empty, non-whitespace string", file=sys.stderr)
        sys.exit(1)
    if os.path.isabs(path):
        abs_path = os.path.realpath(path)
    else:
        abs_path = os.path.realpath(os.path.join(repo_root, path))
    repo_root_real = os.path.realpath(repo_root)
    try:
        if os.path.commonpath([repo_root_real, abs_path]) != repo_root_real:
            raise ValueError
    except ValueError:
        print(f"ERROR: {description} must resolve inside the git repository", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(abs_path):
        print(f"ERROR: {description} {path} not found", file=sys.stderr)
        sys.exit(1)
    return abs_path, normalize_rel_path(os.path.relpath(abs_path, repo_root))


def resolve_state_repo_path(path, description, require_exists=True):
    if not isinstance(path, str) or not path:
        print(f"ERROR: {description} must be a non-empty string", file=sys.stderr)
        sys.exit(1)
    if os.path.isabs(path):
        print(f"ERROR: {description} must be repo-root-relative", file=sys.stderr)
        sys.exit(1)
    normalized = normalize_rel_path(os.path.normpath(path))
    if normalized == ".." or normalized.startswith("../"):
        print(f"ERROR: {description} must stay inside the repository", file=sys.stderr)
        sys.exit(1)
    abs_path = os.path.realpath(os.path.join(repo_root, normalized))
    repo_root_real = os.path.realpath(repo_root)
    try:
        if os.path.commonpath([repo_root_real, abs_path]) != repo_root_real:
            raise ValueError
    except ValueError:
        print(f"ERROR: {description} must stay inside the repository", file=sys.stderr)
        sys.exit(1)
    if require_exists and not os.path.isfile(abs_path):
        print(f"ERROR: {description} {normalized} not found", file=sys.stderr)
        sys.exit(1)
    return abs_path, normalized


def ensure_relative_state_path(path, description, errors):
    if not isinstance(path, str) or not path:
        errors.append(f"{description} must be a non-empty string")
        return None
    if os.path.isabs(path):
        errors.append(f"{description} must be repo-root-relative")
        return None
    normalized = os.path.normpath(path)
    if normalized == ".." or normalized.startswith(f"..{os.sep}"):
        errors.append(f"{description} must stay inside the repository")
        return None
    return os.path.join(repo_root, normalized)


def validate_phase_id(pid):
    if not isinstance(pid, str) or not pid.strip():
        print("ERROR: --phase-id must be a non-empty, non-whitespace string", file=sys.stderr)
        sys.exit(1)
    if "/" in pid or "\\" in pid or pid.startswith(".") or pid == "..":
        print(f'ERROR: invalid phase_id "{pid}" — must not contain path separators or start with "."', file=sys.stderr)
        sys.exit(1)


def phase_root_rel(pid):
    validate_phase_id(pid)
    return f"{pipeline_root_rel}/phases/{pid}"


def phase_root_abs(pid):
    return os.path.join(phases_dir, pid)


def expected_execute_adapter(pid):
    phase_root = phase_root_rel(pid)
    return {
        "relay_root": f"{phase_root}/runtime/relay",
        "status_path": f"{phase_root}/runtime/adapter-status.json",
    }


def child_status_is_terminal(status):
    return isinstance(status, str) and status in VALID_CHILD_TERMINAL_STATUSES


def latest_child_status_for_phase(state, pid):
    child_workflow = state.get("child_workflow")
    if not isinstance(child_workflow, dict):
        return None
    if child_workflow.get("phase_id") != pid:
        return None
    status = child_workflow.get("status")
    return status if isinstance(status, str) and status else None


def find_phase(state, pid):
    for phase in state.get("phases", []):
        if phase.get("phase_id") == pid:
            return phase
    print(f"ERROR: phase {pid} not found in state.json", file=sys.stderr)
    sys.exit(1)


def find_phase_index(state, pid):
    for index, phase in enumerate(state.get("phases", [])):
        if phase.get("phase_id") == pid:
            return index
    print(f"ERROR: phase {pid} not found in state.json", file=sys.stderr)
    sys.exit(1)


def predecessor_phase(state, pid):
    phase_index = find_phase_index(state, pid)
    if phase_index == 0:
        return None
    return state.get("phases", [])[phase_index - 1]


def successor_phase(state, pid):
    phase_index = find_phase_index(state, pid)
    phases = state.get("phases", [])
    if phase_index + 1 >= len(phases):
        print(f"ERROR: phase {pid} has no replacement phase to supersede into", file=sys.stderr)
        sys.exit(1)
    return phases[phase_index + 1]


def build_manifest_entry(path_rel, path_hash, role):
    return {
        "path": path_rel,
        "hash": path_hash,
        "role": role,
    }


def build_pointer(path_rel, path_hash):
    return {
        "path": path_rel,
        "hash": path_hash,
    }


def sha256_text(content):
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def load_state_pointer(pointer, description):
    if not isinstance(pointer, dict):
        print(f"ERROR: {description} must be an object", file=sys.stderr)
        sys.exit(1)
    if set(pointer.keys()) != {"path", "hash"}:
        print(f"ERROR: {description} must store only path and hash", file=sys.stderr)
        sys.exit(1)
    abs_path, rel_path = resolve_repo_file(pointer.get("path"), f"{description}.path")
    actual_hash = sha256_file(abs_path)
    if pointer.get("hash") != actual_hash:
        print(f"ERROR: {description}.hash does not match {rel_path}", file=sys.stderr)
        sys.exit(1)
    return build_pointer(rel_path, actual_hash)


def increment_epoch_id(current_epoch_id):
    current = current_epoch_id or "epoch-001"
    if not isinstance(current, str) or not current.startswith("epoch-"):
        print("ERROR: active_epoch_id must use the format epoch-###", file=sys.stderr)
        sys.exit(1)
    suffix = current.split("-", 1)[1]
    if not suffix.isdigit():
        print("ERROR: active_epoch_id must use the format epoch-###", file=sys.stderr)
        sys.exit(1)
    return f"epoch-{int(suffix) + 1:03d}"


def phase_artifact_rel(pid, filename):
    return f"{phase_root_rel(pid)}/artifacts/{filename}"


def phase_artifact_abs(pid, filename):
    return os.path.join(repo_root, phase_artifact_rel(pid, filename))


def required_recorded_phase_artifact_pointer(phase, artifact_id):
    pid = phase.get("phase_id")
    manifest = phase.get("artifact_manifest")
    if not isinstance(manifest, dict):
        gate_error(f"{artifact_id} artifact must be recorded before gate_passed")
    entry = manifest.get(artifact_id)
    if not isinstance(entry, dict):
        gate_error(f"{artifact_id} artifact must be recorded before gate_passed")
    if set(entry.keys()) != {"path", "hash", "role"}:
        gate_error(
            f"{artifact_id} artifact manifest entry must store only path, hash, and role before gate_passed"
        )
    if entry.get("role") not in VALID_ARTIFACT_ROLES:
        gate_error(f"{artifact_id} artifact has invalid recorded role {entry.get('role')!r} before gate_passed")
    # Gate readiness must be anchored to the locked manifest so execute sees the exact recorded inputs.
    return load_state_pointer(
        {
            "path": entry.get("path"),
            "hash": entry.get("hash"),
        },
        f'{pid} artifact_manifest[{artifact_id}]',
    )


def load_gate_artifact_pointers(phase):
    return (
        required_recorded_phase_artifact_pointer(phase, "execution-spec"),
        required_recorded_phase_artifact_pointer(phase, "verification-plan"),
    )


def execution_packet_rel(pid):
    return phase_artifact_rel(pid, "execution-packet.json")


def gate_error(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def validate_gate_constraints(pid):
    constraints_rel = phase_artifact_rel(pid, "constraints.json")
    constraints_abs = phase_artifact_abs(pid, "constraints.json")
    if not os.path.isfile(constraints_abs):
        gate_error(f"constraints.json is required at {constraints_rel}")
    try:
        with open(constraints_abs) as fh:
            payload = json.load(fh)
    except json.JSONDecodeError as exc:
        gate_error(f"constraints.json is not valid JSON: {exc}")

    allowed_paths = payload.get("allowed_paths")
    if not isinstance(allowed_paths, list) or not allowed_paths:
        gate_error("allowed_paths must be a non-empty array")
    for entry in allowed_paths:
        if not isinstance(entry, str) or not entry:
            gate_error("allowed_paths must contain only non-empty strings")
        if "*" in entry:
            gate_error('allowed_paths entries must not contain "*"')

    if "interface_changes" not in payload:
        gate_error("constraints.json must include interface_changes")

    verification_commands = payload.get("verification_commands")
    if not isinstance(verification_commands, list) or not verification_commands:
        gate_error("verification_commands must be a non-empty array")

    non_goals = payload.get("non_goals")
    if not isinstance(non_goals, list) or not non_goals:
        gate_error("non_goals must be a non-empty array")

    open_questions = payload.get("open_questions")
    if not isinstance(open_questions, list) or open_questions:
        gate_error("open_questions must be [] before gate_passed")

    return build_pointer(constraints_rel, sha256_file(constraints_abs))


def gate_evidence_paths(constraints_rel, execution_spec_pointer, verification_plan_pointer):
    return [
        constraints_rel,
        execution_spec_pointer["path"],
        verification_plan_pointer["path"],
    ]


def build_execution_packet(state, promoted_constraints_pointer, execution_spec_pointer, verification_plan_pointer):
    return {
        "mission": load_state_pointer(state.get("mission_version"), "mission_version"),
        "constraints": promoted_constraints_pointer,
        "execution_spec": execution_spec_pointer,
        "verification_plan": verification_plan_pointer,
    }


def require_execute_phase(phase, action):
    pid = phase.get("phase_id")
    if phase.get("phase_type") != "execute":
        print(f"ERROR: phase {pid} must be execute before {action}", file=sys.stderr)
        sys.exit(1)
    adapter = phase.get("adapter")
    if not isinstance(adapter, dict):
        print(f"ERROR: phase {pid} is missing execute adapter metadata", file=sys.stderr)
        sys.exit(1)
    return adapter


def execute_runtime_paths(phase):
    adapter = require_execute_phase(phase, "reading execute runtime state")
    status_abs, status_rel = resolve_state_repo_path(
        adapter.get("status_path"),
        f'{phase.get("phase_id")} adapter.status_path',
        require_exists=False,
    )
    lock_rel = normalize_rel_path(os.path.join(os.path.dirname(status_rel), "adapter-lock.json"))
    lock_abs = os.path.join(repo_root, lock_rel)
    return status_abs, status_rel, lock_abs, lock_rel


def load_adapter_status_snapshot(state, phase, ts):
    status_abs, status_rel, _, _ = execute_runtime_paths(phase)
    if not os.path.isfile(status_abs):
        print(f"ERROR: adapter status file is missing at {status_rel}", file=sys.stderr)
        sys.exit(1)
    payload = load_json(status_abs, "adapter status file", require_object=True)
    if payload.get("phase_id") != phase.get("phase_id"):
        print(
            f'ERROR: adapter status phase_id {payload.get("phase_id")!r} does not match {phase.get("phase_id")!r}',
            file=sys.stderr,
        )
        sys.exit(1)
    status = payload.get("status")
    if not isinstance(status, str) or not status:
        print("ERROR: adapter status file must include a non-empty status", file=sys.stderr)
        sys.exit(1)

    last_checkpoint_at = parse_timestamp(
        payload.get("last_checkpoint_at"),
        f'{phase.get("phase_id")} adapter-status last_checkpoint_at',
    )
    record_ts = parse_timestamp(ts, "record ts")

    child_workflow = copy.deepcopy(payload)
    child_workflow["stale"] = (
        not child_status_is_terminal(status)
        and (record_ts - last_checkpoint_at).total_seconds() > STALE_CHILD_THRESHOLD_SECONDS
    )
    if child_workflow["stale"]:
        child_workflow["stale_detected_at"] = ts

    state_updated_at = state.get("updated_at") if isinstance(state, dict) else None
    if state_updated_at is None:
        reconciled_forward = True
    else:
        reconciled_forward = last_checkpoint_at > parse_timestamp(state_updated_at, "state.updated_at")
    return child_workflow, reconciled_forward, status_rel


def prevent_duplicate_execute_dispatch(phase):
    status_abs, status_rel, lock_abs, lock_rel = execute_runtime_paths(phase)
    if not os.path.isfile(lock_abs):
        return
    if not os.path.isfile(status_abs):
        print(
            f"ERROR: adapter lock exists at {lock_rel} but adapter status is missing at {status_rel}; "
            f"refusing duplicate dispatch for {phase.get('phase_id')}",
            file=sys.stderr,
        )
        sys.exit(1)
    payload = load_json(status_abs, "adapter status file", require_object=True)
    status = payload.get("status")
    if not isinstance(status, str) or not status:
        print("ERROR: adapter status file must include a non-empty status", file=sys.stderr)
        sys.exit(1)
    if child_status_is_terminal(status):
        return
    print(
        f"ERROR: existing child workflow is still active at {lock_rel} ({status}); "
        f"refusing duplicate dispatch for {phase.get('phase_id')}",
        file=sys.stderr,
    )
    sys.exit(1)


def detect_locked_artifact_drift(phase):
    if phase.get("lock_state") != "locked":
        print(
            f"ERROR: phase {phase.get('phase_id')} must be locked before artifact_drift_detected",
            file=sys.stderr,
        )
        sys.exit(1)

    manifest = phase.get("artifact_manifest")
    if not isinstance(manifest, dict) or not manifest:
        print(
            f"ERROR: phase {phase.get('phase_id')} must have locked artifacts before artifact_drift_detected",
            file=sys.stderr,
        )
        sys.exit(1)

    drifted = []
    for current_artifact_id in sorted(manifest):
        entry = manifest[current_artifact_id]
        if not isinstance(entry, dict):
            print(
                f'ERROR: phase {phase.get("phase_id")} artifact_manifest[{current_artifact_id}] must be an object',
                file=sys.stderr,
            )
            sys.exit(1)
        artifact_abs, artifact_rel = resolve_state_repo_path(
            entry.get("path"),
            f'{phase.get("phase_id")} artifact_manifest[{current_artifact_id}].path',
            require_exists=False,
        )
        actual_hash = sha256_file(artifact_abs) if os.path.isfile(artifact_abs) else None
        if entry.get("hash") != actual_hash:
            drifted.append(
                {
                    "artifact_id": current_artifact_id,
                    "path": artifact_rel,
                    "recorded_hash": entry.get("hash"),
                    "actual_hash": actual_hash,
                }
            )
    return drifted


def rehash_phase_artifacts(phase):
    manifest = phase.get("artifact_manifest") or {}
    if not isinstance(manifest, dict):
        print(f'ERROR: phase {phase.get("phase_id")} artifact_manifest must be an object', file=sys.stderr)
        sys.exit(1)

    refreshed = {}
    for current_artifact_id in sorted(manifest):
        entry = manifest[current_artifact_id]
        if not isinstance(entry, dict):
            print(
                f'ERROR: phase {phase.get("phase_id")} artifact_manifest[{current_artifact_id}] must be an object',
                file=sys.stderr,
            )
            sys.exit(1)
        role = entry.get("role")
        if role not in VALID_ARTIFACT_ROLES:
            print(
                f'ERROR: artifact {current_artifact_id} has invalid role "{role}"',
                file=sys.stderr,
            )
            sys.exit(1)
        abs_path, rel_path = resolve_repo_file(entry.get("path"), f"artifact {current_artifact_id}")
        refreshed[current_artifact_id] = build_manifest_entry(rel_path, sha256_file(abs_path), role)
    return refreshed


def build_resume_contents(record):
    artifact_lines = []
    for current_artifact_id in sorted(record["artifacts"]):
        entry = record["artifacts"][current_artifact_id]
        artifact_lines.append(
            f"- `{current_artifact_id}` ({entry['role']}): `{entry['path']}`"
        )
    if not artifact_lines:
        artifact_lines.append("- No recorded artifacts were present for this phase.")
    return "\n".join(
        [
            "# Phase Resume",
            "",
            f"Phase `{record['phase_id']}` (`{record['phase_type']}`) completed successfully.",
            "",
            "## Accomplished",
            "",
            f"- Locked {len(record['artifacts'])} recorded artifact(s).",
            f"- Published resume artifact `{record['resume_path']}`.",
            "",
            "## Artifacts",
            "",
            *artifact_lines,
            "",
        ]
    )


def compute_pipeline_retrospective_metrics(state):
    phases = state.get("phases", [])
    superseded_count = sum(1 for phase in phases if phase.get("status") == "superseded")
    gate_failures = sum(
        1
        for phase in phases
        if isinstance(phase.get("gate_result"), dict)
        and phase["gate_result"].get("status") == "failed"
    )
    execute_slice_counts = {}
    for phase in phases:
        if phase.get("phase_type") != "execute":
            continue
        child_workflow = phase.get("child_workflow")
        if not isinstance(child_workflow, dict):
            continue
        counts = child_workflow.get("counts")
        if not isinstance(counts, dict):
            continue
        total_slices = counts.get("total_slices")
        if isinstance(total_slices, int) and not isinstance(total_slices, bool):
            execute_slice_counts[phase.get("phase_id")] = total_slices
    return {
        "total_phases": len(phases),
        "epoch_resets": superseded_count,
        "gate_failures": gate_failures,
        "rework_phases": superseded_count,
        "execute_slice_counts": execute_slice_counts,
    }


def build_pipeline_retrospective_record(state, ts):
    return {
        "ts": ts,
        "event": "pipeline_retrospective",
        "mutation": "pipeline_retrospective",
        "pipeline_id": state.get("pipeline_id"),
        "metrics": compute_pipeline_retrospective_metrics(state),
    }


def compact_child_workflow(payload):
    compact = {
        "last_checkpoint_at": payload.get("last_checkpoint_at"),
    }
    status = bounded_text(payload.get("status"), 40)
    if status is not None:
        compact["status"] = status
    phase_ref = payload.get("phase_id")
    if isinstance(phase_ref, str) and phase_ref:
        compact["phase_id"] = phase_ref
    stale = payload.get("stale")
    if stale is True:
        compact["stale"] = True
        if isinstance(payload.get("stale_detected_at"), str) and payload.get("stale_detected_at"):
            compact["stale_detected_at"] = payload.get("stale_detected_at")
    counts = payload.get("counts")
    if isinstance(counts, dict):
        total_slices = counts.get("total_slices")
        if isinstance(total_slices, int) and not isinstance(total_slices, bool):
            compact["counts"] = {"total_slices": total_slices}
    return compact


def bounded_text(value, limit):
    if not isinstance(value, str) or not value:
        return None
    if len(value) <= limit:
        return value
    if limit <= 3:
        return value[:limit]
    return value[: limit - 3] + "..."


def project_child_verdict(verdict):
    if isinstance(verdict, str):
        return bounded_text(verdict, 40)
    if isinstance(verdict, dict):
        status = bounded_text(verdict.get("status"), 40)
        if status is not None:
            return status
        summary = bounded_text(verdict.get("summary"), 40)
        if summary is not None:
            return summary
    return None


def project_child_workflow(payload):
    projected = {}
    for field, limit in (
        ("progress_summary", 120),
        ("current_operation", 80),
    ):
        bounded_value = bounded_text(payload.get(field), limit)
        if bounded_value is not None:
            projected[field] = bounded_value
    verdict = project_child_verdict(payload.get("verdict"))
    if verdict is not None:
        projected["verdict"] = verdict
    return projected


def enforce_state_budget(state, event_name):
    state_size = render_json_size(state)
    if state_size >= STATE_JSON_BUDGET_BYTES:
        print(
            f"ERROR: state.json would be {state_size} bytes after {event_name}; "
            f"must remain under {STATE_JSON_BUDGET_BYTES} bytes",
            file=sys.stderr,
        )
        sys.exit(1)
    return state


def reject_completed_pipeline_mutation(state, cli_event):
    if state.get("status") == "complete" and cli_event in TERMINAL_GUARDED_EVENTS:
        print(f"ERROR: pipeline is complete; {cli_event} rejected", file=sys.stderr)
        sys.exit(1)


def build_record(state, cli_event, ts):
    if cli_event == "init_pipeline":
        require_cli_string(mission_id, "--mission-id", "--mission-id is required for init_pipeline")
        if state is not None:
            print("ERROR: pipeline is already initialized", file=sys.stderr)
            sys.exit(1)
        return {
            "ts": ts,
            "event": "init_pipeline",
            "mutation": "init_pipeline",
            "pipeline_id": mission_id,
            "pipeline_root": pipeline_root_rel,
        }

    if state is None:
        print("ERROR: pipeline state is not initialized", file=sys.stderr)
        sys.exit(1)

    reject_completed_pipeline_mutation(state, cli_event)

    if cli_event == "phase_added":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for phase_added")
        validate_phase_id(phase_id)
        if not phase_type:
            print("ERROR: --phase-type is required for phase_added", file=sys.stderr)
            sys.exit(1)
        if phase_type not in VALID_PHASE_TYPES:
            print(
                'ERROR: invalid --phase-type "{}" (expected triage, align, or execute)'.format(phase_type),
                file=sys.stderr,
            )
            sys.exit(1)
        require_cli_string(skill_version, "--skill-version", "--skill-version is required for phase_added")
        for existing in state.get("phases", []):
            if existing.get("phase_id") == phase_id:
                print(f"ERROR: phase {phase_id} already exists", file=sys.stderr)
                sys.exit(1)
        record = {
            "ts": ts,
            "event": "phase_added",
            "mutation": "phase_added",
            "phase_id": phase_id,
            "phase_type": phase_type,
            "skill_version": skill_version,
        }
        if phase_type == "execute":
            require_cli_string(adapter_id, "--adapter-id", "--adapter-id is required for execute phase_added")
            require_cli_string(adapter_version, "--adapter-version", "--adapter-version is required for execute phase_added")
            record["adapter"] = {
                "adapter_id": adapter_id,
                "adapter_version": adapter_version,
                **expected_execute_adapter(phase_id),
            }
        return record

    if cli_event == "phase_started":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for phase_started")
        validate_phase_id(phase_id)
        target = find_phase(state, phase_id)
        target_status = target.get("status")
        if target_status in {"in_progress", "completed", "superseded"} or target.get("lock_state") == "locked":
            if target_status == "in_progress":
                print(f"ERROR: phase {phase_id} is already in_progress", file=sys.stderr)
            else:
                print(
                    f"ERROR: phase {phase_id} is already completed/superseded/locked and cannot be restarted",
                    file=sys.stderr,
                )
            sys.exit(1)
        for existing in state.get("phases", []):
            if existing.get("status") == "in_progress" and existing.get("phase_id") != phase_id:
                print(
                    f'ERROR: phase {existing.get("phase_id")} is already in_progress; '
                    f"cannot start {phase_id}",
                    file=sys.stderr,
                )
                sys.exit(1)
        if target.get("phase_type") == "execute":
            previous_phase = predecessor_phase(state, phase_id)
            if previous_phase is None or previous_phase.get("phase_type") != "align":
                print(
                    f"ERROR: predecessor must be an align phase before execute {phase_id} can start",
                    file=sys.stderr,
                )
                sys.exit(1)
            gate_result = previous_phase.get("gate_result") if previous_phase is not None else None
            if not isinstance(gate_result, dict) or gate_result.get("status") != "passed":
                print(
                    f"ERROR: predecessor gate must pass before execute {phase_id} can start",
                    file=sys.stderr,
                )
                sys.exit(1)
            packet_rel = execution_packet_rel(previous_phase.get("phase_id"))
            if not os.path.isfile(os.path.join(repo_root, packet_rel)):
                print(
                    f"ERROR: predecessor execution packet is missing at {packet_rel}",
                    file=sys.stderr,
                )
                sys.exit(1)
            prevent_duplicate_execute_dispatch(target)
        return {
            "ts": ts,
            "event": "phase_started",
            "mutation": "phase_started",
            "phase_id": phase_id,
        }

    if cli_event == "child_checkpoint":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for child_checkpoint")
        target = find_phase(state, phase_id)
        if target.get("status") == "superseded":
            print(f"ERROR: phase {phase_id} is superseded and cannot receive child_checkpoint", file=sys.stderr)
            sys.exit(1)
        if target.get("status") != "in_progress":
            print(
                f"ERROR: phase {phase_id} must be in_progress before child_checkpoint",
                file=sys.stderr,
            )
            sys.exit(1)
        child_workflow, reconciled_forward, status_rel = load_adapter_status_snapshot(state, target, ts)
        return {
            "ts": ts,
            "event": "child_checkpoint",
            "mutation": "child_checkpoint",
            "phase_id": phase_id,
            "status_path": status_rel,
            "child_workflow": child_workflow,
            "reconciled_forward": reconciled_forward,
        }

    if cli_event == "artifact_recorded":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for artifact_recorded")
        require_cli_string(artifact_id, "--artifact-id", "--artifact-id is required for artifact_recorded")
        require_cli_string(artifact_path, "--artifact-path", "--artifact-path is required for artifact_recorded")
        if artifact_role not in VALID_ARTIFACT_ROLES:
            print(
                f'ERROR: invalid --artifact-role "{artifact_role}" (expected input or output)',
                file=sys.stderr,
            )
            sys.exit(1)
        phase = find_phase(state, phase_id)
        if phase.get("status") == "superseded":
            print(f"ERROR: phase {phase_id} is superseded; artifacts cannot be recorded", file=sys.stderr)
            sys.exit(1)
        if phase.get("status") == "completed" or phase.get("lock_state") == "locked":
            print(
                f"ERROR: phase {phase_id} is completed/locked; artifacts cannot be recorded",
                file=sys.stderr,
            )
            sys.exit(1)
        artifact_abs, artifact_rel = resolve_repo_file(artifact_path, "--artifact-path")
        artifact_hash = sha256_file(artifact_abs)
        return {
            "ts": ts,
            "event": "artifact_recorded",
            "mutation": "artifact_recorded",
            "phase_id": phase_id,
            "artifact_id": artifact_id,
            "path": artifact_rel,
            "hash": artifact_hash,
            "role": artifact_role,
        }

    if cli_event == "phase_completed":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for phase_completed")
        phase = find_phase(state, phase_id)
        if phase.get("status") == "superseded":
            print(f"ERROR: phase {phase_id} is superseded and cannot be completed", file=sys.stderr)
            sys.exit(1)
        if phase.get("status") != "in_progress":
            print(
                f"ERROR: phase {phase_id} must be in_progress before phase_completed",
                file=sys.stderr,
            )
            sys.exit(1)
        if phase.get("phase_type") == "execute":
            child_status = latest_child_status_for_phase(state, phase_id)
            if not child_status_is_terminal(child_status):
                rendered_status = child_status if child_status is not None else "missing"
                print(
                    f"ERROR: phase_completed rejected for execute phase {phase_id}; "
                    f"child workflow status is {rendered_status}, not terminal",
                    file=sys.stderr,
                )
                sys.exit(1)
        refreshed_artifacts = rehash_phase_artifacts(phase)
        resume_rel = f"{phase_root_rel(phase_id)}/artifacts/resume.md"
        resume_contents = build_resume_contents(
            {
                "phase_id": phase_id,
                "phase_type": phase.get("phase_type"),
                "artifacts": refreshed_artifacts,
                "resume_path": resume_rel,
            }
        )
        resume_hash = sha256_text(resume_contents)
        return {
            "ts": ts,
            "event": "phase_completed",
            "mutation": "phase_completed",
            "phase_id": phase_id,
            "phase_type": phase.get("phase_type"),
            "artifacts": refreshed_artifacts,
            "resume_path": resume_rel,
            "resume_hash": resume_hash,
        }

    if cli_event == "pipeline_completed":
        if state.get("status") == "complete":
            print("ERROR: pipeline is already complete", file=sys.stderr)
            sys.exit(1)
        non_terminal = [
            f"{phase.get('phase_id')} ({phase.get('status')})"
            for phase in state.get("phases", [])
            if phase.get("status") not in VALID_TERMINAL_PHASE_STATUSES
        ]
        if non_terminal:
            print(
                f"ERROR: pipeline_completed requires all phases to be terminal (phases still pending or in_progress: {', '.join(non_terminal)})",
                file=sys.stderr,
            )
            sys.exit(1)
        return {
            "ts": ts,
            "event": "pipeline_completed",
            "mutation": "pipeline_completed",
        }

    if cli_event == "superseded":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for superseded")
        require_cli_string(summary, "--summary", "--summary is required for superseded")
        target = find_phase(state, phase_id)
        if target.get("status") in {"completed", "superseded"} or target.get("lock_state") == "locked":
            print(
                f"ERROR: phase {phase_id} is completed/superseded/locked and cannot be superseded",
                file=sys.stderr,
            )
            sys.exit(1)
        replacement = successor_phase(state, phase_id)
        return {
            "ts": ts,
            "event": "superseded",
            "mutation": "superseded",
            "phase_id": phase_id,
            "summary": summary,
            "replacement_phase_id": replacement.get("phase_id"),
            "next_active_epoch_id": increment_epoch_id(state.get("active_epoch_id")),
        }

    if cli_event == "artifact_drift_detected":
        require_cli_string(phase_id, "--phase-id", "--phase-id is required for artifact_drift_detected")
        require_cli_string(summary, "--summary", "--summary is required for artifact_drift_detected")
        target = find_phase(state, phase_id)
        drifted_artifacts = detect_locked_artifact_drift(target)
        if not drifted_artifacts:
            print(
                f"ERROR: no locked artifact drift detected for phase {phase_id}",
                file=sys.stderr,
            )
            sys.exit(1)
        return {
            "ts": ts,
            "event": "artifact_drift_detected",
            "mutation": "artifact_drift_detected",
            "phase_id": phase_id,
            "summary": summary,
            "drifted_artifacts": drifted_artifacts,
        }

    if cli_event in {"gate_passed", "gate_failed"}:
        require_cli_string(phase_id, "--phase-id", f"--phase-id is required for {cli_event}")
        require_cli_string(summary, "--summary", f"--summary is required for {cli_event}")
        phase = find_phase(state, phase_id)
        if phase.get("phase_type") != "align":
            gate_error("gate events require align phases")
        if phase.get("status") == "superseded":
            gate_error(f"phase {phase_id} is superseded and cannot receive {cli_event}")
        if phase.get("status") != "completed" or phase.get("lock_state") != "locked":
            print(
                f"ERROR: phase {phase_id} must be completed/locked before {cli_event}",
                file=sys.stderr,
            )
            sys.exit(1)
        if phase.get("gate_result") is not None:
            gate_error(f"gate outcome already set for phase {phase_id}; gate events are terminal per phase")
        gate_result = {
            "status": "passed" if cli_event == "gate_passed" else "failed",
            "summary": summary,
            "checked_at": ts,
        }
        record = {
            "ts": ts,
            "event": cli_event,
            "mutation": cli_event,
            "phase_id": phase_id,
            "summary": summary,
            "gate_result": gate_result,
        }
        if cli_event == "gate_passed":
            phase_constraints = validate_gate_constraints(phase_id)
            promoted_constraints = load_state_pointer(state.get("active_constraint_set"), "active_constraint_set")
            if promoted_constraints["hash"] != phase_constraints["hash"]:
                gate_error("active_constraint_set must match the phase constraints.json before gate_passed")
            # v1 gates only require the machine-checkable execution contract artifacts.
            # decision-log remains optional human traceability context and is not part of execute readiness.
            execution_spec, verification_plan = load_gate_artifact_pointers(phase)
            evidence_paths = gate_evidence_paths(phase_constraints["path"], execution_spec, verification_plan)
            execution_packet = build_execution_packet(
                state,
                promoted_constraints,
                execution_spec,
                verification_plan,
            )
            packet_path = execution_packet_rel(phase_id)
            gate_result["evidence_paths"] = evidence_paths
            record["evidence_paths"] = evidence_paths
            record["execution_packet"] = execution_packet
            record["execution_packet_path"] = packet_path
            record["execution_packet_hash"] = sha256_text(render_json(execution_packet))
        return record

    if cli_event == "mission_activated":
        require_cli_string(mission_path, "--mission-path", "--mission-path is required for mission_activated")
        mission_abs, mission_rel = resolve_repo_file(mission_path, "--mission-path")
        return {
            "ts": ts,
            "event": "mission_activated",
            "mutation": "mission_activated",
            "path": mission_rel,
            "hash": sha256_file(mission_abs),
        }

    if cli_event == "constraint_set_activated":
        require_cli_string(constraint_path, "--constraint-path", "--constraint-path is required for constraint_set_activated")
        source_abs, source_rel = resolve_repo_file(constraint_path, "--constraint-path")
        promoted_rel = f"{pipeline_root_rel}/constraints/sets/{os.path.basename(source_rel)}"
        return {
            "ts": ts,
            "event": "constraint_set_activated",
            "mutation": "constraint_set_activated",
            "source_path": source_rel,
            "path": promoted_rel,
            "hash": sha256_file(source_abs),
        }

    print(f'ERROR: unknown event "{cli_event}"', file=sys.stderr)
    sys.exit(1)


def ensure_record_directories(record):
    if record["event"] == "init_pipeline":
        os.makedirs(pipeline_root_abs, exist_ok=True)
        os.makedirs(mission_dir, exist_ok=True)
        os.makedirs(phases_dir, exist_ok=True)
        return

    if record["event"] == "phase_added":
        phase_root = phase_root_abs(record["phase_id"])
        os.makedirs(os.path.join(phase_root, "artifacts"), exist_ok=True)
        if record["phase_type"] == "execute":
            os.makedirs(os.path.join(phase_root, "runtime", "relay"), exist_ok=True)
        return

    if record["event"] == "constraint_set_activated":
        os.makedirs(os.path.join(pipeline_root_abs, "constraints", "sets"), exist_ok=True)
        return


def materialize_record(record):
    if record["event"] == "phase_completed":
        resume_abs = os.path.join(repo_root, record["resume_path"])
        write_text_atomic(resume_abs, build_resume_contents(record))
        return

    if record["event"] == "gate_passed":
        packet_abs = os.path.join(repo_root, record["execution_packet_path"])
        write_json_atomic(packet_abs, record["execution_packet"])
        return

    if record["event"] == "constraint_set_activated":
        source_abs = os.path.join(repo_root, record["source_path"])
        promoted_abs = os.path.join(repo_root, record["path"])
        shutil.copyfile(source_abs, promoted_abs)
        return


def apply_record(state, record):
    if record["event"] == "init_pipeline":
        return enforce_state_budget({
            "pipeline_id": record["pipeline_id"],
            "pipeline_root": pipeline_root_rel,
            "status": "active",
            "active_epoch_id": "epoch-001",
            "current_phase_id": None,
            "phases": [],
            "latest_resume": None,
            "child_workflow": None,
            "automatic_resume": {"blocked": False},
        }, record["event"])

    if state is None:
        print(
            f'ERROR: ledger must begin with init_pipeline before {record["event"]}',
            file=sys.stderr,
        )
        sys.exit(1)

    if record["event"] == "phase_added":
        phase = {
            "phase_id": record["phase_id"],
            "phase_type": record["phase_type"],
            "skill_version": record["skill_version"],
            "status": "pending",
            "lock_state": "unlocked",
        }
        if record["phase_type"] == "execute":
            phase["adapter"] = dict(record["adapter"])
        state.setdefault("phases", []).append(phase)
        return enforce_state_budget(state, record["event"])

    if record["event"] == "phase_started":
        target = find_phase(state, record["phase_id"])
        target["status"] = "in_progress"
        state["current_phase_id"] = record["phase_id"]
        return enforce_state_budget(state, record["event"])

    if record["event"] == "child_checkpoint":
        target = find_phase(state, record["phase_id"])
        target["child_workflow"] = project_child_workflow(record["child_workflow"])
        state["child_workflow"] = compact_child_workflow(record["child_workflow"])
        return enforce_state_budget(state, record["event"])

    if record["event"] == "artifact_recorded":
        target = find_phase(state, record["phase_id"])
        manifest = target.setdefault("artifact_manifest", {})
        manifest[record["artifact_id"]] = build_manifest_entry(
            record["path"],
            record["hash"],
            record["role"],
        )
        return enforce_state_budget(state, record["event"])

    if record["event"] == "phase_completed":
        target = find_phase(state, record["phase_id"])
        target["status"] = "completed"
        target["lock_state"] = "locked"
        if record["artifacts"]:
            target["artifact_manifest"] = dict(record["artifacts"])
        else:
            target.pop("artifact_manifest", None)
        if target.get("phase_type") == "execute" and isinstance(target.get("child_workflow"), dict):
            mirrored_child_workflow = state.get("child_workflow")
            if (
                isinstance(mirrored_child_workflow, dict)
                and mirrored_child_workflow.get("phase_id") == record["phase_id"]
            ):
                target["child_workflow"] = copy.deepcopy(mirrored_child_workflow)
            else:
                target.pop("child_workflow", None)
        if state.get("current_phase_id") == record["phase_id"]:
            state["current_phase_id"] = None
        child_workflow = state.get("child_workflow")
        if isinstance(child_workflow, dict) and child_workflow.get("phase_id") == record["phase_id"]:
            state["child_workflow"] = None
        state["latest_resume"] = record["resume_path"]
        return enforce_state_budget(state, record["event"])

    if record["event"] == "pipeline_completed":
        state["status"] = "complete"
        state["current_phase_id"] = None
        return enforce_state_budget(state, record["event"])

    if record["event"] == "superseded":
        target = find_phase(state, record["phase_id"])
        target["status"] = "superseded"
        target["lock_state"] = "locked"
        target["superseded_by"] = record["replacement_phase_id"]
        target["superseded_reason"] = record["summary"]
        state["active_epoch_id"] = record["next_active_epoch_id"]
        if state.get("current_phase_id") == record["phase_id"]:
            state["current_phase_id"] = None
        child_workflow = state.get("child_workflow")
        if isinstance(child_workflow, dict) and child_workflow.get("phase_id") == record["phase_id"]:
            state["child_workflow"] = None
        return enforce_state_budget(state, record["event"])

    if record["event"] == "artifact_drift_detected":
        target = find_phase(state, record["phase_id"])
        target["artifact_drift"] = {
            "summary": record["summary"],
            "detected_at": record["ts"],
            "artifacts": copy.deepcopy(record["drifted_artifacts"]),
        }
        state["automatic_resume"] = {
            "blocked": True,
            "reason": "artifact_drift_detected",
            "phase_id": record["phase_id"],
            "summary": record["summary"],
            "blocked_at": record["ts"],
        }
        return enforce_state_budget(state, record["event"])

    if record["event"] in {"gate_passed", "gate_failed"}:
        target = find_phase(state, record["phase_id"])
        target["gate_result"] = dict(record["gate_result"])
        return enforce_state_budget(state, record["event"])

    if record["event"] == "mission_activated":
        state["mission_version"] = {
            "path": record["path"],
            "hash": record["hash"],
        }
        return enforce_state_budget(state, record["event"])

    if record["event"] == "constraint_set_activated":
        state["active_constraint_set"] = {
            "path": record["path"],
            "hash": record["hash"],
        }
        return enforce_state_budget(state, record["event"])

    if record["event"] == "pipeline_retrospective":
        return enforce_state_budget(state, record["event"])

    print(f'ERROR: unknown ledger event "{record["event"]}"', file=sys.stderr)
    sys.exit(1)


def validate_state(state):
    errors = []

    def validate_child_workflow(payload, description):
        if not isinstance(payload, dict):
            errors.append(f"{description} must be an object")
            return
        if not isinstance(payload.get("status"), str) or not payload.get("status"):
            errors.append(f"{description}.status must be a non-empty string")
        if parse_timestamp_value(payload.get("last_checkpoint_at")) is None:
            errors.append(f"{description}.last_checkpoint_at must be a valid ISO-8601 timestamp")
        stale = payload.get("stale")
        if stale is not None and not isinstance(stale, bool):
            errors.append(f"{description}.stale must be a boolean when present")
        if stale:
            if parse_timestamp_value(payload.get("stale_detected_at")) is None:
                errors.append(f"{description}.stale_detected_at must be a valid ISO-8601 timestamp when stale")
        counts = payload.get("counts")
        if counts is not None and not isinstance(counts, dict):
            errors.append(f"{description}.counts must be an object when present")

    def validate_phase_child_workflow(payload, description):
        if not isinstance(payload, dict):
            errors.append(f"{description} must be an object")
            return
        progress_summary = payload.get("progress_summary")
        if progress_summary is not None and (not isinstance(progress_summary, str) or not progress_summary):
            errors.append(f"{description}.progress_summary must be a non-empty string when present")
        current_operation = payload.get("current_operation")
        if current_operation is not None and (not isinstance(current_operation, str) or not current_operation):
            errors.append(f"{description}.current_operation must be a non-empty string when present")
        verdict = payload.get("verdict")
        if verdict is not None and (not isinstance(verdict, str) or not verdict):
            errors.append(f"{description}.verdict must be a non-empty string when present")

    if not os.path.exists(events_file):
        errors.append("events.ndjson is missing — ledger integrity cannot be verified")
    else:
        load_events(events_file)

    if state.get("pipeline_root") != pipeline_root_rel:
        errors.append(
            f'pipeline_root {state.get("pipeline_root")!r} does not match expected {pipeline_root_rel!r}'
        )
    pipeline_status = state.get("status")
    if pipeline_status not in VALID_PIPELINE_STATUSES:
        errors.append(f"status must be one of: {', '.join(sorted(VALID_PIPELINE_STATUSES))}")
    if "repo_root" in state:
        errors.append("state.json must not store repo_root")
    if render_json_size(state) >= STATE_JSON_BUDGET_BYTES:
        errors.append("state.json must remain under 2KB")
    if os.path.exists(os.path.join(pipeline_root_abs, "plan.json")):
        errors.append("pipeline-level plan.json must not exist")
    if not os.path.isdir(mission_dir):
        errors.append("missing mission directory")
    if not os.path.isdir(phases_dir):
        errors.append("missing phases directory")

    updated_at = state.get("updated_at")
    if not isinstance(updated_at, str) or not updated_at:
        errors.append("updated_at must be a non-empty string")
    elif parse_timestamp_value(updated_at) is None:
        errors.append("updated_at must be a valid ISO-8601 timestamp")

    active_epoch_id = state.get("active_epoch_id")
    if not isinstance(active_epoch_id, str) or not active_epoch_id.startswith("epoch-"):
        errors.append("active_epoch_id must use the format epoch-###")
    else:
        suffix = active_epoch_id.split("-", 1)[1]
        if not suffix.isdigit():
            errors.append("active_epoch_id must use the format epoch-###")

    automatic_resume = state.get("automatic_resume")
    if not isinstance(automatic_resume, dict):
        errors.append("automatic_resume must be an object")
    else:
        blocked = automatic_resume.get("blocked")
        if not isinstance(blocked, bool):
            errors.append("automatic_resume.blocked must be a boolean")
        elif blocked:
            if not isinstance(automatic_resume.get("reason"), str) or not automatic_resume.get("reason"):
                errors.append("automatic_resume.reason must be a non-empty string when blocked")
            if not isinstance(automatic_resume.get("phase_id"), str) or not automatic_resume.get("phase_id"):
                errors.append("automatic_resume.phase_id must be a non-empty string when blocked")
            if parse_timestamp_value(automatic_resume.get("blocked_at")) is None:
                errors.append("automatic_resume.blocked_at must be a valid ISO-8601 timestamp when blocked")
            if not isinstance(automatic_resume.get("summary"), str) or not automatic_resume.get("summary"):
                errors.append("automatic_resume.summary must be a non-empty string when blocked")

    state_child_workflow = state.get("child_workflow")
    if state_child_workflow is not None:
        validate_child_workflow(state_child_workflow, "child_workflow")

    mission_version = state.get("mission_version")
    if mission_version is not None:
        if not isinstance(mission_version, dict):
            errors.append("mission_version must be an object")
        else:
            if set(mission_version.keys()) != {"path", "hash"}:
                errors.append("mission_version must store only path and hash")
            mission_abs = ensure_relative_state_path(mission_version.get("path"), "mission_version.path", errors)
            if mission_abs and not os.path.isfile(mission_abs):
                errors.append(f"missing mission document: {mission_version.get('path')}")
            elif mission_abs and mission_version.get("hash") != sha256_file(mission_abs):
                errors.append("mission_version.hash does not match the mission document")

    active_constraint_set = state.get("active_constraint_set")
    if active_constraint_set is not None:
        if not isinstance(active_constraint_set, dict):
            errors.append("active_constraint_set must be an object")
        else:
            if set(active_constraint_set.keys()) != {"path", "hash"}:
                errors.append("active_constraint_set must store only path and hash")
            constraint_abs = ensure_relative_state_path(
                active_constraint_set.get("path"),
                "active_constraint_set.path",
                errors,
            )
            if constraint_abs and not os.path.isfile(constraint_abs):
                errors.append(f"missing promoted constraint set: {active_constraint_set.get('path')}")
            elif constraint_abs and active_constraint_set.get("hash") != sha256_file(constraint_abs):
                errors.append("active_constraint_set.hash does not match the promoted constraint set")

    phases = state.get("phases")
    if not isinstance(phases, list):
        errors.append("phases must be an array")
        return errors

    phase_ids = set()
    in_progress = []
    for phase in phases:
        pid = phase.get("phase_id")
        ptype = phase.get("phase_type")
        phase_status = phase.get("status")
        if not pid:
            errors.append("phase entry missing phase_id")
            continue
        if pid in phase_ids:
            errors.append(f"duplicate phase_id {pid}")
        phase_ids.add(pid)
        if ptype not in VALID_PHASE_TYPES:
            errors.append(f"{pid} has invalid phase_type {ptype!r}")
        if not phase.get("skill_version"):
            errors.append(f"{pid} is missing skill_version")
        if phase_status not in VALID_PHASE_STATUSES:
            errors.append(f"{pid} has invalid status {phase_status!r}")
        if phase_status == "in_progress":
            in_progress.append(pid)
        if phase_status in {"completed", "superseded"} and phase.get("lock_state") != "locked":
            errors.append(f"{pid} must be locked when {phase_status}")

        phase_root = phase_root_abs(pid)
        artifacts_dir = os.path.join(phase_root, "artifacts")
        if not os.path.isdir(phase_root):
            errors.append(f"missing expected directory: {phase_root}")
        if not os.path.isdir(artifacts_dir):
            errors.append(f"missing expected directory: {artifacts_dir}")

        manifest = phase.get("artifact_manifest")
        if manifest is not None:
            if not isinstance(manifest, dict):
                errors.append(f"{pid} artifact_manifest must be an object")
            else:
                for current_artifact_id, entry in manifest.items():
                    if not isinstance(entry, dict):
                        errors.append(f"{pid} artifact_manifest[{current_artifact_id}] must be an object")
                        continue
                    if set(entry.keys()) != {"path", "hash", "role"}:
                        errors.append(
                            f"{pid} artifact_manifest[{current_artifact_id}] must store only path, hash, and role"
                        )
                    if entry.get("role") not in VALID_ARTIFACT_ROLES:
                        errors.append(
                            f"{pid} artifact_manifest[{current_artifact_id}] has invalid role {entry.get('role')!r}"
                        )
                    artifact_abs = ensure_relative_state_path(
                        entry.get("path"),
                        f"{pid} artifact_manifest[{current_artifact_id}].path",
                        errors,
                    )
                    if artifact_abs and not os.path.isfile(artifact_abs):
                        errors.append(f"missing artifact file: {entry.get('path')}")
                    elif (
                        artifact_abs
                        and phase.get("lock_state") == "locked"
                        and entry.get("hash") != sha256_file(artifact_abs)
                    ):
                        errors.append(
                            f"{pid} artifact_manifest[{current_artifact_id}].hash does not match the locked artifact"
                        )

        gate_result = phase.get("gate_result")
        if gate_result is not None:
            if not isinstance(gate_result, dict):
                errors.append(f"{pid} gate_result must be an object")
            else:
                gate_status = gate_result.get("status")
                if gate_status not in VALID_GATE_STATUSES:
                    errors.append(f"{pid} gate_result.status must be passed or failed")
                if not isinstance(gate_result.get("summary"), str) or not gate_result.get("summary"):
                    errors.append(f"{pid} gate_result.summary must be a non-empty string")
                if not isinstance(gate_result.get("checked_at"), str) or not gate_result.get("checked_at"):
                    errors.append(f"{pid} gate_result.checked_at must be a non-empty string")
                evidence_paths = gate_result.get("evidence_paths")
                if gate_status == "passed":
                    if not isinstance(evidence_paths, list) or not evidence_paths:
                        errors.append(f"{pid} gate_result.evidence_paths must be a non-empty array when passed")
                    else:
                        for evidence_path in evidence_paths:
                            evidence_abs = ensure_relative_state_path(
                                evidence_path,
                                f"{pid} gate_result.evidence_paths",
                                errors,
                            )
                            if evidence_abs and not os.path.isfile(evidence_abs):
                                errors.append(f"missing gate evidence file: {evidence_path}")
                    packet_abs = phase_artifact_abs(pid, "execution-packet.json")
                    if not os.path.isfile(packet_abs):
                        errors.append(f"missing execution packet: {phase_artifact_rel(pid, 'execution-packet.json')}")
                elif evidence_paths is not None and not isinstance(evidence_paths, list):
                    errors.append(f"{pid} gate_result.evidence_paths must be an array when present")

        phase_child_workflow = phase.get("child_workflow")
        if phase_child_workflow is not None:
            if ptype != "execute":
                errors.append(f"{pid} child_workflow is only valid for execute phases")
            mirrored_active_child = (
                isinstance(state_child_workflow, dict)
                and state_child_workflow.get("phase_id") == pid
            )
            if mirrored_active_child:
                validate_phase_child_workflow(phase_child_workflow, f"{pid} child_workflow")
            else:
                validate_child_workflow(phase_child_workflow, f"{pid} child_workflow")

        if phase_status == "superseded":
            superseded_by = phase.get("superseded_by")
            if not isinstance(superseded_by, str) or not superseded_by:
                errors.append(f"{pid} superseded_by must be a non-empty string when superseded")
            elif superseded_by == pid:
                errors.append(f"{pid} superseded_by must point to a different phase")

        artifact_drift = phase.get("artifact_drift")
        if artifact_drift is not None:
            if not isinstance(artifact_drift, dict):
                errors.append(f"{pid} artifact_drift must be an object")
            else:
                if not isinstance(artifact_drift.get("summary"), str) or not artifact_drift.get("summary"):
                    errors.append(f"{pid} artifact_drift.summary must be a non-empty string")
                if parse_timestamp_value(artifact_drift.get("detected_at")) is None:
                    errors.append(f"{pid} artifact_drift.detected_at must be a valid ISO-8601 timestamp")
                if not isinstance(artifact_drift.get("artifacts"), list) or not artifact_drift.get("artifacts"):
                    errors.append(f"{pid} artifact_drift.artifacts must be a non-empty array")

        if ptype == "execute":
            runtime_dir = os.path.join(phase_root, "runtime")
            relay_dir = os.path.join(runtime_dir, "relay")
            adapter = phase.get("adapter")
            expected_adapter = expected_execute_adapter(pid)
            if adapter is None:
                errors.append(f"{pid} is missing execute adapter metadata")
            else:
                if not adapter.get("adapter_id"):
                    errors.append(f"{pid} adapter.adapter_id is required")
                if not adapter.get("adapter_version"):
                    errors.append(f"{pid} adapter.adapter_version is required")
                if adapter.get("relay_root") != expected_adapter["relay_root"]:
                    errors.append(f"{pid} adapter.relay_root does not match pipeline_root-derived path")
                if adapter.get("status_path") != expected_adapter["status_path"]:
                    errors.append(f"{pid} adapter.status_path does not match pipeline_root-derived path")
                for field in ("relay_root", "status_path"):
                    value = adapter.get(field)
                    if isinstance(value, str) and os.path.isabs(value):
                        errors.append(f"{pid} adapter.{field} must be repo-root-relative")
            if not os.path.isdir(runtime_dir):
                errors.append(f"missing expected directory: {runtime_dir}")
            if not os.path.isdir(relay_dir):
                errors.append(f"missing expected directory: {relay_dir}")

    if isinstance(state_child_workflow, dict):
        child_phase_id = state_child_workflow.get("phase_id")
        if child_phase_id not in phase_ids:
            errors.append(f'child_workflow.phase_id "{child_phase_id}" not found in phases')

    if isinstance(automatic_resume, dict) and automatic_resume.get("blocked") and automatic_resume.get("phase_id") not in phase_ids:
        errors.append(f'automatic_resume.phase_id "{automatic_resume.get("phase_id")}" not found in phases')

    if len(in_progress) > 1:
        errors.append("exactly one phase may be in_progress")
    active_when_complete = [
        f"{phase.get('phase_id')} ({phase.get('status')})"
        for phase in phases
        if phase.get("status") in {"pending", "in_progress"}
    ]
    if pipeline_status == "complete" and active_when_complete:
        errors.append(
            "completed pipelines must not leave phases pending or in_progress"
            + (f": {', '.join(active_when_complete)}" if active_when_complete else "")
        )

    current_phase_id = state.get("current_phase_id")
    if current_phase_id is not None:
        if current_phase_id not in phase_ids:
            errors.append(f'current_phase_id "{current_phase_id}" not found in phases')
        elif current_phase_id not in in_progress:
            errors.append(f'current_phase_id "{current_phase_id}" is not marked in_progress')
    elif len(in_progress) == 1:
        errors.append("current_phase_id must be set when a phase is in_progress")

    latest_resume = state.get("latest_resume")
    if latest_resume is not None:
        resume_abs = ensure_relative_state_path(latest_resume, "latest_resume", errors)
        if resume_abs and not os.path.isfile(resume_abs):
            errors.append(f"latest_resume file is missing: {latest_resume}")
        elif resume_abs and os.path.basename(resume_abs) != "resume.md":
            errors.append("latest_resume must point to a resume.md artifact")

    return errors


def rebuild_state_from_records(records):
    rebuilt_state = None
    for record in records:
        rebuilt_state = apply_record(rebuilt_state, record)
        rebuilt_state["updated_at"] = record["ts"]
        enforce_state_budget(rebuilt_state, record["event"])
    if rebuilt_state is None:
        print(f"ERROR: {events_file} does not contain an init_pipeline event", file=sys.stderr)
        sys.exit(1)
    return rebuilt_state


def print_mutation_summary(state, record):
    if record["event"] == "init_pipeline":
        print(
            f'pipeline [{record["event"]}]: id={state["pipeline_id"]} '
            f'status={state["status"]} phases={len(state["phases"])}'
        )
        return

    if record["event"] == "mission_activated":
        print(f'mission [{record["event"]}]: path={record["path"]}')
        return

    if record["event"] == "constraint_set_activated":
        print(f'constraints [{record["event"]}]: path={record["path"]}')
        return

    if record["event"] == "pipeline_completed":
        print(
            f'pipeline [{record["event"]}]: status={state["status"]} '
            f'phases={len(state["phases"])} retrospective=appended'
        )
        return

    phase = find_phase(state, record["phase_id"])
    if record["event"] == "artifact_recorded":
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'artifact={record["artifact_id"]} role={record["role"]} status={phase["status"]}'
        )
        return

    if record["event"] == "child_checkpoint":
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'child_status={record["child_workflow"]["status"]} stale={record["child_workflow"].get("stale", False)}'
        )
        return

    if record["event"] == "phase_completed":
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'type={phase["phase_type"]} status={phase["status"]} latest_resume={state["latest_resume"]}'
        )
        return

    if record["event"] == "superseded":
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'replaced_by={record["replacement_phase_id"]} epoch={state["active_epoch_id"]}'
        )
        return

    if record["event"] == "artifact_drift_detected":
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'drifts={len(record["drifted_artifacts"])} automatic_resume_blocked={state["automatic_resume"]["blocked"]}'
        )
        return

    if record["event"] in {"gate_passed", "gate_failed"}:
        print(
            f'{phase["phase_id"]} [{record["event"]}]: '
            f'type={phase["phase_type"]} gate={record["gate_result"]["status"]}'
        )
        return

    print(
        f'{phase["phase_id"]} [{record["event"]}]: '
        f'type={phase["phase_type"]} status={phase["status"]}'
    )


if rebuild_mode:
    records = load_events(events_file)
    rebuilt_state = rebuild_state_from_records(records)
    drift = validate_state(rebuilt_state)
    if drift:
        for item in drift:
            print(f"DRIFT: {item}", file=sys.stderr)
        sys.exit(1)
    write_json_atomic(state_file, rebuilt_state)
    print(f"Rebuilt {state_file} from {events_file}")
    sys.exit(0)

if validate_mode:
    state = load_json(state_file, "state file", require_object=True)
    drift = validate_state(state)
    if not drift and os.path.exists(events_file):
        replayed_state = rebuild_state_from_records(load_events(events_file))
        if state != replayed_state:
            drift.append("state.json does not match replay of events.ndjson")
    if drift:
        for item in drift:
            print(f"DRIFT: {item}", file=sys.stderr)
        sys.exit(1)
    print("state.json: consistent")
    sys.exit(0)

if not event:
    print("ERROR: --event is required (or use --validate/--rebuild)", file=sys.stderr)
    sys.exit(1)

existing_state = None
if os.path.isfile(state_file):
    existing_state = load_json(state_file, "state file")

ts = utc_now()
record = build_record(existing_state, event, ts)
records = [record]
if record["event"] == "pipeline_completed":
    completion_state = apply_record(copy.deepcopy(existing_state), record)
    completion_state["updated_at"] = record["ts"]
    enforce_state_budget(completion_state, record["event"])
    records.append(build_pipeline_retrospective_record(completion_state, record["ts"]))

updated_state = existing_state
for current_record in records:
    candidate_state = apply_record(
        copy.deepcopy(updated_state) if updated_state is not None else None,
        current_record,
    )
    candidate_state["updated_at"] = current_record["ts"]
    enforce_state_budget(candidate_state, current_record["event"])
    ensure_record_directories(current_record)
    materialize_record(current_record)
    append_event(events_file, current_record)
    updated_state = candidate_state
write_json_atomic(state_file, updated_state)
print_mutation_summary(updated_state, record)
PY
