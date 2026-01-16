#!/bin/bash

# Claude HUD State Tracker
# Tracks session state for all Claude Code projects in a centralized file
# Handles: SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse, Stop, SessionEnd, PreCompact

# Skip if this is a summary generation subprocess (prevents recursive hook pollution)
if [ "$HUD_SUMMARY_GEN" = "1" ]; then
  cat > /dev/null  # consume stdin
  exit 0
fi

# CRITICAL: Capture Claude's PID at the very start, BEFORE any subshells
# Inside subshells, $PPID refers to the hook script PID, not Claude's PID
# This variable must be used for all state file PID writes
CLAUDE_PID="$PPID"

STATE_FILE="$HOME/.claude/hud-session-states-v2.json"
ACTIVITY_FILE="$HOME/.claude/hud-file-activity.json"
LOG_FILE="$HOME/.claude/hud-hook-debug.log"
STATE_LOCK_DIR="${STATE_FILE}.lock"
ACTIVITY_LOCK_DIR="${ACTIVITY_FILE}.lock"

# Normalize a path: resolve symlinks and strip trailing slashes
normalize_path() {
  local path="$1"

  # Resolve symlinks if possible (handles ~/projects -> /Users/foo/Code)
  if [ -d "$path" ]; then
    path=$(cd "$path" 2>/dev/null && pwd -P) || path="$path"
  fi

  # Strip all trailing slashes using pattern expansion
  while [[ "$path" == */ && "$path" != "/" ]]; do
    path="${path%/}"
  done
  # If we ended up with empty string (was all slashes), return root
  if [ -z "$path" ]; then
    echo "/"
  else
    echo "$path"
  fi
}

# Get current time in milliseconds (portable across GNU/BSD date)
# Returns milliseconds since epoch (13 digits)
# Tries multiple approaches for maximum portability
get_time_ms() {
  local now_ms=""

  # Try GNU date first (if gdate installed via brew)
  if command -v gdate >/dev/null 2>&1; then
    now_ms=$(gdate +%s%3N 2>/dev/null)
  fi

  # Try perl Time::HiRes (commonly present on macOS)
  if [ -z "$now_ms" ] && command -v perl >/dev/null 2>&1; then
    now_ms=$(perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000)' 2>/dev/null)
  fi

  # Last fallback: seconds * 1000 (still numeric and monotonic)
  if [ -z "$now_ms" ]; then
    now_ms="$(( $(date +%s) * 1000 ))"
  fi

  # Validate numeric (safety check)
  if ! [[ "$now_ms" =~ ^[0-9]+$ ]]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ERROR: timestamp not numeric: '$now_ms', using fallback" >> "$LOG_FILE"
    now_ms="$(( $(date +%s) * 1000 ))"
  fi

  echo "$now_ms"
}

# Get process start time as Unix timestamp
# Uses lstart (available on macOS/BSD) and converts to epoch seconds
get_process_start_time() {
  local pid="$1"

  # BSD/macOS ps: lstart uses %c format (locale's preferred date/time representation)
  # Force LC_ALL=C for consistent parsing
  local lstart
  lstart=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || {
    # If lstart fails, we can't reliably get start time
    # Return empty (caller should handle as verification failure)
    return 1
  }

  # Convert lstart to epoch seconds using date -j (BSD/macOS)
  # Use %c format to match what ps lstart produces
  local epoch
  epoch=$(LC_ALL=C date -j -f "%c" "$lstart" +%s 2>/dev/null) || {
    # Date parsing failed - return empty
    return 1
  }

  echo "$epoch"
}

