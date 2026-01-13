#!/bin/bash

# Claude HUD State Tracker
# Tracks session state for all Claude Code projects in a centralized file
# Handles: SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse, Stop, SessionEnd, PreCompact

# Skip if this is a summary generation subprocess (prevents recursive hook pollution)
if [ "$HUD_SUMMARY_GEN" = "1" ]; then
  cat > /dev/null  # consume stdin
  exit 0
fi

STATE_FILE="$HOME/.claude/hud-session-states-v2.json"
LOG_FILE="$HOME/.claude/hud-hook-debug.log"

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

case "$event" in
  "SessionStart")
    new_state="ready"

    # Spawn background lock holder for reliable session detection
    # This holds a lock while Claude is running, auto-releases on exit/crash
    # Creating lock on SessionStart allows HUD to show Ready immediately on launch
    LOCK_DIR="$HOME/.claude/sessions"
    mkdir -p "$LOCK_DIR"

    # Use md5 hash of cwd as lock file name
    if command -v md5 &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd" | md5)
    elif command -v md5sum &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd" | md5sum | cut -d' ' -f1)
    else
      # Fallback: simple hash using cksum
      LOCK_HASH=$(echo -n "$cwd" | cksum | cut -d' ' -f1)
    fi
    LOCK_FILE="$LOCK_DIR/${LOCK_HASH}.lock"
    CLAUDE_PID=$PPID

    # Spawn lock holder in background using mkdir-based locking (works on macOS)
    # mkdir is atomic - only one process can create a directory
    # IMPORTANT: Redirect all file descriptors to fully detach from parent process
    # Without this, Claude hangs waiting for inherited FDs to close
    (
      # CLEANUP: Remove any existing locks held by this same PID (handles cd scenarios)
      # This prevents multiple lock files pointing to the same Claude process
      for existing_lock in "$LOCK_DIR"/*.lock; do
        [ -d "$existing_lock" ] || continue
        [ "$existing_lock" = "$LOCK_FILE" ] && continue  # Skip our target lock
        existing_pid=$(cat "$existing_lock/pid" 2>/dev/null)
        if [ "$existing_pid" = "$CLAUDE_PID" ]; then
          rm -rf "$existing_lock"
          echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up duplicate lock for PID $CLAUDE_PID: $existing_lock" >> "$LOG_FILE"
        fi
      done

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
          if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            # Process still running - exit
            exit 0
          fi
          # Stale lock - remove and retry
          rm -rf "$LOCK_FILE"
          if ! mkdir "$LOCK_FILE" 2>/dev/null; then
            exit 0  # Another process grabbed it
          fi
        else
          exit 0  # Lock dir exists but no pid file - race condition, exit
        fi
      fi

      # We got the lock - write metadata
      echo "$CLAUDE_PID" > "$LOCK_FILE/pid"
      echo "{\"pid\": $CLAUDE_PID, \"started\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"path\": \"$cwd\"}" > "$LOCK_FILE/meta.json"

      # Monitor loop with handoff support
      # When current PID exits, try to hand off to another instance in same project
      current_pid=$CLAUDE_PID
      while true; do
        # Hold lock while current Claude runs
        while kill -0 $current_pid 2>/dev/null; do
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
            tmp_file=$(mktemp)
            jq_filter='.'
            for sid in $dead_sids; do
              jq_filter="$jq_filter | del(.sessions[\"$sid\"])"
              echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up stale session $sid for $cwd" >> "$LOG_FILE"
            done
            jq "$jq_filter" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
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
          echo "{\"pid\": $handoff_pid, \"started\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"path\": \"$cwd\", \"handoff_from\": $current_pid}" > "$LOCK_FILE/meta.json"
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

    if command -v md5 &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd" | md5)
    elif command -v md5sum &>/dev/null; then
      LOCK_HASH=$(echo -n "$cwd" | md5sum | cut -d' ' -f1)
    else
      LOCK_HASH=$(echo -n "$cwd" | cksum | cut -d' ' -f1)
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
              # Process still running - exit
              exit 0
            fi
            # Stale lock - remove and retry
            rm -rf "$LOCK_FILE"
            if ! mkdir "$LOCK_FILE" 2>/dev/null; then
              exit 0
            fi
          else
            exit 0
          fi
        fi

        # Write lock metadata
        echo "$CLAUDE_PID" > "$LOCK_FILE/pid"
        echo "{\"pid\": $CLAUDE_PID, \"started\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"path\": \"$cwd\"}" > "$LOCK_FILE/meta.json"

        # Monitor loop (same as SessionStart)
        current_pid=$CLAUDE_PID
        while true; do
          while kill -0 $current_pid 2>/dev/null; do
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
              tmp_file=$(mktemp)
              jq_filter='.'
              for sid in $dead_sids; do
                jq_filter="$jq_filter | del(.sessions[\"$sid\"])"
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up stale session $sid for $cwd" >> "$LOG_FILE"
              done
              jq "$jq_filter" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
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
            echo "{\"pid\": $handoff_pid, \"started\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"path\": \"$cwd\", \"handoff_from\": $current_pid}" > "$LOCK_FILE/meta.json"
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

    current_state=$(jq -r --arg sid "$session_id" '.sessions[$sid].state // "idle"' "$STATE_FILE" 2>/dev/null)

    if [ "$current_state" = "compacting" ]; then
      new_state="working"
      should_publish=true
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | PostToolUse: compacting->working transition" >> "$LOG_FILE"
    elif [ "$current_state" = "working" ]; then
      # Update heartbeat timestamp
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      tmp_file=$(mktemp)
      jq --arg sid "$session_id" \
         --arg ts "$timestamp" \
         '.sessions[$sid].updated_at = $ts' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
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

update_state() {
  # Skip if no session_id
  if [ -z "$session_id" ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | WARNING: Skipping state update (no session_id), event=$event, cwd=$cwd" >> "$LOG_FILE"
    return
  fi

  local tmp_file
  tmp_file=$(mktemp)

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
       --argjson pid "$PPID" \
       '.sessions[$sid] = ((.sessions[$sid] // {}) + {
         session_id: $sid,
         state: $state,
         cwd: $cwd,
         updated_at: $ts,
         pid: $pid
       })' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
  fi
}

update_state

# Publish state if transitioning from compacting → working
if [ "$should_publish" = "true" ]; then
  "$HOME/.claude/hooks/publish-state.sh" &>/dev/null &
  disown 2>/dev/null
fi

# Generate real-time description for UserPromptSubmit and Stop events
# This provides live context updates so users can glance at HUD to recall what's happening
generate_description=false
if [ "$event" = "Stop" ] || [ "$event" = "UserPromptSubmit" ]; then
  generate_description=true
fi

if [ "$generate_description" = "true" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  (
    context=$(tail -100 "$transcript_path" | grep -E '"type":"(user|assistant)"' | tail -20)

    if [ -z "$context" ]; then
      exit 0
    fi

    claude_cmd=$(command -v claude || echo "/opt/homebrew/bin/claude")

    # Run from $HOME with HUD_SUMMARY_GEN=1 to prevent recursive hook triggers
    # The hook will skip processing when this env var is set
    response=$(cd "$HOME" && HUD_SUMMARY_GEN=1 "$claude_cmd" -p \
      --no-session-persistence \
      --output-format json \
      --model haiku \
      "Extract from this coding session context what the user is currently working on. Return ONLY valid JSON, no markdown: {\"working_on\": \"brief description\"}. Context: $context" 2>/dev/null)

    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
      exit 0
    fi

    result=$(echo "$response" | jq -r '.result // empty')

    working_on=$(echo "$result" | jq -r '.working_on // empty' 2>/dev/null)

    if [ -z "$working_on" ]; then
      working_on=$(echo "$result" | sed -n 's/.*"working_on"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi

    if [ -n "$working_on" ] && [ -n "$session_id" ]; then
      tmp_file=$(mktemp)
      jq --arg sid "$session_id" \
         --arg working_on "$working_on" \
         '.sessions[$sid].working_on = $working_on' \
         "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
  ) &>/dev/null &
  disown 2>/dev/null
fi

exit 0
