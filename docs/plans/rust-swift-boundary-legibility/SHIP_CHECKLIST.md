#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"
RUNTIME_CONNECTION="$HOME/.capacitor/runtime/runtime-service.json"

cd "$ROOT"

echo "== Automated release gates =="
bash docs/plans/rust-swift-boundary-legibility/guard.sh
cargo test -p capacitor-core
swift test --package-path apps/swift --filter 'ActivationPolicyTests|TerminalLauncherTests|RuntimeClientTests|SupportedTerminalAppTests|AppStateSessionObservationTests'
swift test --package-path apps/swift
swift build --package-path apps/swift

echo
echo "== Optional live runtime summary =="
if [ -f "$RUNTIME_CONNECTION" ]; then
  RUNTIME_PORT="$(jq -er '.port' "$RUNTIME_CONNECTION")"
  RUNTIME_TOKEN="$(jq -er '.auth_token' "$RUNTIME_CONNECTION")"
  curl -fsS \
    -H "Authorization: Bearer ${RUNTIME_TOKEN}" \
    "http://127.0.0.1:${RUNTIME_PORT}/runtime/snapshot" | \
    jq '{routing: [.routing[] | {project_path, kind: .target.kind, session_name: .target.session_name, pane_id: .target.pane_id, host_tty: .target.host_tty, terminal_app: .target.terminal_app}], shells: ([.shells[] | {cwd, parent_app, tmux_session, tmux_client_tty, tty, updated_at}] | sort_by(.updated_at) | reverse | .[:20])}'
else
  echo "runtime service connection file not found at $RUNTIME_CONNECTION; skipping live snapshot summary"
fi

echo
echo "== Residue sweep =="
echo "[ ] All completed-slice residue queries return zero matches"
echo "[ ] No migration-only debug helpers, adapters, or scratch files remain"
echo "[ ] No stale symbols remain for runtime_activation / fetchRuntimeConfig / fetchCoreRoutingDiagnostics / DebugShellStateCard"
echo "[ ] No migration-only TODO/FIXME markers remain"

echo
echo "== Manual-only checks =="
echo "[ ] Attached tmux route with terminal_app=nil still focuses the expected host terminal"
echo "[ ] Detached direct-shell route still prefers the routed terminal host"
echo "[ ] No-client activation still chooses the explicit fallback ladder"
echo "[ ] Activation logs and diagnostics distinguish runtime facts from Swift policy interpretation"

echo
echo "== Ship decision =="
echo "Ready to ship: yes / no"
echo "Remaining blockers:"
echo "  - <blocker or None>"
echo "Evidence summary:"
echo "  - guard.sh, cargo test, swift test, swift build"
