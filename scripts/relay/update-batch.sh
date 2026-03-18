#!/usr/bin/env bash
# update-batch.sh - Deterministic state mutation for manage-codex batch.json
#
# Eliminates LLM bookkeeping: the orchestrator calls this after each phase
# transition instead of manually editing batch.json.
#
# Usage:
#   ./scripts/relay/update-batch.sh --slice slice-001 --event attempt_started
#   ./scripts/relay/update-batch.sh --slice slice-001 --event impl_dispatched
#   ./scripts/relay/update-batch.sh --slice slice-001 --event review_clean
#   ./scripts/relay/update-batch.sh --event converge_complete
#   ./scripts/relay/update-batch.sh --validate
#   ./scripts/relay/update-batch.sh --rebuild
#
# Events:
#   attempt_started      - Record a worker attempt before dispatch
#   impl_dispatched      - Record a completed implementation handoff
#   review_clean         - Set slice status to "done", record verdict
#   review_rejected      - Increment review_rejections for the slice
#   converge_complete    - Set phase to "complete", all slices to "done"
#   converge_failed      - Increment convergence_attempts
#   analytically_resolved - Slice resolved by analysis (no code change needed)
#   orchestrator_direct   - Orchestrator fixed directly (code changed, no worker)
#   add_slice             - Add a new slice (requires --task and --type)
#
# Options:
#   --slice ID         - Target slice ID (required for slice-level events)
#   --event EVENT      - State transition event (required unless --validate/--rebuild)
#   --handoff PATH     - Archive handoff file after update
#   --summary TEXT     - Brief note recorded in the slice
#   --task TEXT        - Task description (for add_slice)
#   --type TYPE        - Slice type: implement|review|converge (for add_slice)
#   --scope DIRS       - Comma-separated file_scope (optional for add_slice)
#   --skills LIST      - Comma-separated domain skills (optional for add_slice)
#   --verification CMD - Verification command; repeat to add multiple commands
#   --criteria TEXT    - Success criteria text (optional for add_slice)
#   --validate         - Check batch.json consistency, exit 0 if clean, 1 if drift
#   --rebuild          - Rebuild batch.json from .relay/plan.json + events.ndjson
#   --batch PATH       - Path to batch.json (default: .relay/batch.json)

set -euo pipefail

BATCH_FILE=".relay/batch.json"
ARCHIVE_DIR=".relay/archive"
SLICE=""
EVENT=""
HANDOFF=""
SUMMARY=""
TASK=""
SLICE_TYPE=""
SCOPE=""
SKILLS=""
VERIFICATION=""
CRITERIA=""
VALIDATE=false
REBUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slice)    SLICE="$2"; shift 2 ;;
    --event)    EVENT="$2"; shift 2 ;;
    --handoff)  HANDOFF="$2"; shift 2 ;;
    --summary)  SUMMARY="$2"; shift 2 ;;
    --task)     TASK="$2"; shift 2 ;;
    --type)     SLICE_TYPE="$2"; shift 2 ;;
    --scope)    SCOPE="$2"; shift 2 ;;
    --skills)   SKILLS="$2"; shift 2 ;;
    --verification)
      if [[ -n "$VERIFICATION" ]]; then
        VERIFICATION+=$'\n'
      fi
      VERIFICATION+="$2"
      shift 2
      ;;
    --criteria) CRITERIA="$2"; shift 2 ;;
    --validate) VALIDATE=true; shift ;;
    --rebuild)  REBUILD=true; shift ;;
    --batch)    BATCH_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if $VALIDATE && $REBUILD; then
  echo "ERROR: --validate and --rebuild are mutually exclusive" >&2
  exit 1
fi

python3 - "$BATCH_FILE" "$ARCHIVE_DIR" "$SLICE" "$EVENT" "$HANDOFF" "$SUMMARY" "$TASK" "$SLICE_TYPE" "$SCOPE" "$SKILLS" "$VERIFICATION" "$CRITERIA" "$VALIDATE" "$REBUILD" <<'PY'
import json
import os
import shutil
import sys
from copy import deepcopy
from datetime import datetime, timezone


