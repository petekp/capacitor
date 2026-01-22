#!/bin/bash
# Claude HUD State Tracker Hook v3.1.0
# All session data lives in ~/.capacitor/ (sidecar purity):
# - State file: ~/.capacitor/sessions.json
# - Lock directories: ~/.capacitor/sessions/
# - File activity: ~/.capacitor/file-activity.json
#
# We never write to ~/.claude/ (Claude's namespace).
#
# Requires jq or python3.

set -o pipefail

# Skip if this is a summary generation subprocess (prevents recursive hook pollution)
if [ "${HUD_SUMMARY_GEN:-}" = "1" ]; then
  cat > /dev/null
  exit 0
fi

STATE_FILE="$HOME/.capacitor/sessions.json"
ACTIVITY_FILE="$HOME/.capacitor/file-activity.json"
STATE_DIR="$(dirname "$STATE_FILE")"
ACTIVITY_DIR="$(dirname "$ACTIVITY_FILE")"
LOG_FILE="$HOME/.capacitor/hud-hook-debug.log"
LOCK_DIR="$HOME/.capacitor/sessions"
STATE_LOCK_DIR="${STATE_FILE}.lock"
ACTIVITY_LOCK_DIR="${ACTIVITY_FILE}.lock"

mkdir -p "$STATE_DIR" "$ACTIVITY_DIR" "$LOCK_DIR" "$(dirname "$LOG_FILE")"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0
export HUD_HOOK_INPUT="$INPUT"

HAVE_JQ=""
HAVE_PY=""
command -v jq >/dev/null 2>&1 && HAVE_JQ="1"
command -v python3 >/dev/null 2>&1 && HAVE_PY="1"
[ -z "$HAVE_JQ" ] && [ -z "$HAVE_PY" ] && exit 0

log() {
  printf '%s | %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "$LOG_FILE"
}

json_get() {
  local jq_expr="$1"
  local py_paths="$2"
  if [ -n "$HAVE_JQ" ]; then
    printf '%s' "$HUD_HOOK_INPUT" | jq -r "$jq_expr" 2>/dev/null
    return 0
  fi
  if [ -n "$HAVE_PY" ]; then
    python3 - "$py_paths" <<'PY'
import json
import os
import sys

paths = [p for p in sys.argv[1].split(",") if p]
raw = os.environ.get("HUD_HOOK_INPUT", "")
try:
    data = json.loads(raw) if raw else {}
except Exception:
    data = {}

def get_path(obj, path):
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur

for path in paths:
    val = get_path(data, path)
    if val is None:
        continue
    if isinstance(val, (dict, list)):
        print(json.dumps(val))
    else:
        print(val)
    sys.exit(0)
print("")
PY
    return 0
  fi
  echo ""
}

normalize_path() {
  local path="$1"
  if [ -z "$path" ]; then
    echo ""
    return
  fi
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  if [ -z "$path" ]; then
    echo "/"
  else
    echo "$path"
  fi
}

