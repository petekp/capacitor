#!/bin/bash
# Capture a durable snapshot of Claude HUD state for a given project path.
#
# Usage: ./scripts/state-snapshot.sh /path/to/project

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-path>" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for state snapshots" >&2
    exit 1
fi

PROJECT_PATH="$1"
SNAPSHOT_DIR="${HUD_STATE_SNAPSHOT_DIR:-$HOME/.capacitor/hud-state-snapshots}"
mkdir -p "$SNAPSHOT_DIR"

TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
SAFE_PATH="$(printf '%s' "$PROJECT_PATH" | sed 's#[^A-Za-z0-9._-]#-#g' | cut -c1-80)"
if [ -z "$SAFE_PATH" ]; then
    SAFE_PATH="project"
fi

SNAPSHOT_FILE="${SNAPSHOT_DIR}/state-snapshot-${TIMESTAMP}-${SAFE_PATH}.txt"

python3 - "$PROJECT_PATH" "$SNAPSHOT_FILE" <<'PY'
import json
import os
import sys
from collections import deque
from datetime import datetime, timezone

project_input = sys.argv[1]
snapshot_path = sys.argv[2]

def utc_now():
    return datetime.now(timezone.utc)

def fmt_dt(dt):
    if not dt:
        return "n/a"
    return dt.isoformat().replace("+00:00", "Z")

