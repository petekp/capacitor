#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"
RUNTIME_CONNECTION="$HOME/.capacitor/runtime/runtime-service.json"

cd "$ROOT"

if [ ! -f "$RUNTIME_CONNECTION" ]; then
  echo "Ship gate failed: missing runtime service connection file at $RUNTIME_CONNECTION"
  exit 1
fi

RUNTIME_PORT="$(jq -er '.port' "$RUNTIME_CONNECTION")"
RUNTIME_TOKEN="$(jq -er '.auth_token' "$RUNTIME_CONNECTION")"
RUNTIME_URL="http://127.0.0.1:${RUNTIME_PORT}/runtime/snapshot"

echo "== Automated gates =="
(
  cd apps/swift
  swift test
)
bash docs/plans/terminal-routing-foundation/guard.sh

SNAPSHOT="$(curl -fsS -H "Authorization: Bearer ${RUNTIME_TOKEN}" "$RUNTIME_URL")"

ROUTING_COUNT="$(printf '%s' "$SNAPSHOT" | jq '.routing | length')"
if [ "$ROUTING_COUNT" -le 0 ]; then
  echo "Ship gate failed: expected non-zero live routing rows"
  exit 1
fi

TMUX_PANE_COUNT="$(printf '%s' "$SNAPSHOT" | jq '[.routing[] | select(.target.kind == "tmux_pane")] | length')"
if [ "$TMUX_PANE_COUNT" -le 0 ]; then
  echo "Ship gate failed: expected at least one live tmux_pane route"
  exit 1
fi

echo "routing_count=$ROUTING_COUNT"
echo "tmux_pane_count=$TMUX_PANE_COUNT"

echo
echo "== Manual evidence gates =="
echo "[ ] Ghostty same-tab route proof captured"
echo "[ ] Ghostty cross-tab route proof captured"
echo "[ ] Ghostty detached-session reuse proof captured"
echo "[ ] Ghostty stale-pane fallback proof captured"
echo "[ ] One live iTerm activation proof captured"
echo "[ ] One live Terminal activation proof captured"

echo
echo "Snapshot summary:"
printf '%s' "$SNAPSHOT" | jq '{routing_count: (.routing | length), tmux_pane_routes: [.routing[] | select(.target.kind == "tmux_pane")], fresh_tmux_shells: ([.shells[] | select(.tmux_session != null) | {cwd,parent_app,tmux_session,tmux_client_tty,tty,updated_at}] | sort_by(.updated_at) | reverse | .[:10])}'