timestamp_iso() {
  if [ -n "$HAVE_PY" ]; then
    python3 - <<'PY'
import datetime
print(datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")
PY
  else
    date -u +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

timestamp_ms() {
  if [ -n "$HAVE_PY" ]; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

get_process_start_time() {
  local pid="$1"
  local lstart
  lstart=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  local epoch
  epoch=$(LC_ALL=C date -j -f "%c" "$lstart" +%s 2>/dev/null) || {
    epoch=$(LC_ALL=C date -d "$lstart" +%s 2>/dev/null) || return 1
  }
  echo "$epoch"
}

compute_lock_hash() {
  local normalized
  normalized=$(normalize_path "$1")
  if command -v md5 >/dev/null 2>&1; then
    md5 -q -s "$normalized"
  elif command -v md5sum >/dev/null 2>&1; then
    echo -n "$normalized" | md5sum | cut -d' ' -f1
  else
    log "ERROR: md5 or md5sum not available; cannot create lock for $normalized"
    echo ""
  fi
}

write_lock_metadata() {
  local output_file="$1"
  local pid="$2"
  local path="$3"
  local handoff_from="$4"
  local proc_started
  proc_started=$(get_process_start_time "$pid" 2>/dev/null || true)
  local created_ms
  created_ms=$(timestamp_ms)

  if [ -n "$HAVE_PY" ]; then
    python3 - "$output_file" "$pid" "$path" "$proc_started" "$created_ms" "$handoff_from" <<'PY'
import json
import sys

output_file, pid, path, proc_started, created_ms, handoff_from = sys.argv[1:7]

data = {"pid": int(pid), "path": path, "created": int(created_ms)}
if proc_started:
    data["proc_started"] = int(proc_started)
if handoff_from:
    data["handoff_from"] = int(handoff_from)

with open(output_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
  else
    if [ -n "$proc_started" ]; then
      if [ -n "$handoff_from" ]; then
        jq -n --argjson pid "$pid" \
              --argjson proc_started "$proc_started" \
              --argjson created "$created_ms" \
              --arg path "$path" \
              --argjson handoff_from "$handoff_from" \
              '{pid:$pid, proc_started:$proc_started, created:$created, path:$path, handoff_from:$handoff_from}' > "$output_file"
      else
        jq -n --argjson pid "$pid" \
              --argjson proc_started "$proc_started" \
              --argjson created "$created_ms" \
              --arg path "$path" \
              '{pid:$pid, proc_started:$proc_started, created:$created, path:$path}' > "$output_file"
      fi
    else
      if [ -n "$handoff_from" ]; then
        jq -n --argjson pid "$pid" \
              --argjson created "$created_ms" \
              --arg path "$path" \
              --argjson handoff_from "$handoff_from" \
              '{pid:$pid, created:$created, path:$path, handoff_from:$handoff_from}' > "$output_file"
      else
        jq -n --argjson pid "$pid" \
              --argjson created "$created_ms" \
              --arg path "$path" \
              '{pid:$pid, created:$created, path:$path}' > "$output_file"
      fi
    fi
  fi
}

is_claude_process() {
  local pid="$1"
  local proc_name proc_cmd

  proc_name=$(ps -p "$pid" -o comm= 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$proc_name" == *claude* ]]; then
    return 0
  fi

  proc_cmd=$(ps -p "$pid" -o args= 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$proc_cmd" == *claude* ]]; then
    return 0
  fi

  return 1
}

is_legacy_lock_stale() {
  local lock_dir="$1"
  local meta_file="$lock_dir/meta.json"
  [ ! -f "$meta_file" ] && return 1

  if [ -n "$HAVE_PY" ]; then
    python3 - "$meta_file" "$lock_dir" <<'PY'
import json
import os
import sys
import time
import datetime

meta_file, lock_dir = sys.argv[1:3]
try:
    meta = json.load(open(meta_file, "r", encoding="utf-8"))
except Exception:
    sys.exit(1)

if meta.get("proc_started") is not None:
    sys.exit(1)

created = meta.get("created") or meta.get("started")
now_ms = int(time.time() * 1000)

def to_ms(value):
    if isinstance(value, (int, float)):
        value = int(value)
        return value * 1000 if value < 1_000_000_000_000 else value
    if isinstance(value, str):
        try:
            dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return int(dt.timestamp() * 1000)
        except Exception:
            return None
    return None

created_ms = to_ms(created)
if created_ms is None:
    try:
        created_ms = int(os.path.getmtime(lock_dir) * 1000)
    except Exception:
        created_ms = None

if created_ms is None:
    sys.exit(1)

age_ms = now_ms - created_ms
sys.exit(0 if age_ms > 86_400_000 else 1)
PY
    return $?
  fi

  local proc_started
  proc_started=$(jq -r '.proc_started // empty' "$meta_file" 2>/dev/null)
  [ -n "$proc_started" ] && return 1

  local created
  created=$(jq -r '.created // .started // empty' "$meta_file" 2>/dev/null)
  local now
  now=$(date +%s)

  if [[ "$created" =~ ^[0-9]+$ ]]; then
    local created_s
    if [ "$created" -ge 1000000000000 ]; then
      created_s=$((created / 1000))
    else
      created_s=$created
    fi
    local age_s=$((now - created_s))
    [ "$age_s" -gt 86400 ] && return 0
  fi

  local mtime_s
  mtime_s=$(stat -f %m "$lock_dir" 2>/dev/null || echo "")
  if [ -n "$mtime_s" ]; then
    local age_s=$((now - mtime_s))
    [ "$age_s" -gt 86400 ] && return 0
  fi

  return 1
}

with_state_lock() (
  local timeout=50
  local attempt=0

  while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
    ((attempt++))
    if [ $attempt -ge $timeout ]; then
      if [ -d "$STATE_LOCK_DIR" ]; then
        local owner_pid owner_proc_started should_break=false
        owner_pid=$(cat "$STATE_LOCK_DIR/owner_pid" 2>/dev/null)

        if [ -n "$owner_pid" ] && [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
          if ! kill -0 "$owner_pid" 2>/dev/null; then
            should_break=true
            log "WARNING: Breaking stale lock (owner PID $owner_pid dead)"
          else
            owner_proc_started=$(cat "$STATE_LOCK_DIR/owner_proc_started" 2>/dev/null)
            if [ -n "$owner_proc_started" ]; then
              actual_start=$(get_process_start_time "$owner_pid" 2>/dev/null)
              if [ -n "$actual_start" ] && [ "$actual_start" != "$owner_proc_started" ]; then
                should_break=true
                log "WARNING: Breaking stale lock (PID $owner_pid reused)"
              fi
            fi
          fi
        else
          if command -v stat >/dev/null 2>&1; then
            local lock_mtime current_time lock_age
            current_time=$(date +%s)
            lock_mtime=$(stat -f %m "$STATE_LOCK_DIR" 2>/dev/null || echo "$current_time")
            lock_age=$((current_time - lock_mtime))
            if [ $lock_age -gt 10 ]; then
              should_break=true
              log "WARNING: Breaking stale lock (no valid owner, age: ${lock_age}s)"
            fi
          fi
        fi

        if [ "$should_break" = "true" ]; then
          rm -rf "$STATE_LOCK_DIR" 2>/dev/null
          if mkdir "$STATE_LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$STATE_LOCK_DIR/owner_pid"
            get_process_start_time "$$" > "$STATE_LOCK_DIR/owner_proc_started" 2>/dev/null
            trap 'rm -rf "$STATE_LOCK_DIR" 2>/dev/null' EXIT
            "$@"
            exit $?
          fi
        fi
      fi
      log "ERROR: Failed to acquire state lock after 5 seconds"
      exit 1
    fi
    sleep 0.1
  done

  echo "$$" > "$STATE_LOCK_DIR/owner_pid"
  get_process_start_time "$$" > "$STATE_LOCK_DIR/owner_proc_started" 2>/dev/null
  trap 'rm -rf "$STATE_LOCK_DIR" 2>/dev/null' EXIT

  "$@"
)

ensure_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"version":3,"sessions":{}}' > "$STATE_FILE"
    return 0
  fi
  if [ -n "$HAVE_JQ" ]; then
    jq -e . "$STATE_FILE" >/dev/null 2>&1 || echo '{"version":3,"sessions":{}}' > "$STATE_FILE"
  else
    python3 - "$STATE_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        json.load(fh)
except Exception:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"version": 3, "sessions": {}}, fh)
PY
  fi
}

get_session_field() {
  local sid="$1"
  local field="$2"
  [ ! -f "$STATE_FILE" ] && return 0
  if [ -n "$HAVE_JQ" ]; then
    jq -r --arg sid "$sid" ".sessions[$sid].$field // empty" "$STATE_FILE" 2>/dev/null
  else
    python3 - "$STATE_FILE" "$sid" "$field" <<'PY'
import json
import sys

path, sid, field = sys.argv[1:4]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
rec = data.get("sessions", {}).get(sid, {})
val = rec.get(field)
if val is None:
    print("")
elif isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val)
PY
  fi
}

update_state() {
  local sid="$1"
  local action="$2"
  local new_state="$3"
  local cwd="$4"
  local timestamp="$5"
  local event_name="$6"
  local tool_name="$7"

  _update_state_inner() {
    if [ -n "$HAVE_PY" ]; then
      python3 - "$STATE_FILE" "$sid" "$action" "$new_state" "$cwd" "$timestamp" "$event_name" "$tool_name" <<'PY'
import json
import sys

state_file, sid, action, new_state, cwd, ts, event_name, tool_name = sys.argv[1:9]

base = {"version": 3, "sessions": {}}
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
        if isinstance(data, dict):
            base.update(data)
except Exception:
    data = base

sessions = base.get("sessions")
if not isinstance(sessions, dict):
    sessions = {}
base["sessions"] = sessions

if action == "delete":
    sessions.pop(sid, None)
else:
    rec = sessions.get(sid)
    if not isinstance(rec, dict):
        rec = {}

    old_state = rec.get("state")
    state_changed = False

    if action == "heartbeat":
        if "state" not in rec and new_state:
            rec["state"] = new_state
            state_changed = True
    else:
        if new_state and new_state != old_state:
            rec["state"] = new_state
            state_changed = True

    if cwd:
        rec["cwd"] = cwd
    else:
        rec.setdefault("cwd", "")

    rec["session_id"] = sid
    rec["updated_at"] = ts

    # v3: Track when state actually changed
    if state_changed or "state_changed_at" not in rec:
        rec["state_changed_at"] = ts

    # v3: Record the last event for debugging
    if event_name:
        last_event = {"event": event_name, "timestamp": ts}
        if tool_name:
            last_event["tool"] = tool_name
        rec["last_event"] = last_event

    sessions[sid] = rec

base["version"] = 3

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(base, fh, indent=2)
PY
    else
      local tmp_file
      tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
      if [ "$action" = "delete" ]; then
        jq --arg sid "$sid" 'del(.sessions[$sid])' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
      else
        if [ "$action" = "heartbeat" ]; then
          jq --arg sid "$sid" \
             --arg ts "$timestamp" \
             --arg event "$event_name" \
             --arg tool "$tool_name" \
             '.version = 3
              | .sessions = (.sessions // {})
              | if .sessions[$sid] then
                  .sessions[$sid].updated_at = $ts
                  | .sessions[$sid].last_event = (if $event != "" then {event: $event, timestamp: $ts} + (if $tool != "" then {tool: $tool} else {} end) else .sessions[$sid].last_event end)
                else . end' \
             "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
        else
          jq --arg sid "$sid" \
             --arg state "$new_state" \
             --arg cwd "$cwd" \
             --arg ts "$timestamp" \
             --arg event "$event_name" \
             --arg tool "$tool_name" \
             '.version = 3
              | .sessions = (.sessions // {})
              | .sessions[$sid] = ((.sessions[$sid] // {}) + {session_id: $sid, state: $state, updated_at: $ts, state_changed_at: $ts})
              | if $cwd != "" then .sessions[$sid].cwd = $cwd else . end
              | if $event != "" then .sessions[$sid].last_event = ({event: $event, timestamp: $ts} + (if $tool != "" then {tool: $tool} else {} end)) else . end' \
             "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
        fi
      fi
    fi
  }

  if ! with_state_lock _update_state_inner; then
    log "ERROR: Failed to update state (lock timeout), session=$sid"
  fi
}

record_file_activity() {
  local sid="$1"
  local cwd="$2"
  local file_path="$3"
  local tool_name="$4"
  local timestamp="$5"

  [ -z "$sid" ] && return 0
  [ -z "$file_path" ] && return 0

  if [[ "$file_path" != /* ]]; then
    file_path="$cwd/$file_path"
  fi

  if [ -e "$file_path" ] || [ -e "$(dirname "$file_path")" ]; then
    local canonical
    canonical=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P)/$(basename "$file_path")
    if [ -n "$canonical" ]; then
      file_path="$canonical"
    fi
  fi

  if [ ! -f "$ACTIVITY_FILE" ]; then
    echo '{"version":1,"sessions":{}}' > "$ACTIVITY_FILE"
  fi

  _record_activity_inner() {
    if [ -n "$HAVE_PY" ]; then
      python3 - "$ACTIVITY_FILE" "$sid" "$cwd" "$file_path" "$tool_name" "$timestamp" <<'PY'
import json
import sys

path, sid, cwd, file_path, tool_name, ts = sys.argv[1:7]

base = {"version": 1, "sessions": {}}
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
        if isinstance(data, dict):
            base.update(data)
except Exception:
    data = base

sessions = base.get("sessions")
if not isinstance(sessions, dict):
    sessions = {}
base["sessions"] = sessions

session = sessions.get(sid)
if not isinstance(session, dict):
    session = {"cwd": cwd, "files": []}

files = session.get("files")
if not isinstance(files, list):
    files = []

files.insert(0, {"file_path": file_path, "tool": tool_name, "timestamp": ts})
files = files[:100]

session["cwd"] = cwd
session["files"] = files
sessions[sid] = session
base["version"] = 1

with open(path, "w", encoding="utf-8") as fh:
    json.dump(base, fh, indent=2)
PY
    else
      local tmp_file
      tmp_file=$(mktemp "${ACTIVITY_FILE}.tmp.XXXXXX")
      jq --arg sid "$sid" \
         --arg cwd "$cwd" \
         --arg file_path "$file_path" \
         --arg tool "$tool_name" \
         --arg ts "$timestamp" \
         '.sessions[$sid] //= {cwd: $cwd, files: []}
          | .sessions[$sid].cwd = $cwd
          | .sessions[$sid].files = ([{file_path: $file_path, tool: $tool, timestamp: $ts}] + .sessions[$sid].files)[:100]' \
         "$ACTIVITY_FILE" > "$tmp_file" && mv "$tmp_file" "$ACTIVITY_FILE"
    fi
  }

  local timeout=30
  local attempt=0
  while ! mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null; do
    ((attempt++))
    if [ $attempt -ge $timeout ]; then
      rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
      mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null || return 1
      break
    fi
    sleep 0.1
  done

  _record_activity_inner
  rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
}

find_handoff_pid() {
  local cwd="$1"
  local exclude_pid="$2"
  [ ! -f "$STATE_FILE" ] && return 0

  if [ -n "$HAVE_PY" ]; then
    python3 - "$STATE_FILE" "$cwd" "$exclude_pid" <<'PY'
import json
import os
import sys

path, cwd, exclude_pid = sys.argv[1:4]
exclude_pid = int(exclude_pid) if exclude_pid.isdigit() else None

try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

sessions = data.get("sessions", {})
if not isinstance(sessions, dict):
    sys.exit(0)

for rec in sessions.values():
    if not isinstance(rec, dict):
        continue
    if rec.get("cwd") != cwd:
        continue
    pid = rec.get("pid")
    if not isinstance(pid, int):
        continue
    if exclude_pid is not None and pid == exclude_pid:
        continue
    try:
        os.kill(pid, 0)
    except Exception:
        continue
    print(pid)
    sys.exit(0)
PY
    return 0
  fi

  jq -r --arg cwd "$cwd" --arg exclude "$exclude_pid" \
    '.sessions | to_entries[]
     | select(.value.cwd == $cwd)
     | select(.value.pid != null)
     | select((.value.pid | tostring) != $exclude)
     | .value.pid' \
    "$STATE_FILE" 2>/dev/null | while read -r candidate_pid; do
      if [ -n "$candidate_pid" ] && kill -0 "$candidate_pid" 2>/dev/null; then
        echo "$candidate_pid"
        break
      fi
    done
}

spawn_lock_holder() {
  local cwd="$1"
  local claude_pid="$2"

  local normalized
  normalized=$(normalize_path "$cwd")
  local lock_hash
  lock_hash=$(compute_lock_hash "$normalized")
  [ -z "$lock_hash" ] && return 0

  local lock_file="$LOCK_DIR/${lock_hash}.lock"

  (
    for existing_lock in "$LOCK_DIR"/*.lock; do
      [ -d "$existing_lock" ] || continue
      if [ -f "$existing_lock/pid" ]; then
        existing_pid=$(cat "$existing_lock/pid" 2>/dev/null)
        if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
          rm -rf "$existing_lock"
          log "Cleaned up stale lock (PID $existing_pid dead): $existing_lock"
        fi
      fi
    done

    if ! mkdir "$lock_file" 2>/dev/null; then
      if [ -f "$lock_file/pid" ]; then
        old_pid=$(cat "$lock_file/pid" 2>/dev/null)
        if [ -n "$old_pid" ]; then
          if [ "$old_pid" = "$claude_pid" ]; then
            write_lock_metadata "$lock_file/meta.json" "$claude_pid" "$cwd"
            log "Reused existing lock for PID $claude_pid at $cwd"
            exit 0
          elif kill -0 "$old_pid" 2>/dev/null; then
            if ! is_claude_process "$old_pid"; then
              log "Taking over lock from PID $old_pid (not Claude) at $cwd"
              rm -rf "$lock_file"
              mkdir "$lock_file" 2>/dev/null || exit 0
            elif is_legacy_lock_stale "$lock_file"; then
              log "Taking over stale legacy lock from PID $old_pid at $cwd"
              rm -rf "$lock_file"
              mkdir "$lock_file" 2>/dev/null || exit 0
            else
              exit 0
            fi
          else
            rm -rf "$lock_file"
            mkdir "$lock_file" 2>/dev/null || exit 0
          fi
        else
          rm -rf "$lock_file"
          mkdir "$lock_file" 2>/dev/null || exit 0
        fi
      else
        exit 0
      fi
    fi

    echo "$claude_pid" > "$lock_file/pid"
    write_lock_metadata "$lock_file/meta.json" "$claude_pid" "$cwd"

    current_pid=$claude_pid
    while true; do
      while kill -0 "$current_pid" 2>/dev/null; do
        [ -d "$lock_file" ] || exit 0
        sleep 1
      done

      handoff_pid=$(find_handoff_pid "$cwd" "$current_pid")
      if [ -n "$handoff_pid" ]; then
        echo "$handoff_pid" > "$lock_file/pid"
        write_lock_metadata "$lock_file/meta.json" "$handoff_pid" "$cwd" "$current_pid"
        log "Lock handoff: $current_pid -> $handoff_pid for $cwd"
        current_pid=$handoff_pid
      else
        rm -rf "$lock_file"
        log "Lock released for $cwd (PID $current_pid exited, no handoff candidate)"
        break
      fi
    done
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
  log "Lock holder spawned for $cwd (PID $claude_pid)"
}

EVENT=$(json_get '.hook_event_name // empty' 'hook_event_name')
SESSION_ID=$(json_get '.session_id // empty' 'session_id')
CWD_INPUT=$(json_get '.cwd // empty' 'cwd')
TRIGGER=$(json_get '.trigger // empty' 'trigger')
NOTIFICATION_TYPE=$(json_get '.notification_type // empty' 'notification_type')
STOP_HOOK_ACTIVE=$(json_get '.stop_hook_active // false' 'stop_hook_active')
TOOL_NAME=$(json_get '.tool_name // empty' 'tool_name')
TOOL_FILE_PATH=$(json_get '.tool_input.file_path // empty' 'tool_input.file_path')
TOOL_ALT_PATH=$(json_get '.tool_input.path // empty' 'tool_input.path')
TOOL_RESPONSE_PATH=$(json_get '.tool_response.filePath // empty' 'tool_response.filePath')

log "Hook input: event=$EVENT session_id=$SESSION_ID cwd=$CWD_INPUT trigger=$TRIGGER notification_type=$NOTIFICATION_TYPE stop_hook_active=$STOP_HOOK_ACTIVE tool=$TOOL_NAME"

[ -z "$EVENT" ] && exit 0

if [ -z "$SESSION_ID" ]; then
  log "Skipping event (missing session_id): event=$EVENT"
  exit 0
fi

ensure_state_file

CURRENT_STATE=$(get_session_field "$SESSION_ID" "state")
CURRENT_CWD=$(get_session_field "$SESSION_ID" "cwd")

resolve_cwd() {
  local resolved=""
  if [ -n "$CWD_INPUT" ]; then
    resolved="$CWD_INPUT"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    resolved="$CLAUDE_PROJECT_DIR"
  elif [ -n "$CURRENT_CWD" ]; then
    resolved="$CURRENT_CWD"
  elif [ -n "${PWD:-}" ]; then
    resolved="$PWD"
  fi
  resolved=$(normalize_path "$resolved")
  echo "$resolved"
}

CWD=$(resolve_cwd)
TIMESTAMP=$(timestamp_iso)
CLAUDE_PID="$PPID"

ACTION=""
NEW_STATE=""

case "$EVENT" in
  "SessionStart")
    if [ "$CURRENT_STATE" = "working" ] || [ "$CURRENT_STATE" = "waiting" ] || [ "$CURRENT_STATE" = "compacting" ]; then
      log "SessionStart ignored (current_state=$CURRENT_STATE)"
      exit 0
    fi
    NEW_STATE="ready"
    spawn_lock_holder "$CWD" "$CLAUDE_PID"
    ;;
  "UserPromptSubmit")
    NEW_STATE="working"
    spawn_lock_holder "$CWD" "$CLAUDE_PID"
    ;;
  "PreToolUse")
    if [ "$CURRENT_STATE" = "working" ]; then
      ACTION="heartbeat"
    else
      NEW_STATE="working"
    fi
    ;;
  "PostToolUse")
    if [ -z "$TOOL_FILE_PATH" ] && [ -n "$TOOL_ALT_PATH" ]; then
      TOOL_FILE_PATH="$TOOL_ALT_PATH"
    elif [ -z "$TOOL_FILE_PATH" ] && [ -n "$TOOL_RESPONSE_PATH" ]; then
      TOOL_FILE_PATH="$TOOL_RESPONSE_PATH"
    fi

    case "$TOOL_NAME" in
      Edit|Write|Read|NotebookEdit)
        (record_file_activity "$SESSION_ID" "$CWD" "$TOOL_FILE_PATH" "$TOOL_NAME" "$TIMESTAMP") &
        disown 2>/dev/null
        ;;
    esac

    if [ "$CURRENT_STATE" = "working" ]; then
      ACTION="heartbeat"
    else
      NEW_STATE="working"
    fi
    ;;
  "PermissionRequest")
    NEW_STATE="waiting"
    ;;
  "PreCompact")
    if [ "$TRIGGER" = "auto" ]; then
      NEW_STATE="compacting"
    else
      log "PreCompact ignored (trigger=$TRIGGER)"
      exit 0
    fi
    ;;
  "Notification")
    if [ "$NOTIFICATION_TYPE" = "idle_prompt" ]; then
      NEW_STATE="ready"
    else
      log "Notification ignored (type=$NOTIFICATION_TYPE)"
      exit 0
    fi
    ;;
  "Stop")
    if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
      log "Stop ignored (stop_hook_active=true)"
      exit 0
    fi
    NEW_STATE="ready"
    ;;
  "SessionEnd")
    ACTION="delete"
    ;;
  *)
    log "Unhandled event: $EVENT"
    exit 0
    ;;
esac

if [ -z "$CWD" ] && [ "$ACTION" != "delete" ]; then
  log "Skipping event (missing cwd): event=$EVENT session_id=$SESSION_ID"
  exit 0
fi

if [ -z "$ACTION" ]; then
  if [ -n "$NEW_STATE" ]; then
    ACTION="upsert"
  else
    ACTION="heartbeat"
  fi
fi

log "State update: action=$ACTION new_state=$NEW_STATE session_id=$SESSION_ID cwd=$CWD"

if [ "$ACTION" = "delete" ]; then
  update_state "$SESSION_ID" "delete" "" "" "$TIMESTAMP" "$EVENT" ""

  if [ -f "$ACTIVITY_FILE" ]; then
    (
      local timeout=30
      local attempt=0
      while ! mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $timeout ]; then
          rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
          mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null || exit 0
          break
        fi
        sleep 0.1
      done

      if [ -n "$HAVE_PY" ]; then
        python3 - "$ACTIVITY_FILE" "$SESSION_ID" <<'PY'
import json
import sys

path, sid = sys.argv[1:3]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

sessions = data.get("sessions")
if isinstance(sessions, dict):
    sessions.pop(sid, None)

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
      else
        tmp_file=$(mktemp "${ACTIVITY_FILE}.tmp.XXXXXX")
        jq --arg sid "$SESSION_ID" 'del(.sessions[$sid])' "$ACTIVITY_FILE" > "$tmp_file" && mv "$tmp_file" "$ACTIVITY_FILE"
      fi

      rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
    ) &
    disown 2>/dev/null
  fi
else
  update_state "$SESSION_ID" "$ACTION" "$NEW_STATE" "$CWD" "$TIMESTAMP" "$EVENT" "$TOOL_NAME"
fi