def parse_iso(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except Exception:
        return None

def age_seconds(dt, now):
    if not dt:
        return None
    return int((now - dt).total_seconds())

def normalize_path(path):
    if not path:
        return ""
    expanded = os.path.expanduser(path)
    abs_path = os.path.abspath(expanded)
    if abs_path != "/":
        abs_path = abs_path.rstrip("/")
    if not abs_path:
        return "/"
    return abs_path

def relation(base, candidate):
    if not candidate:
        return None
    if base == candidate:
        return "exact"
    if base == "/":
        if candidate.startswith("/") and candidate != "/":
            return "child"
        return None
    if candidate == "/":
        return "parent"
    if candidate.startswith(base + "/"):
        return "child"
    if base.startswith(candidate + "/"):
        return "parent"
    return None

def file_mtime(path):
    try:
        ts = os.path.getmtime(path)
    except Exception:
        return None
    return datetime.fromtimestamp(ts, timezone.utc)

def is_pid_alive(pid):
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return None
    except OSError:
        return False

now = utc_now()
normalized_project = normalize_path(project_input)
absolute_project = os.path.abspath(os.path.expanduser(project_input))

state_file = os.path.expanduser("~/.capacitor/sessions.json")
lock_dir = os.path.expanduser("~/.claude/sessions")
hook_log = os.environ.get("HUD_HOOK_LOG_FILE", os.path.expanduser("~/.capacitor/hud-hook-events.jsonl"))

state_exists = os.path.isfile(state_file)
lock_dir_exists = os.path.isdir(lock_dir)
hook_log_exists = os.path.isfile(hook_log)

def write_line(out, text=""):
    out.write(text + "\n")

def format_age(dt):
    age = age_seconds(dt, now)
    if age is None:
        return "n/a"
    return str(age)

with open(snapshot_path, "w", encoding="utf-8") as out:
    write_line(out, "State Snapshot")
    write_line(out, f"Created: {fmt_dt(now)}")
    write_line(out, f"Project query: {project_input}")
    write_line(out, f"Project normalized: {normalized_project}")
    write_line(out, f"Project absolute: {absolute_project}")
    write_line(out, "")
    write_line(out, "Files")
    state_mtime = file_mtime(state_file) if state_exists else None
    hook_log_mtime = file_mtime(hook_log) if hook_log_exists else None
    hook_log_size = os.path.getsize(hook_log) if hook_log_exists else None
    write_line(out, f"- sessions.json: {state_file} (exists={state_exists}, mtime={fmt_dt(state_mtime)})")
    write_line(out, f"- lock dir: {lock_dir} (exists={lock_dir_exists})")
    write_line(
        out,
        f"- hook log: {hook_log} (exists={hook_log_exists}, size={hook_log_size}, mtime={fmt_dt(hook_log_mtime)})",
    )
    write_line(out, "")

    session_matches = []
    matched_session_ids = set()

    if state_exists:
        try:
            with open(state_file, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            data = {}
        sessions = data.get("sessions", {}) if isinstance(data, dict) else {}
        if isinstance(sessions, dict):
            for sid, record in sessions.items():
                if not isinstance(record, dict):
                    continue
                cwd = normalize_path(record.get("cwd", ""))
                project_dir = normalize_path(record.get("project_dir", ""))
                match = {}
                rel_cwd = relation(normalized_project, cwd)
                rel_project = relation(normalized_project, project_dir)
                if rel_cwd:
                    match["cwd"] = rel_cwd
                if rel_project:
                    match["project_dir"] = rel_project
                if match:
                    session_matches.append((sid, record, match))
                    matched_session_ids.add(sid)

    write_line(out, f"Matching session records (count={len(session_matches)})")
    if not session_matches:
        write_line(out, "(none)")
    for sid, record, match in session_matches:
        last_event = record.get("last_event") if isinstance(record.get("last_event"), dict) else {}
        transcript_path = record.get("transcript_path") or ""
        transcript_expanded = os.path.expanduser(transcript_path) if transcript_path else ""
        transcript_mtime = file_mtime(transcript_expanded) if transcript_expanded else None
        updated_at = parse_iso(record.get("updated_at", ""))
        state_changed_at = parse_iso(record.get("state_changed_at", ""))

        match_parts = [f"{key}={value}" for key, value in sorted(match.items())]
        write_line(out, f"- session_id: {sid}")
        write_line(out, f"  match: {', '.join(match_parts)}")
        write_line(out, f"  state: {record.get('state', '')}")
        write_line(out, f"  updated_at: {record.get('updated_at', '')} (age_s={format_age(updated_at)})")
        write_line(out, f"  state_changed_at: {record.get('state_changed_at', '')} (age_s={format_age(state_changed_at)})")
        write_line(out, f"  active_subagent_count: {record.get('active_subagent_count', 0)}")
        write_line(out, f"  cwd: {record.get('cwd', '')}")
        write_line(out, f"  project_dir: {record.get('project_dir', '')}")
        write_line(out, f"  transcript_path: {transcript_path}")
        if transcript_path:
            write_line(out, f"  transcript_mtime: {fmt_dt(transcript_mtime)} (age_s={format_age(transcript_mtime)})")
        write_line(out, f"  permission_mode: {record.get('permission_mode', '')}")
        write_line(out, f"  working_on: {record.get('working_on', '')}")
        if last_event:
            write_line(
                out,
                "  last_event: "
                + f"name={last_event.get('hook_event_name', '')} "
                + f"at={last_event.get('at', '')} "
                + f"tool_name={last_event.get('tool_name', '')} "
                + f"tool_use_id={last_event.get('tool_use_id', '')} "
                + f"notification_type={last_event.get('notification_type', '')} "
                + f"trigger={last_event.get('trigger', '')} "
                + f"stop_hook_active={last_event.get('stop_hook_active', '')} "
                + f"source={last_event.get('source', '')} "
                + f"reason={last_event.get('reason', '')} "
                + f"agent_id={last_event.get('agent_id', '')} "
                + f"agent_transcript_path={last_event.get('agent_transcript_path', '')}"
            )
        write_line(out, "")

    lock_matches = []
    if lock_dir_exists:
        try:
            entries = sorted(os.listdir(lock_dir))
        except Exception:
            entries = []
        for entry in entries:
            if not entry.endswith(".lock"):
                continue
            lock_path = os.path.join(lock_dir, entry)
            if not os.path.isdir(lock_path):
                continue
            meta_path = os.path.join(lock_path, "meta.json")
            pid_path = os.path.join(lock_path, "pid")
            meta = {}
            if os.path.isfile(meta_path):
                try:
                    with open(meta_path, "r", encoding="utf-8") as fh:
                        meta = json.load(fh)
                except Exception:
                    meta = {}
            lock_project = normalize_path(meta.get("path", "")) if isinstance(meta, dict) else ""
            match_type = relation(normalized_project, lock_project)
            if not match_type:
                continue

            pid = None
            if isinstance(meta, dict):
                raw_pid = meta.get("pid")
                try:
                    pid = int(raw_pid)
                except Exception:
                    pid = None
            if isinstance(pid, int) and pid <= 0:
                pid = None
            if pid is None and os.path.isfile(pid_path):
                try:
                    with open(pid_path, "r", encoding="utf-8") as fh:
                        pid = int(fh.read().strip() or "0")
                except Exception:
                    pid = None
            lock_matches.append(
                {
                    "lock_dir": lock_path,
                    "meta_path": meta_path,
                    "pid_path": pid_path,
                    "match": match_type,
                    "pid": pid,
                    "pid_alive": is_pid_alive(pid),
                    "path": meta.get("path", "") if isinstance(meta, dict) else "",
                    "proc_started": meta.get("proc_started", "") if isinstance(meta, dict) else "",
                    "created": meta.get("created", "") if isinstance(meta, dict) else "",
                    "meta_mtime": fmt_dt(file_mtime(meta_path)),
                }
            )

    write_line(out, f"Lock directories (count={len(lock_matches)})")
    if not lock_matches:
        write_line(out, "(none)")
    for info in lock_matches:
        write_line(out, f"- lock_dir: {info['lock_dir']}")
        write_line(out, f"  match: {info['match']}")
        write_line(out, f"  path: {info['path']}")
        write_line(out, f"  pid: {info['pid']} (alive={info['pid_alive']})")
        write_line(out, f"  proc_started: {info['proc_started']}")
        write_line(out, f"  created: {info['created']}")
        write_line(out, f"  meta_mtime: {info['meta_mtime']}")
        write_line(out, "")

    max_log_lines = 400
    max_output_events = 120
    log_events = []
    if hook_log_exists:
        try:
            with open(hook_log, "r", encoding="utf-8") as fh:
                lines = deque(fh, maxlen=max_log_lines)
        except Exception:
            lines = deque()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except Exception:
                continue
            if not isinstance(payload, dict):
                continue
            sid = payload.get("session_id", "")
            cwd = normalize_path(payload.get("cwd", ""))
            project_dir = normalize_path(payload.get("project_dir", ""))
            if (
                relation(normalized_project, cwd)
                or relation(normalized_project, project_dir)
                or (sid in matched_session_ids)
            ):
                log_events.append(payload)

    if len(log_events) > max_output_events:
        log_events = log_events[-max_output_events:]

    write_line(out, f"Recent hook events (matching; scanned_last={max_log_lines}, shown={len(log_events)})")
    if not log_events:
        write_line(out, "(none)")
    for event in log_events:
        write_line(
            out,
            " - "
            + f"{event.get('ts', '')} "
            + f"session_id={event.get('session_id', '')} "
            + f"action={event.get('action', '')} "
            + f"event={event.get('event', '')} "
            + f"state={event.get('state', '')} "
            + f"cwd={event.get('cwd', '')} "
            + f"project_dir={event.get('project_dir', '')} "
            + f"notification_type={event.get('notification_type', '')} "
            + f"trigger={event.get('trigger', '')} "
            + f"stop_hook_active={event.get('stop_hook_active', '')} "
            + f"tool_name={event.get('tool_name', '')} "
            + f"tool_use_id={event.get('tool_use_id', '')} "
            + f"source={event.get('source', '')} "
            + f"reason={event.get('reason', '')} "
            + f"subagent_delta={event.get('subagent_delta', '')} "
            + f"write_status={event.get('write_status', '')} "
            + f"skip_reason={event.get('skip_reason', '')}"
        )

PY

echo "$SNAPSHOT_FILE"