batch_file = sys.argv[1]
archive_dir = sys.argv[2]
slice_id = sys.argv[3]
event = sys.argv[4]
handoff = sys.argv[5]
summary = sys.argv[6]
task = sys.argv[7]
slice_type = sys.argv[8]
scope = sys.argv[9]
skills = sys.argv[10]
verification = sys.argv[11]
criteria = sys.argv[12]
validate_mode = sys.argv[13] == "true"
rebuild_mode = sys.argv[14] == "true"

VALID_TYPES = {"implement", "review", "converge"}
SLICE_LEVEL_EVENTS = {
    "attempt_started",
    "impl_dispatched",
    "review_clean",
    "review_rejected",
    "analytically_resolved",
    "orchestrator_direct",
}
CONVERGENCE_EVENTS = {"converge_complete", "converge_failed"}
NORMALIZED_EVENTS = {
    "attempt_started",
    "attempt_finished",
    "review_recorded",
    "converge_started",
    "slice_added",
    "analytically_resolved",
    "orchestrator_direct",
}

relay_dir = os.path.dirname(batch_file) or os.path.normpath(os.path.join(archive_dir, os.pardir))
events_file = os.path.join(os.path.normpath(os.path.join(archive_dir, os.pardir)), "events.ndjson")
plan_file = os.path.join(relay_dir, "plan.json")


def utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_csv(value):
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_lines(value):
    return [line.strip() for line in value.splitlines() if line.strip()]


def load_json(path, description):
    try:
        with open(path) as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: {description} {path} not found", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {description} {path} is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(1)


def write_json_atomic(path, payload):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
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
            records.append(record)
    return records


def append_event(path, record):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")))
        fh.write("\n")


def next_slice_id(batch):
    max_num = 0
    for existing in batch.get("slices", []):
        parts = existing.get("id", "").split("-", 1)
        if len(parts) != 2:
            continue
        try:
            max_num = max(max_num, int(parts[1]))
        except ValueError:
            continue
    return f"slice-{max_num + 1:03d}"


def find_slice(batch, sid):
    for current in batch.get("slices", []):
        if current.get("id") == sid:
            return current
    print(f"ERROR: slice {sid} not found in batch.json", file=sys.stderr)
    sys.exit(1)


def next_pending(batch):
    for current in batch.get("slices", []):
        if current.get("status") == "pending" and current.get("type", "implement") != "converge":
            return current["id"]
    return None


def clear_attempt_flag(slice_state):
    slice_state.pop("attempt_in_progress", None)


def advance_after_resolution(batch):
    nxt = next_pending(batch)
    if nxt:
        batch["current_slice"] = nxt
    else:
        batch["phase"] = "converge"
        batch["current_slice"] = ""


def build_add_slice_payload(batch, ts):
    if not task or not slice_type:
        print("ERROR: add_slice requires --task and --type", file=sys.stderr)
        sys.exit(1)
    if slice_type not in VALID_TYPES:
        print(
            f"ERROR: invalid slice type \"{slice_type}\" (expected one of: implement, review, converge)",
            file=sys.stderr,
        )
        sys.exit(1)
    return {
        "ts": ts,
        "event": "slice_added",
        "mutation": "add_slice",
        "slice": next_slice_id(batch),
        "summary": summary or task,
        "task": task,
        "slice_type": slice_type,
        "file_scope": parse_csv(scope),
        "domain_skills": parse_csv(skills),
        "verification_commands": parse_lines(verification),
        "success_criteria": criteria,
    }


