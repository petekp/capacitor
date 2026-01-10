#!/bin/bash
# HUD Relay State Publisher
# Publishes Claude Code session state to the relay server
#
# Configuration via environment variables:
#   HUD_RELAY_URL    - Relay server URL (default: http://localhost:8787)
#   HUD_DEVICE_ID    - Device ID for this machine (required)
#   HUD_SECRET_KEY   - Shared secret for encryption (required)

set -e

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
    # Silent exit if not configured - this is expected for users who haven't paired
    exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

# Extract relevant fields from hook input
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

# Read current status from hud-status.json if it exists
STATUS_FILE="$HOME/.claude/hud-status.json"
if [ -f "$STATUS_FILE" ]; then
    # Get status for current project
    PROJECT_STATUS=$(jq --arg path "$CWD" '.projects[$path] // {}' "$STATUS_FILE")
    STATE=$(echo "$PROJECT_STATUS" | jq -r '.state // "idle"')
    WORKING_ON=$(echo "$PROJECT_STATUS" | jq -r '.working_on // empty')
    NEXT_STEP=$(echo "$PROJECT_STATUS" | jq -r '.next_step // empty')
    CONTEXT_PERCENT=$(echo "$PROJECT_STATUS" | jq -r '.context.percent_used // empty')
else
    STATE="idle"
    WORKING_ON=""
    NEXT_STEP=""
    CONTEXT_PERCENT=""
fi

# Build the state payload
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATE_JSON=$(jq -n \
    --arg path "$CWD" \
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

# Publish to relay (async, don't wait for response)
curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$ENCRYPTED_MSG" \
    "${HUD_RELAY_URL}/api/v1/state/${HUD_DEVICE_ID}" \
    --max-time 2 \
    >/dev/null 2>&1 &

exit 0
