#!/bin/bash
# Device Pairing Script for HUD Relay
# Generates pairing QR code for mobile devices
#
# Usage: ./pair-device.sh [relay-url]
# Default relay URL: https://hud-relay.<your-account>.workers.dev

set -e

RELAY_URL="${1:-http://localhost:8787}"
CONFIG_FILE="$HOME/.claude/hud-relay.json"

generate_device_id() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

generate_secret_key() {
    openssl rand -base64 32
}

if [ -f "$CONFIG_FILE" ]; then
    echo "Existing configuration found at $CONFIG_FILE"
    DEVICE_ID=$(jq -r '.deviceId' "$CONFIG_FILE")
    SECRET_KEY=$(jq -r '.secretKey' "$CONFIG_FILE")
    EXISTING_URL=$(jq -r '.relayUrl' "$CONFIG_FILE")

    if [ "$RELAY_URL" != "$EXISTING_URL" ]; then
        echo "Warning: Relay URL differs from existing config."
        echo "  Existing: $EXISTING_URL"
        echo "  New:      $RELAY_URL"
        read -p "Update relay URL? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            jq --arg url "$RELAY_URL" '.relayUrl = $url' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            echo "Updated relay URL."
        fi
    fi
else
    mkdir -p "$(dirname "$CONFIG_FILE")"
    DEVICE_ID=$(generate_device_id)
    SECRET_KEY=$(generate_secret_key)

    cat > "$CONFIG_FILE" << EOF
{
    "relayUrl": "$RELAY_URL",
    "deviceId": "$DEVICE_ID",
    "secretKey": "$SECRET_KEY"
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo "Created new configuration at $CONFIG_FILE"
fi

PAIRING_DATA=$(jq -c . "$CONFIG_FILE")

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    HUD RELAY PAIRING"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Device ID: $DEVICE_ID"
echo "Relay URL: $RELAY_URL"
echo ""

if command -v qrencode &> /dev/null; then
    echo "Scan this QR code with your mobile HUD app:"
    echo ""
    echo "$PAIRING_DATA" | qrencode -t ANSIUTF8
    echo ""
else
    echo "To display QR code, install qrencode:"
    echo "  brew install qrencode"
    echo ""
    echo "Or manually enter this pairing data in your mobile app:"
    echo ""
    echo "$PAIRING_DATA"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "1. Scan the QR code with the Claude HUD mobile app"
echo "2. Install the publish-state hook in Claude Code:"
echo "   cp apps/relay/hooks/publish-state.sh ~/.claude/hooks/"
echo "   # Add to settings.json: { \"hooks\": { \"Stop\": [\"~/.claude/hooks/publish-state.sh\"] } }"
echo "3. Deploy the relay worker (if not already):"
echo "   cd apps/relay && wrangler deploy"
echo ""