def build_record(batch, cli_event, ts):
    if cli_event in SLICE_LEVEL_EVENTS and not slice_id:
        print(f"ERROR: --slice is required for {cli_event}", file=sys.stderr)
        sys.exit(1)

    if cli_event == "attempt_started":
        find_slice(batch, slice_id)
        return {
            "ts": ts,
            "event": "attempt_started",
            "mutation": "attempt_started",
            "slice": slice_id,
            "summary": summary,
        }
    if cli_event == "impl_dispatched":
        find_slice(batch, slice_id)
        return {
            "ts": ts,
            "event": "attempt_finished",
            "mutation": "impl_dispatched",
            "slice": slice_id,
            "summary": summary,
        }
    if cli_event in {"review_clean", "review_rejected"}:
        find_slice(batch, slice_id)
        default_summary = "CLEAN" if cli_event == "review_clean" else "ISSUES FOUND"
        return {
            "ts": ts,
            "event": "review_recorded",
            "mutation": cli_event,
            "slice": slice_id,
            "summary": summary or default_summary,
        }
    if cli_event in CONVERGENCE_EVENTS:
        return {
            "ts": ts,
            "event": "converge_started",
            "mutation": cli_event,
            "summary": summary,
        }
    if cli_event == "add_slice":
        return build_add_slice_payload(batch, ts)
    if cli_event in {"analytically_resolved", "orchestrator_direct"}:
        find_slice(batch, slice_id)
        return {
            "ts": ts,
            "event": cli_event,
            "mutation": cli_event,
            "slice": slice_id,
            "summary": summary,
        }
    print(f"ERROR: unknown event \"{cli_event}\"", file=sys.stderr)
    sys.exit(1)


def apply_record(batch, record):
    record_event = record.get("event")
    mutation = record.get("mutation", record_event)
    ts = record.get("ts") or utc_now()
    record_slice = record.get("slice", "")
    record_summary = record.get("summary", "")

    if record_event not in NORMALIZED_EVENTS:
        print(f"ERROR: unknown ledger event \"{record_event}\"", file=sys.stderr)
        sys.exit(1)

    if record_event == "attempt_started":
        current = find_slice(batch, record_slice)
        if not current.get("attempt_in_progress"):
            current["impl_attempts"] = current.get("impl_attempts", 0) + 1
        current["attempt_in_progress"] = True
        current["last_updated"] = ts
        batch["phase"] = "implement"
        batch["current_slice"] = record_slice
        return

    if record_event == "attempt_finished":
        current = find_slice(batch, record_slice)
        if not current.get("attempt_in_progress"):
            current["impl_attempts"] = current.get("impl_attempts", 0) + 1
        clear_attempt_flag(current)
        current["last_updated"] = ts
        if record_summary:
            current["verification"] = record_summary
        batch["phase"] = "implement"
        batch["current_slice"] = record_slice
        return

    if record_event == "review_recorded":
        current = find_slice(batch, record_slice)
        clear_attempt_flag(current)
        current["last_updated"] = ts
        if mutation == "review_clean":
            current["status"] = "done"
            current["review"] = record_summary or "CLEAN"
            advance_after_resolution(batch)
            return
        if mutation == "review_rejected":
            current["review_rejections"] = current.get("review_rejections", 0) + 1
            current["review"] = record_summary or "ISSUES FOUND"
            return
        print(f"ERROR: unsupported review mutation \"{mutation}\"", file=sys.stderr)
        sys.exit(1)

    if record_event == "converge_started":
        if mutation == "converge_complete":
            for current in batch.get("slices", []):
                current["status"] = "done"
                current["last_updated"] = ts
                clear_attempt_flag(current)
            batch["phase"] = "complete"
            batch["current_slice"] = ""
            return
        if mutation == "converge_failed":
            batch["convergence_attempts"] = batch.get("convergence_attempts", 0) + 1
            if record_summary:
                batch["last_convergence_note"] = record_summary
            return
        print(f"ERROR: unsupported convergence mutation \"{mutation}\"", file=sys.stderr)
        sys.exit(1)

    if record_event == "slice_added":
        new_slice = {
            "id": record["slice"],
            "type": record["slice_type"],
            "task": record["task"],
            "file_scope": list(record.get("file_scope", [])),
            "domain_skills": list(record.get("domain_skills", [])),
            "verification_commands": list(record.get("verification_commands", [])),
            "success_criteria": record.get("success_criteria", ""),
            "status": "pending",
            "impl_attempts": 0,
            "review_rejections": 0,
            "created": ts,
        }
        batch.setdefault("slices", []).append(new_slice)
        return

    if record_event == "analytically_resolved":
        current = find_slice(batch, record_slice)
        clear_attempt_flag(current)
        current["status"] = "done"
        current["resolution"] = "analytically_resolved"
        current["review"] = record_summary or "Resolved by analysis - no code change needed"
        current["last_updated"] = ts
        advance_after_resolution(batch)
        return

    if record_event == "orchestrator_direct":
        current = find_slice(batch, record_slice)
        clear_attempt_flag(current)
        current["status"] = "done"
        current["resolution"] = "orchestrator_direct"
        current["review"] = record_summary or "Fixed directly by orchestrator"
        current["last_updated"] = ts
        advance_after_resolution(batch)
        return


