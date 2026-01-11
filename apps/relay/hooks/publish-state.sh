#!/bin/bash
# HUD Relay State Publisher
# Publishes Claude Code session state to the relay server
#
# Configuration via environment variables:
#   HUD_RELAY_URL    - Relay server URL (default: http://localhost:8787)
#   HUD_DEVICE_ID    - Device ID for this machine (required)
#   HUD_SECRET_KEY   - Shared secret for encryption (required)

# Debug log (comment out in production)
DEBUG_LOG="$HOME/.claude/hud-publish-debug.log"
log_debug() {
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $1" >> "$DEBUG_LOG"
}

log_debug "=== publish-state.sh started ==="

# Read config from ~/.claude/hud-relay.json if it exists
CONFIG_FILE="$HOME/.claude/hud-relay.json"
if [ -f "$CONFIG_FILE" ]; then
    HUD_RELAY_URL="${HUD_RELAY_URL:-$(jq -r '.relayUrl // empty' "$CONFIG_FILE")}"
    HUD_DEVICE_ID="${HUD_DEVICE_ID:-$(jq -r '.deviceId // empty' "$CONFIG_FILE")}"
    HUD_SECRET_KEY="${HUD_SECRET_KEY:-$(jq -r '.secretKey // empty' "$CONFIG_FILE")}"
fi

# Defaults
HUD_RELAY_URL="${HUD_RELAY_URL:-http://localhost:8787}"

# Validate required config
if [ -z "$HUD_DEVICE_ID" ] || [ -z "$HUD_SECRET_KEY" ]; then
    log_debug "Missing config - exiting"
    exit 0
fi

log_debug "Config loaded: URL=$HUD_RELAY_URL, DeviceID=$HUD_DEVICE_ID"

# Read hook input from stdin
INPUT=$(cat)

# Small delay to ensure hud-state-tracker.sh finishes updating state file first
# (hooks may run in parallel)
sleep 0.2

# Extract relevant fields from hook input
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

log_debug "Hook event: $HOOK_EVENT, CWD: $CWD"

# Normalize CWD to git root (project root) for consistent path matching
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    GIT_ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$GIT_ROOT" ]; then
        PROJECT_PATH="$GIT_ROOT"
    else
        PROJECT_PATH="$CWD"
    fi
else
    PROJECT_PATH="$CWD"
fi

# Read current status from hud-session-states.json (written by hud-state-tracker.sh)
# Try CWD first (exact match), then fall back to project root
STATUS_FILE="$HOME/.claude/hud-session-states.json"
if [ -f "$STATUS_FILE" ]; then
    # Try exact CWD path first
    PROJECT_STATUS=$(jq --arg path "$CWD" '.projects[$path] // null' "$STATUS_FILE")

    # If no match for CWD and CWD != PROJECT_PATH, try project root
    if [ "$PROJECT_STATUS" = "null" ] && [ "$CWD" != "$PROJECT_PATH" ]; then
        PROJECT_STATUS=$(jq --arg path "$PROJECT_PATH" '.projects[$path] // {}' "$STATUS_FILE")
    elif [ "$PROJECT_STATUS" = "null" ]; then
        PROJECT_STATUS="{}"
    fi

    STATE=$(echo "$PROJECT_STATUS" | jq -r '.state // "idle"')
    WORKING_ON=$(echo "$PROJECT_STATUS" | jq -r '.working_on // empty')
    NEXT_STEP=$(echo "$PROJECT_STATUS" | jq -r '.next_step // empty')
    CONTEXT_PERCENT=$(echo "$PROJECT_STATUS" | jq -r '.context_percent // empty')
else
    STATE="idle"
    WORKING_ON=""
    NEXT_STEP=""
    CONTEXT_PERCENT=""
fi

# Build the state payload using normalized PROJECT_PATH
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATE_JSON=$(jq -n \
    --arg path "$PROJECT_PATH" \
    --arg state "$STATE" \
    --arg workingOn "$WORKING_ON" \
    --arg nextStep "$NEXT_STEP" \
    --arg contextPercent "$CONTEXT_PERCENT" \
    --arg updatedAt "$TIMESTAMP" \
    '{
        projects: {
            ($path): {
                state: $state,
                workingOn: (if $workingOn == "" then null else $workingOn end),
                nextStep: (if $nextStep == "" then null else $nextStep end),
                contextPercent: (if $contextPercent == "" then null else ($contextPercent | tonumber) end),
                lastUpdated: $updatedAt
            }
        },
        activeProject: $path,
        updatedAt: $updatedAt
    }'
)

# For now, send unencrypted (encryption will be added with Swift client)
# In production, we'd encrypt with libsodium here
NONCE=$(openssl rand -base64 24)
CIPHERTEXT=$(echo "$STATE_JSON" | base64)

ENCRYPTED_MSG=$(jq -n \
    --arg nonce "$NONCE" \
    --arg ciphertext "$CIPHERTEXT" \
    '{nonce: $nonce, ciphertext: $ciphertext}'
)

log_debug "Publishing state=$STATE for path=$PROJECT_PATH"

# Publish to relay (async, don't wait for response)
# Use /usr/bin/curl with -4 for IPv4 to avoid SSL issues
/usr/bin/curl -4 -s -X POST \
    -H "Content-Type: application/json" \
    -d "$ENCRYPTED_MSG" \
    "${HUD_RELAY_URL}/api/v1/state/${HUD_DEVICE_ID}" \
    --max-time 5 \
    >> "$DEBUG_LOG" 2>&1 &

log_debug "Curl spawned in background"
exit 0