# Execute a command with state file lock held (subshell pattern)
# Usage: with_state_lock <command> [args...]
# The lock is held for the duration of the command execution
with_state_lock() (
  # Subshell ensures EXIT trap releases lock when command completes
  local timeout=50  # 5 seconds max (50 * 0.1s)
  local attempt=0

  while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
    ((attempt++))
    if [ $attempt -ge $timeout ]; then
      # Check if lock is stale and should be broken
      if [ -d "$STATE_LOCK_DIR" ]; then
        local owner_pid owner_proc_started should_break=false
        owner_pid=$(cat "$STATE_LOCK_DIR/owner_pid" 2>/dev/null)

        if [ -n "$owner_pid" ] && [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
          # Owner PID exists and is numeric - check liveness and identity
          if ! kill -0 "$owner_pid" 2>/dev/null; then
            # Owner is dead - break lock
            should_break=true
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Breaking stale lock (owner PID $owner_pid dead)" >> "$LOG_FILE"
          else
            # Owner PID is alive - verify identity using start time
            owner_proc_started=$(cat "$STATE_LOCK_DIR/owner_proc_started" 2>/dev/null)
            if [ -n "$owner_proc_started" ]; then
              actual_start=$(get_process_start_time "$owner_pid" 2>/dev/null)
              if [ -n "$actual_start" ] && [ "$actual_start" != "$owner_proc_started" ]; then
                # Start time mismatch - PID was reused
                should_break=true
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Breaking stale lock (PID $owner_pid reused: expected start $owner_proc_started, got $actual_start)" >> "$LOG_FILE"
              fi
            fi
          fi
        else
          # Owner PID missing or invalid - check lock directory age
          if command -v stat >/dev/null 2>&1; then
            local lock_mtime current_time lock_age
            current_time=$(date +%s)
            # macOS: stat -f %m gives mtime as Unix timestamp
            lock_mtime=$(stat -f %m "$STATE_LOCK_DIR" 2>/dev/null || echo "$current_time")
            lock_age=$((current_time - lock_mtime))

            if [ $lock_age -gt 10 ]; then
              # Lock is old and has no valid owner - break it
              should_break=true
              echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Breaking stale lock (no valid owner, age: ${lock_age}s)" >> "$LOG_FILE"
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
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ERROR: Failed to acquire state lock after 5 seconds" >> "$LOG_FILE"
      exit 1
    fi
    sleep 0.1
  done

  # Lock acquired - write owner PID, process start time, and set EXIT trap
  echo "$$" > "$STATE_LOCK_DIR/owner_pid"
  get_process_start_time "$$" > "$STATE_LOCK_DIR/owner_proc_started" 2>/dev/null
  trap 'rm -rf "$STATE_LOCK_DIR" 2>/dev/null' EXIT

  # Execute the command
  "$@"
)

# Write lock meta.json with proper timestamps
# Args: $1=output_file, $2=pid, $3=path, $4=handoff_from (optional)
write_lock_metadata() {
  local output_file="$1"
  local pid="$2"
  local path="$3"
  local handoff_from="$4"

  local proc_start_time created_time_ms
  proc_start_time=$(get_process_start_time "$pid") || proc_start_time=""
  # Use millisecond resolution for created timestamp to avoid same-second ties
  # Portable across BSD/GNU date via get_time_ms helper
  created_time_ms=$(get_time_ms)

  if [ -n "$proc_start_time" ]; then
    # Include proc_started for PID verification
    if [ -n "$handoff_from" ]; then
      jq -n --argjson pid "$pid" \
            --argjson proc_started "$proc_start_time" \
            --argjson created "$created_time_ms" \
            --arg path "$path" \
            --argjson handoff_from "$handoff_from" \
            '{pid:$pid, proc_started:$proc_started, created:$created, path:$path, handoff_from:$handoff_from}' > "$output_file"
    else
      jq -n --argjson pid "$pid" \
            --argjson proc_started "$proc_start_time" \
            --argjson created "$created_time_ms" \
            --arg path "$path" \
            '{pid:$pid, proc_started:$proc_started, created:$created, path:$path}' > "$output_file"
    fi
  else
    # Fallback: omit proc_started (Rust treats as legacy/unverified)
    if [ -n "$handoff_from" ]; then
      jq -n --argjson pid "$pid" \
            --argjson created "$created_time_ms" \
            --arg path "$path" \
            --argjson handoff_from "$handoff_from" \
            '{pid:$pid, created:$created, path:$path, handoff_from:$handoff_from}' > "$output_file"
    else
      jq -n --argjson pid "$pid" \
            --argjson created "$created_time_ms" \
            --arg path "$path" \
            '{pid:$pid, created:$created, path:$path}' > "$output_file"
    fi
  fi
}

# Check if a PID belongs to a Claude process
# Args: $1=pid
# Returns: 0 if it's a Claude process, 1 if not
is_claude_process() {
  local pid="$1"
  local proc_name proc_cmd

  # Check process name
  proc_name=$(ps -p "$pid" -o comm= 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$proc_name" == *claude* ]]; then
    return 0
  fi

  # Check command line (handles node-based execution)
  proc_cmd=$(ps -p "$pid" -o args= 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$proc_cmd" == *claude* ]]; then
    return 0
  fi

  return 1
}

# Check if a lock file is a stale legacy lock (no proc_started AND > 24h old)
# This matches the Rust resolver's staleness logic for consistency
# Args: $1=lock_dir (the .lock directory)
# Returns: 0 if stale (should be taken over), 1 if not stale
is_legacy_lock_stale() {
  local lock_dir="$1"
  local meta_file="$lock_dir/meta.json"

  [ -f "$meta_file" ] || return 1  # No meta file - not stale (missing data)

  # Check if lock has proc_started (modern lock format)
  local has_proc_started
  has_proc_started=$(jq -r 'if .proc_started then "yes" else "no" end' "$meta_file" 2>/dev/null)

  if [ "$has_proc_started" = "yes" ]; then
    # Modern lock with proc_started - not a legacy lock, not stale by this check
    return 1
  fi

  # Legacy lock - check age
  local now_ms lock_age_ms
  now_ms=$(get_time_ms)

  # Try to get created timestamp (milliseconds)
  local created_ms
  created_ms=$(jq -r '.created // empty' "$meta_file" 2>/dev/null)

  if [ -n "$created_ms" ] && [[ "$created_ms" =~ ^[0-9]+$ ]]; then
    # Normalize to milliseconds if needed (values < 1 trillion assumed to be seconds)
    if [ "$created_ms" -lt 1000000000000 ]; then
      created_ms=$((created_ms * 1000))
    fi
    lock_age_ms=$((now_ms - created_ms))
  else
    # Try ISO string "started" field
    local iso_started
    iso_started=$(jq -r '.started // empty' "$meta_file" 2>/dev/null)

    if [ -n "$iso_started" ]; then
      # Parse ISO 8601 to epoch seconds, then to ms
      local epoch_s
      epoch_s=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_started" +%s 2>/dev/null) || \
      epoch_s=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_started%Z}" +%s 2>/dev/null) || \
      epoch_s=""

      if [ -n "$epoch_s" ]; then
        local created_from_iso_ms=$((epoch_s * 1000))
        lock_age_ms=$((now_ms - created_from_iso_ms))
      else
        # Can't parse - use file mtime as fallback
        local mtime_s
        mtime_s=$(stat -f %m "$lock_dir" 2>/dev/null) || mtime_s=""
        if [ -n "$mtime_s" ]; then
          lock_age_ms=$(( (now_ms / 1000 - mtime_s) * 1000 ))
        else
          lock_age_ms=0  # Can't determine - assume not stale
        fi
      fi
    else
      # No timestamp at all - use file mtime
      local mtime_s
      mtime_s=$(stat -f %m "$lock_dir" 2>/dev/null) || mtime_s=""
      if [ -n "$mtime_s" ]; then
        lock_age_ms=$(( (now_ms / 1000 - mtime_s) * 1000 ))
      else
        lock_age_ms=0
      fi
    fi
  fi

  # 24 hours = 86,400,000 milliseconds
  if [ "$lock_age_ms" -gt 86400000 ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Legacy lock at $lock_dir is stale (age: $((lock_age_ms / 3600000))h)" >> "$LOG_FILE"
    return 0  # Stale
  fi

  return 1  # Not stale
}

# Record file activity for a tool use
# This enables HUD to track which projects have recent file edits
# Args: $1=session_id, $2=cwd, $3=file_path, $4=tool_name, $5=timestamp
record_file_activity() {
  local sid="$1"
  local cwd="$2"
  local file_path="$3"
  local tool_name="$4"
  local timestamp="$5"

  # Skip if no file path
  [ -z "$file_path" ] && return 0

  # Resolve relative paths against cwd
  if [[ "$file_path" != /* ]]; then
    file_path="$cwd/$file_path"
  fi

  # Canonicalize if path exists (resolve symlinks)
  if [ -e "$file_path" ] || [ -e "$(dirname "$file_path")" ]; then
    local canonical
    canonical=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P)/$(basename "$file_path")
    if [ -n "$canonical" ]; then
      file_path="$canonical"
    fi
  fi

  # Initialize activity file if needed
  if [ ! -f "$ACTIVITY_FILE" ] || ! jq -e . "$ACTIVITY_FILE" &>/dev/null; then
    echo '{"version":1,"sessions":{}}' > "$ACTIVITY_FILE"
  fi

  # Update activity file with lock
  _record_activity_inner() {
    local tmp_file
    tmp_file=$(mktemp "${ACTIVITY_FILE}.tmp.XXXXXX")

    jq --arg sid "$sid" \
       --arg cwd "$cwd" \
       --arg file_path "$file_path" \
       --arg tool "$tool_name" \
       --arg ts "$timestamp" \
       '
       # Ensure session exists
       .sessions[$sid] //= {cwd: $cwd, files: []}
       # Update cwd (in case session moved)
       | .sessions[$sid].cwd = $cwd
       # Add file activity (keep last 100 per session for memory efficiency)
       | .sessions[$sid].files = ([{
           file_path: $file_path,
           tool: $tool,
           timestamp: $ts
         }] + .sessions[$sid].files)[:100]
       ' "$ACTIVITY_FILE" > "$tmp_file" && mv "$tmp_file" "$ACTIVITY_FILE"
  }

  # Acquire activity lock (similar to state lock but simpler)
  local timeout=30  # 3 seconds max
  local attempt=0
  while ! mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null; do
    ((attempt++))
    if [ $attempt -ge $timeout ]; then
      # Force break stale lock
      rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
      mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null || return 1
      break
    fi
    sleep 0.1
  done

  # Execute and release lock
  _record_activity_inner
  rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
}

input=$(cat)

# Log every hook call (include trigger for PreCompact debugging)
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $(echo "$input" | jq -c '{event: .hook_event_name, cwd: .cwd, stop_hook_active: .stop_hook_active, trigger: .trigger}')" >> "$LOG_FILE"

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')
source=$(echo "$input" | jq -r '.source // empty')
trigger=$(echo "$input" | jq -r '.trigger // empty')

# Extract tool info for PostToolUse file activity tracking
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Expand tilde in transcript_path (bash doesn't expand ~ in variables)
transcript_path="${transcript_path/#\~/$HOME}"

if [ "$event" = "Stop" ] && [ "$stop_hook_active" = "true" ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Skipping Stop event (stop_hook_active=true)" >> "$LOG_FILE"
  exit 0
fi

if [ -z "$cwd" ] || [ -z "$event" ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Invalid input: cwd='$cwd' event='$event'" >> "$LOG_FILE"
  exit 0
fi

# Ensure jq is available
if ! command -v jq &>/dev/null; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ERROR: jq not found" >> "$LOG_FILE"
  exit 0
fi

# Initialize or repair state file if missing or corrupted
if [ ! -f "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" &>/dev/null; then
  echo '{"version":2,"sessions":{}}' > "$STATE_FILE"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Initialized state file" >> "$LOG_FILE"
fi

# Inner function for cleanup (called within lock)
_cleanup_dead_sessions_inner() {
  local tmp_file dead_sessions

  # Extract session IDs with PIDs, check if they're alive
  dead_sessions=$(jq -r '.sessions | to_entries[] | select(.value.pid != null) | "\(.key)|\(.value.pid)"' "$STATE_FILE" 2>/dev/null | \
    while IFS='|' read -r sid pid; do
      # Check if PID is dead (not running)
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        echo "$sid"
      fi
    done)

  # If we found dead sessions, remove them
  if [ -n "$dead_sessions" ]; then
    # Use co-located temp file
    tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
    # Build jq delete expression for all dead sessions
    local delete_expr=""
    for sid in $dead_sessions; do
      delete_expr="$delete_expr | del(.sessions[\"$sid\"])"
    done
    # Remove leading " | "
    delete_expr="${delete_expr# | }"

    # Apply the deletions
    if jq "$delete_expr" "$STATE_FILE" > "$tmp_file" 2>/dev/null && \
       jq -e . "$tmp_file" &>/dev/null; then
      mv "$tmp_file" "$STATE_FILE"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up dead sessions: $dead_sessions" >> "$LOG_FILE"
    else
      rm -f "$tmp_file"
    fi
  fi
}

# Opportunistic cleanup: remove dead sessions (non-blocking, best-effort)
cleanup_dead_sessions() {
  # Execute cleanup with lock held
  if ! with_state_lock _cleanup_dead_sessions_inner; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Failed to cleanup dead sessions (lock timeout)" >> "$LOG_FILE"
  fi
}

case "$event" in
  "SessionStart")
    new_state="ready"

    # Spawn background lock holder for reliable session detection
    # This holds a lock while Claude is running, auto-releases on exit/crash
    # Creating lock on SessionStart allows HUD to show Ready immediately on launch
    LOCK_DIR="$HOME/.claude/sessions"
    mkdir -p "$LOCK_DIR"

    # Normalize path before hashing (strip trailing slashes except root)
    # This ensures hash matches Rust's normalization in compute_lock_hash()
    cwd_normalized=$(normalize_path "$cwd")

    # Use md5 hash of normalized cwd as lock file name
    # Use -q (quiet) to ensure we get just the hash, not "MD5 (stdin) = hash"
    if command -v md5 &>/dev/null; then
      LOCK_HASH=$(md5 -q -s "$cwd_normalized")
    elif command -v md5sum &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd_normalized" | md5sum | cut -d' ' -f1)
    else
      # Fallback: simple hash using cksum
      LOCK_HASH=$(echo -n "$cwd_normalized" | cksum | cut -d' ' -f1)
    fi
    LOCK_FILE="$LOCK_DIR/${LOCK_HASH}.lock"
    CLAUDE_PID=$PPID

    # Spawn lock holder in background using mkdir-based locking (works on macOS)
    # mkdir is atomic - only one process can create a directory
    # IMPORTANT: Redirect all file descriptors to fully detach from parent process
    # Without this, Claude hangs waiting for inherited FDs to close
    (
      # NOTE: Duplicate cleanup removed - resolver expects multiple locks per PID
      # When session cd's, BOTH old and new locks should exist (newest selected by timestamp)
      # This enables proper parent/child matching in the resolver

      # CLEANUP: Opportunistically clean up any stale locks (dead PIDs)
      for existing_lock in "$LOCK_DIR"/*.lock; do
        [ -d "$existing_lock" ] || continue
        existing_pid=$(cat "$existing_lock/pid" 2>/dev/null)
        if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
          rm -rf "$existing_lock"
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up stale lock (PID $existing_pid dead): $existing_lock" >> "$LOG_FILE"
        fi
      done

      # Try to create lock directory (atomic operation)
      if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        # Lock exists - check if the holding process is still alive
        if [ -f "$LOCK_FILE/pid" ]; then
          OLD_PID=$(cat "$LOCK_FILE/pid" 2>/dev/null)
          if [ -n "$OLD_PID" ]; then
            if [ "$OLD_PID" = "$CLAUDE_PID" ]; then
              # FIX #2: Lock is ours (resume at same location) - just update timestamp
              write_lock_metadata "$LOCK_FILE/meta.json" "$CLAUDE_PID" "$cwd"
              echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Reused existing lock for PID $CLAUDE_PID at $cwd" >> "$LOG_FILE"
              exit 0  # Lock exists and is valid
            elif kill -0 "$OLD_PID" 2>/dev/null; then
              # Different PID still alive - check if we should take over
              # Take over if: (1) not a Claude process (PID reuse), or (2) stale legacy lock
              if ! is_claude_process "$OLD_PID"; then
                # PID reused by non-Claude process - safe to take over
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Taking over lock from PID $OLD_PID (not a Claude process) at $cwd" >> "$LOG_FILE"
                rm -rf "$LOCK_FILE"
                if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                  exit 0  # Another process grabbed it
                fi
              elif is_legacy_lock_stale "$LOCK_FILE"; then
                # Stale legacy lock (>24h) - take over even though PID is alive
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Taking over stale legacy lock from PID $OLD_PID at $cwd" >> "$LOG_FILE"
                rm -rf "$LOCK_FILE"
                if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                  exit 0  # Another process grabbed it
                fi
              else
                # Recent lock held by active Claude process - respect it
                exit 0
              fi
            else
              # Stale lock - remove and retry
              rm -rf "$LOCK_FILE"
              if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                exit 0  # Another process grabbed it
              fi
            fi
          else
            # Empty PID file - remove and retry
            rm -rf "$LOCK_FILE"
            if ! mkdir "$LOCK_FILE" 2>/dev/null; then
              exit 0
            fi
          fi
        else
          exit 0  # Lock dir exists but no pid file - race condition, exit
        fi
      fi

      # We got the lock - write metadata
      echo "$CLAUDE_PID" > "$LOCK_FILE/pid"
      write_lock_metadata "$LOCK_FILE/meta.json" "$CLAUDE_PID" "$cwd"

      # Monitor loop with handoff support
      # When current PID exits, try to hand off to another instance in same project
      current_pid=$CLAUDE_PID
      while true; do
        # Hold lock while current Claude runs
        while kill -0 $current_pid 2>/dev/null; do
          # Self-terminate if lock was removed by another instance
          [ -d "$LOCK_FILE" ] || exit 0
          sleep 1
        done

        # Current PID exited - attempt handoff to another instance
        handoff_pid=""
        if [ -f "$STATE_FILE" ]; then
          # First, clean up stale sessions for this cwd:
          # - Sessions with the exiting PID (definitely stale)
          # - Sessions with dead PIDs (crashed/closed without SessionEnd)
          # Sessions without PIDs are left alone (from before PID tracking was added)
          dead_sids=""
          while IFS='|' read -r sid pid; do
            if [ -n "$sid" ]; then
              if [ "$pid" = "$current_pid" ]; then
                dead_sids="$dead_sids $sid"
              elif [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                dead_sids="$dead_sids $sid"
              fi
            fi
          done < <(jq -r --arg cwd "$cwd" '
            .sessions | to_entries[]
            | select(.value.cwd == $cwd)
            | select(.value.pid != null)
            | "\(.key)|\(.value.pid)"
          ' "$STATE_FILE" 2>/dev/null)

          # Remove stale sessions
          if [ -n "$dead_sids" ]; then
            # Inner function for cleanup (called within lock)
            _cleanup_stale_inner() {
              # Use co-located temp file
              local tmp_file
              tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
              local jq_filter='.'
              for sid in $dead_sids; do
                jq_filter="$jq_filter | del(.sessions[\"$sid\"])"
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up stale session $sid for $cwd" >> "$LOG_FILE"
              done
              jq "$jq_filter" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
            }

            # Execute cleanup with lock held
            if ! with_state_lock _cleanup_stale_inner; then
              echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Failed to cleanup stale sessions (lock timeout)" >> "$LOG_FILE"
            fi
          fi

          # Now find handoff candidates (sessions with alive PIDs, different from exiting PID)
          handoff_pid=$(jq -r --arg cwd "$cwd" --arg my_pid "$current_pid" '
            .sessions | to_entries[]
            | select(.value.cwd == $cwd)
            | select(.value.pid != null)
            | select((.value.pid | tostring) != $my_pid)
            | .value.pid
          ' "$STATE_FILE" 2>/dev/null | while read candidate_pid; do
            if [ -n "$candidate_pid" ] && kill -0 "$candidate_pid" 2>/dev/null; then
              echo "$candidate_pid"
              break
            fi
          done)
        fi

        if [ -n "$handoff_pid" ]; then
          # Handoff: update lock to new PID and continue monitoring
          echo "$handoff_pid" > "$LOCK_FILE/pid"
          write_lock_metadata "$LOCK_FILE/meta.json" "$handoff_pid" "$cwd" "$current_pid"
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Lock handoff: $current_pid -> $handoff_pid for $cwd" >> "$LOG_FILE"
          current_pid=$handoff_pid
          # Continue loop to monitor new PID
        else
          # No handoff candidate - release lock and exit
          rm -rf "$LOCK_FILE"
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Lock released for $cwd (PID $current_pid exited, no handoff candidate)" >> "$LOG_FILE"
          break
        fi
      done
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Lock holder spawned for $cwd (PID $CLAUDE_PID)" >> "$LOG_FILE"
    ;;
  "UserPromptSubmit")
    new_state="working"

    # CRITICAL: Ensure lock exists for resumed sessions
    # SessionStart only fires on initial launch, not on session resume
    # If this is a resumed session, we need to create the lock retroactively
    LOCK_DIR="$HOME/.claude/sessions"
    mkdir -p "$LOCK_DIR"

    # Normalize path before hashing (must match Rust's normalization)
    cwd_normalized=$(normalize_path "$cwd")

    # Use -q (quiet) to ensure we get just the hash
    if command -v md5 &>/dev/null; then
      LOCK_HASH=$(md5 -q -s "$cwd_normalized")
    elif command -v md5sum &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd_normalized" | md5sum | cut -d' ' -f1)
    else
      LOCK_HASH=$(echo -n "$cwd_normalized" | cksum | cut -d' ' -f1)
    fi
    LOCK_FILE="$LOCK_DIR/${LOCK_HASH}.lock"

    # Check if lock exists for this cwd
    if [ ! -d "$LOCK_FILE" ]; then
      # No lock exists - this is likely a resumed session
      # Create lock holder (same logic as SessionStart)
      CLAUDE_PID=$PPID
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | No lock found for $cwd, creating retroactively (resumed session, PID $CLAUDE_PID)" >> "$LOG_FILE"

      (
        # CLEANUP: Remove any existing locks held by this same PID
        for existing_lock in "$LOCK_DIR"/*.lock; do
          [ -d "$existing_lock" ] || continue
          [ "$existing_lock" = "$LOCK_FILE" ] && continue
          existing_pid=$(cat "$existing_lock/pid" 2>/dev/null)
          if [ "$existing_pid" = "$CLAUDE_PID" ]; then
            rm -rf "$existing_lock"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up duplicate lock for PID $CLAUDE_PID: $existing_lock" >> "$LOG_FILE"
          fi
        done

        # Try to create lock directory
        if ! mkdir "$LOCK_FILE" 2>/dev/null; then
          # Lock exists - check if holding process is alive
          if [ -f "$LOCK_FILE/pid" ]; then
            OLD_PID=$(cat "$LOCK_FILE/pid" 2>/dev/null)
            if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
              # Process still running - check if we should take over
              if ! is_claude_process "$OLD_PID"; then
                # PID reused by non-Claude process - safe to take over
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Taking over lock from PID $OLD_PID (not Claude) at $cwd (UserPromptSubmit)" >> "$LOG_FILE"
                rm -rf "$LOCK_FILE"
                if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                  exit 0
                fi
              elif is_legacy_lock_stale "$LOCK_FILE"; then
                # Stale legacy lock (>24h) - take over
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Taking over stale legacy lock from PID $OLD_PID at $cwd (UserPromptSubmit)" >> "$LOG_FILE"
                rm -rf "$LOCK_FILE"
                if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                  exit 0
                fi
              else
                # Recent lock held by active Claude process - respect it
                exit 0
              fi
            else
              # Dead PID - stale lock, remove and retry
              rm -rf "$LOCK_FILE"
              if ! mkdir "$LOCK_FILE" 2>/dev/null; then
                exit 0
              fi
            fi
          else
            exit 0
          fi
        fi

        # Write lock metadata
        echo "$CLAUDE_PID" > "$LOCK_FILE/pid"
        write_lock_metadata "$LOCK_FILE/meta.json" "$CLAUDE_PID" "$cwd"

        # Monitor loop (same as SessionStart)
        current_pid=$CLAUDE_PID
        while true; do
          while kill -0 $current_pid 2>/dev/null; do
            # Self-terminate if lock was removed by another instance
            [ -d "$LOCK_FILE" ] || exit 0
            sleep 1
          done

          # Attempt handoff
          handoff_pid=""
          if [ -f "$STATE_FILE" ]; then
            dead_sids=""
            while IFS='|' read -r sid pid; do
              if [ -n "$sid" ]; then
                if [ "$pid" = "$current_pid" ]; then
                  dead_sids="$dead_sids $sid"
                elif [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                  dead_sids="$dead_sids $sid"
                fi
              fi
            done < <(jq -r --arg cwd "$cwd" '
              .sessions | to_entries[]
              | select(.value.cwd == $cwd)
              | select(.value.pid != null)
              | "\(.key)|\(.value.pid)"
            ' "$STATE_FILE" 2>/dev/null)

            if [ -n "$dead_sids" ]; then
              # Inner function for cleanup (called within lock)
              _cleanup_stale_inner_resumed() {
                # Use co-located temp file
                local tmp_file
                tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
                local jq_filter='.'
                for sid in $dead_sids; do
                  jq_filter="$jq_filter | del(.sessions[\"$sid\"])"
                  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up stale session $sid for $cwd" >> "$LOG_FILE"
                done
                jq "$jq_filter" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
              }

              # Execute cleanup with lock held
              if ! with_state_lock _cleanup_stale_inner_resumed; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Failed to cleanup stale sessions (lock timeout)" >> "$LOG_FILE"
              fi
            fi

            handoff_pid=$(jq -r --arg cwd "$cwd" --arg my_pid "$current_pid" '
              .sessions | to_entries[]
              | select(.value.cwd == $cwd)
              | select(.value.pid != null)
              | select((.value.pid | tostring) != $my_pid)
              | .value.pid
            ' "$STATE_FILE" 2>/dev/null | while read candidate_pid; do
              if [ -n "$candidate_pid" ] && kill -0 "$candidate_pid" 2>/dev/null; then
                echo "$candidate_pid"
                break
              fi
            done)
          fi

          if [ -n "$handoff_pid" ]; then
            echo "$handoff_pid" > "$LOCK_FILE/pid"
            write_lock_metadata "$LOCK_FILE/meta.json" "$handoff_pid" "$cwd" "$current_pid"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Lock handoff: $current_pid -> $handoff_pid for $cwd" >> "$LOG_FILE"
            current_pid=$handoff_pid
          else
            rm -rf "$LOCK_FILE"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Lock released for $cwd (PID $current_pid exited, no handoff candidate)" >> "$LOG_FILE"
            break
          fi
        done
      ) </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null
    fi
    ;;
  "PermissionRequest")
    new_state="blocked"
    ;;
  "PostToolUse")
    # Tool use means Claude is actively working
    # Requires session_id for state lookup
    if [ -z "$session_id" ]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | PostToolUse: no session_id, skipping" >> "$LOG_FILE"
      exit 0
    fi

    # Record file activity for file-modifying tools (enables monorepo package tracking)
    # This runs in background to not block the hook response
    if [ -n "$tool_file_path" ]; then
      case "$tool_name" in
        Edit|Write|Read|NotebookEdit)
          activity_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
          (record_file_activity "$session_id" "$cwd" "$tool_file_path" "$tool_name" "$activity_ts") &
          disown 2>/dev/null
          ;;
      esac
    fi

    current_state=$(jq -r --arg sid "$session_id" '.sessions[$sid].state // "idle"' "$STATE_FILE" 2>/dev/null)

    if [ "$current_state" = "compacting" ]; then
      new_state="working"
      should_publish=true
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | PostToolUse: compacting->working transition" >> "$LOG_FILE"
    elif [ "$current_state" = "working" ]; then
      # Update heartbeat timestamp (with lock to prevent concurrent writes)
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      _heartbeat_inner() {
        local tmp_file
        tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
        jq --arg sid "$session_id" \
           --arg ts "$timestamp" \
           'if .sessions[$sid] then .sessions[$sid].updated_at = $ts else . end' \
           "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
      }
      with_state_lock _heartbeat_inner
      exit 0
    elif [ "$current_state" = "ready" ] || [ "$current_state" = "idle" ] || [ "$current_state" = "blocked" ]; then
      # Tool use in non-working state means Claude is working
      # (e.g., session resumption, permission granted)
      new_state="working"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | PostToolUse: $current_state->working transition" >> "$LOG_FILE"
    else
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | PostToolUse: unexpected state '$current_state', ignoring" >> "$LOG_FILE"
      exit 0
    fi
    ;;
  "Notification")
    # idle_prompt means Claude is waiting for user input (handles interrupt case)
    notification_type=$(echo "$input" | jq -r '.notification_type // empty')
    if [ "$notification_type" = "idle_prompt" ]; then
      new_state="ready"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Notification: idle_prompt -> ready" >> "$LOG_FILE"
    else
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Notification: ignoring type '$notification_type'" >> "$LOG_FILE"
      exit 0
    fi
    ;;
  "Stop")
    new_state="ready"
    ;;
  "SessionEnd")
    # Set to idle when session ends - this is the correct final state
    # Even though it fires after Stop, "idle" is correct when Claude is closed
    new_state="idle"

    # Clean up file activity for this session (background, non-blocking)
    if [ -n "$session_id" ] && [ -f "$ACTIVITY_FILE" ]; then
      (
        # Acquire activity lock
        timeout=30
        attempt=0
        while ! mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null; do
          attempt=$((attempt + 1))
          if [ $attempt -ge $timeout ]; then
            rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
            mkdir "$ACTIVITY_LOCK_DIR" 2>/dev/null || exit 0
            break
          fi
          sleep 0.1
        done

        # Remove session's activity data
        tmp_file=$(mktemp "${ACTIVITY_FILE}.tmp.XXXXXX")
        jq --arg sid "$session_id" 'del(.sessions[$sid])' "$ACTIVITY_FILE" > "$tmp_file" && \
          mv "$tmp_file" "$ACTIVITY_FILE"

        rm -rf "$ACTIVITY_LOCK_DIR" 2>/dev/null
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up activity data for session $session_id" >> "$LOG_FILE"
      ) &
      disown 2>/dev/null
    fi
    ;;
  "PreCompact")
    # Always show "compacting" status for both auto and manual compaction
    # Users want visibility into compaction regardless of how it was triggered
    new_state="compacting"
    ;;
  *)
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Unhandled event: $event" >> "$LOG_FILE"
    exit 0
    ;;
esac

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Log state transition for debugging
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | State transition: event=$event, new_state=$new_state, session_id=$session_id, cwd=$cwd" >> "$LOG_FILE"

# Inner function for state update (called within lock)
_update_state_inner() {
  # Use co-located temp file (same directory as state file)
  local tmp_file
  tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")

  if [ "$new_state" = "idle" ]; then
    # Remove session on SessionEnd
    jq --arg sid "$session_id" \
       'del(.sessions[$sid])' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
  else
    # Preserve existing working_on/next_step when updating state
    # Include PID for lock handoff support (multiple instances in same project)
    jq --arg sid "$session_id" \
       --arg state "$new_state" \
       --arg cwd "$cwd" \
       --arg ts "$timestamp" \
       --argjson pid "$CLAUDE_PID" \
       '.sessions[$sid] = ((.sessions[$sid] // {}) + {
         session_id: $sid,
         state: $state,
         cwd: $cwd,
         updated_at: $ts,
         pid: $pid
       })' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
  fi
}

update_state() {
  # Skip if no session_id
  if [ -z "$session_id" ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Skipping state update (no session_id), event=$event, cwd=$cwd" >> "$LOG_FILE"
    return
  fi

  # Execute state update with lock held
  if ! with_state_lock _update_state_inner; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ERROR: Failed to update state (lock timeout), event=$event, session=$session_id" >> "$LOG_FILE"
  fi
}

update_state

# Opportunistic cleanup in background (non-blocking, SessionEnd only)
if [ "$event" = "SessionEnd" ]; then
  (cleanup_dead_sessions &) 2>/dev/null
fi

# Publish state if transitioning from compacting → working
if [ "$should_publish" = "true" ]; then
  "$HOME/.claude/hooks/publish-state.sh" &>/dev/null &
  disown 2>/dev/null
fi

# Generate summary on Stop events only (not every prompt submit)
# Optimized: uses only last 3 user messages, truncated to 150 chars each (~300 tokens total)
SUMMARY_COOLDOWN=60  # seconds between summary generations per session
SUMMARY_CACHE_FILE="$HOME/.claude/hud-summary-times.json"

# Debug: log transcript_path status on Stop events
if [ "$event" = "Stop" ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | SUMMARY_DEBUG: event=Stop, transcript_path='$transcript_path', exists=$([ -f "$transcript_path" ] && echo "yes" || echo "no")" >> "$LOG_FILE"
fi

if [ "$event" = "Stop" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  (
    _log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | SUMMARY: $1" >> "$LOG_FILE"; }
    _log "Starting summary generation for session=$session_id"

    # Check cooldown - skip if we generated recently for this session
    if [ -f "$SUMMARY_CACHE_FILE" ]; then
      last_gen=$(jq -r --arg sid "$session_id" '.[$sid] // 0' "$SUMMARY_CACHE_FILE" 2>/dev/null || echo "0")
      now=$(date +%s)
      if [ $((now - last_gen)) -lt $SUMMARY_COOLDOWN ]; then
        _log "Skipping due to cooldown (last=$last_gen, now=$now, diff=$((now - last_gen))s)"
        exit 0
      fi
    fi

    # Extract only user messages that contain actual text prompts, last 3, truncated to 150 chars each
    # This reduces context from ~25k tokens to ~300 tokens (50x reduction)
    # Handle both string content and array content formats
    context=$(grep '"type":"user"' "$transcript_path" | \
              jq -r '
                .message.content as $c |
                if ($c | type) == "string" then $c[0:150]
                elif ($c | type) == "array" then
                  ([$c[] | select(.type == "text")] | if length > 0 then .[0].text[0:150] else empty end)
                else empty
                end
              ' 2>/dev/null | \
              grep -v '^\[' | grep -v '^<' | tail -3 | \
              tr '\n' ' ' | sed 's/  */ /g')

    if [ -z "$context" ] || [ ${#context} -lt 10 ]; then
      _log "Skipping: context too short (len=${#context})"
      exit 0
    fi
    _log "Context extracted (len=${#context})"

    claude_cmd=$(command -v claude || echo "/opt/homebrew/bin/claude")
    _log "Calling claude at $claude_cmd"

    # Run from $HOME with HUD_SUMMARY_GEN=1 to prevent recursive hook triggers
    # Disable tools and frame as explicit summarization task
    response=$(cd "$HOME" && HUD_SUMMARY_GEN=1 "$claude_cmd" -p \
      --no-session-persistence \
      --output-format json \
      --model haiku \
      --tools "" \
      --system-prompt "You extract task summaries. Given user messages, output ONLY a 5-8 word gerund phrase describing what they're working on. Examples: 'Fixing login button alignment', 'Adding dark mode toggle', 'Debugging API response errors'. Output the phrase only, nothing else." \
      "Summarize this user's task: $context" 2>&1)

    _log "Claude response received (len=${#response})"

    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
      _log "ERROR: Invalid JSON response: ${response:0:200}"
      exit 0
    fi

    result=$(echo "$response" | jq -r '.result // empty')
    _log "Result extracted: ${result:0:100}"

    # Handle both JSON response and plain text
    working_on=$(echo "$result" | jq -r '.working_on // empty' 2>/dev/null)
    if [ -z "$working_on" ]; then
      # Haiku might return plain text for such a simple prompt
      working_on=$(echo "$result" | head -1 | cut -c1-80)
    fi
    _log "working_on='$working_on'"

    if [ -n "$working_on" ] && [ -n "$session_id" ]; then
      # Update working_on in state file
      _working_on_inner() {
        local tmp_file
        tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
        # Check if session still exists before update
        if jq -e --arg sid "$session_id" '.sessions[$sid]' "$STATE_FILE" >/dev/null 2>&1; then
          jq --arg sid "$session_id" \
             --arg working_on "$working_on" \
             '.sessions[$sid].working_on = $working_on' \
             "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | SUMMARY: Updated working_on for session=$session_id" >> "$LOG_FILE"
        else
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | SUMMARY: Session $session_id no longer exists, skipping update" >> "$LOG_FILE"
          rm -f "$tmp_file"
        fi
      }
      with_state_lock _working_on_inner

      # Update cooldown timestamp
      mkdir -p "$(dirname "$SUMMARY_CACHE_FILE")"
      if [ -f "$SUMMARY_CACHE_FILE" ]; then
        tmp_cache=$(mktemp)
        jq --arg sid "$session_id" --arg ts "$(date +%s)" '.[$sid] = ($ts | tonumber)' \
           "$SUMMARY_CACHE_FILE" > "$tmp_cache" && mv "$tmp_cache" "$SUMMARY_CACHE_FILE"
      else
        echo "{\"$session_id\": $(date +%s)}" > "$SUMMARY_CACHE_FILE"
      fi
    fi
  ) &>/dev/null &
  disown 2>/dev/null
fi

exit 0