def archive_handoff_if_present(batch):
    if not handoff or not os.path.isfile(handoff):
        return

    os.makedirs(archive_dir, exist_ok=True)
    batch_id = batch.get("batch_id", "unknown")
    attempt = 0
    if slice_id:
        current = find_slice(batch, slice_id)
        attempt = current.get("impl_attempts", 0)
    archive_name = f"{batch_id}-{slice_id}-{event}-{attempt}.md"
    archive_path = os.path.join(archive_dir, archive_name)
    shutil.copy2(handoff, archive_path)
    print(f"Archived: {archive_path}")


def print_mutation_summary(batch, record):
    if record.get("event") == "slice_added":
        print(f"Added {record['slice']}: {record['task'][:60]}")
        return
    if slice_id:
        current = find_slice(batch, slice_id)
        print(
            f"{slice_id} [{event}]: impl={current.get('impl_attempts', 0)} "
            f"rej={current.get('review_rejections', 0)} status={current['status']}"
        )
        return
    if event.startswith("converge"):
        print(f"converge [{event}]: attempts={batch.get('convergence_attempts', 0)} phase={batch.get('phase', '')}")


def validate_batch(batch):
    errors = []
    slice_ids = {current["id"] for current in batch.get("slices", [])}
    current_slice = batch.get("current_slice", "")
    if current_slice and current_slice not in slice_ids:
        errors.append(f"current_slice \"{current_slice}\" not in slice list")
    for current in batch.get("slices", []):
        if current.get("type", "implement") not in VALID_TYPES:
            errors.append(f"{current['id']} has invalid type {current.get('type')!r}")
        if (
            current.get("status") == "done"
            and current.get("impl_attempts", 0) == 0
            and current.get("type", "implement") not in ("converge", "review")
            and current.get("resolution") not in ("analytically_resolved", "orchestrator_direct")
        ):
            errors.append(f"{current['id']} is done but has 0 impl_attempts")
        if current.get("status") == "done" and current.get("attempt_in_progress"):
            errors.append(f"{current['id']} is done but still marked attempt_in_progress")
    return errors


if validate_mode:
    batch = load_json(batch_file, "batch file")
    drift = validate_batch(batch)
    if drift:
        for item in drift:
            print(f"DRIFT: {item}", file=sys.stderr)
        sys.exit(1)
    print("batch.json: consistent")
    sys.exit(0)

if rebuild_mode:
    plan = load_json(plan_file, "plan file")
    rebuilt = deepcopy(plan)
    for record in load_events(events_file):
        apply_record(rebuilt, record)
    write_json_atomic(batch_file, rebuilt)
    print(f"Rebuilt {batch_file} from {plan_file} + {events_file}")
    sys.exit(0)

if not os.path.isfile(batch_file):
    print(f"ERROR: {batch_file} not found", file=sys.stderr)
    sys.exit(1)

if not event:
    print("ERROR: --event is required (or use --validate/--rebuild)", file=sys.stderr)
    sys.exit(1)

batch = load_json(batch_file, "batch file")
ts = utc_now()
record = build_record(batch, event, ts)
append_event(events_file, record)
apply_record(batch, record)
archive_handoff_if_present(batch)
write_json_atomic(batch_file, batch)
print_mutation_summary(batch, record)
PY
