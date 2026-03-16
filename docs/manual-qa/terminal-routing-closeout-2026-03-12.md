# Terminal Routing Closeout - 2026-03-12

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Automated Checks Completed

- `cargo test -p hud-hook runtime_snapshot_recomputes_routing_from_seeded_snapshot_on_startup -- --nocapture`
- `cargo test -p hud-hook runtime_snapshot_recomputes_routing_from_seeded_snapshot_on_startup --release -- --nocapture`
- `cargo test -p capacitor-core ffi_ingest_shell_signal_derives_tmux_pane_routing -- --nocapture`
- `bash docs/plans/terminal-routing-foundation/guard.sh`
- `./scripts/dev/restart-app.sh`
- `bash docs/plans/terminal-routing-foundation/SHIP_CHECKLIST.md`

## Root Cause

- The live runtime-service gap was not a reducer bug.
- `~/.local/bin/hud-hook` is a symlink to `target/release/hud-hook`.
- The live runtime-service process was still running the March 9, 2026 release build.
- Rebuilding `target/release/hud-hook` and relaunching the debug app restored live routing immediately.

## Live Evidence Earned

- Runtime snapshot after relaunch:
  - `routing_count = 8`
  - `tmux_pane_count = 2`
- Live `tmux_pane` routes now exist for:
  - `/users/petepetrash/code/sanctuary`
  - `/users/petepetrash/code/capacitor`
- Live app log evidence:
  - repeated `RoutingStateStore.applyRuntimeRoutingViews ... count=8`
  - `[TerminalLauncher] launchTerminalWithTmuxSession app=Ghostty session=sanctuary path=/Users/petepetrash/Code/sanctuary`
- Attached live `tmux_pane` routes now exist for:
  - `/users/petepetrash/code/sanctuary` with `host_tty = /dev/ttys020`
  - `/users/petepetrash/code/capacitor` with `host_tty = /dev/ttys022`
- The relaunched app successfully adopted and then relaunched its own `hud-hook serve` child after the manual service handoff.

## Manual Checks Remaining At 2026-03-12

1. Ghostty same-tab route proof
2. Ghostty cross-tab route proof
3. Ghostty detached-session reuse proof
4. Ghostty stale-pane fallback proof
5. One live iTerm activation proof
6. One live Terminal activation proof

## Environment Notes

- CLI AX automation from this shell can click visible project cards again, but the broader multi-step cards scenario still times out once the UI leaves the card list.
- A Terminal host shell was seeded and runtime state now shows an attached capacitor pane on `/dev/ttys022`, but this session still did not capture a fresh `[ScriptedTerminalDriver] app=Terminal ... matched=true` click log.
- Runtime-service tokens are ephemeral; always read `~/.capacitor/runtime/runtime-service.json` before querying `/runtime/snapshot`.

## 2026-03-13 Follow-Up

### Root Causes

- The remaining `sanctuary` failure was an AX harness bug, not an activation-core bug.
- `scripts/ax/ax_runner.swift` was centering visible mouse clicks on card rects that existed in the AX tree but were not hittable for `sanctuary` and `mcp-app-studio-starter`.
- Those project-card AX elements expose a named accessibility action containing `Open in Terminal`; invoking that action dispatches the correct card handler deterministically.
- The remaining `mcp-app-studio-starter` activation failure was real: `TmuxRouter.findSessionForPath` queried `tmux list-windows -a -F '#{session_name}\t#{pane_current_path}'`, which only reports the current pane path for each window.
- Because `mcp-app-studio-starter` lived in non-active pane `%1` inside shared session `dev`, session lookup missed the existing session and launched a fresh `mcp-app-studio-starter` tmux session instead of reusing `dev`.

### Automated Checks Completed

- `swift test --filter 'TerminalLauncherTests|RuntimeClientTests|RoutingStateStoreTests|AppStateSessionObservationTests'`
- `swiftc -typecheck scripts/ax/ax_runner.swift`
- `bash docs/plans/terminal-routing-foundation/guard.sh`

### Live Evidence Earned

- After updating `TmuxRouter.findSessionForPath` to use `tmux list-panes -a`, a visible card click on `ax.project-card.mcp-app-studio-starter` moved tmux client `/dev/ttys009` to `session=dev pane=%1 path=/Users/petepetrash/Code/aui/mcp-app-studio-starter`.
- After updating `scripts/ax/ax_runner.swift` to prefer named accessibility actions, a visible card click on `ax.project-card.sanctuary` moved tmux client `/dev/ttys009` to `session=1 pane=%2 path=/Users/petepetrash/Code/sanctuary`.
- Regression check: a visible card click on `ax.project-card.pete-2025` moved tmux client `/dev/ttys009` back to `session=dev pane=%0 path=/Users/petepetrash/Code/pete-2025`.
- Live runner evidence now includes `step.click.named_action` for the project-card clicks that previously no-op’d under visible mode.

### Manual Checks Still Needed After The First 2026-03-13 Fix Pass

1. Ghostty cross-tab route proof
2. Ghostty stale-pane fallback proof
3. One live iTerm activation proof
4. One live Terminal activation proof

## 2026-03-13 Convergence

### Additional Automated Checks Completed

- `swift test`
- `cargo test -p capacitor-core`
- `bash docs/plans/terminal-routing-foundation/SHIP_CHECKLIST.md`

### Final Live Evidence

- Ghostty same-tab route proof:
  - baseline `ax.project-card.pete-2025` click left Ghostty client `/dev/ttys009` on `session=dev pane=%0 path=/Users/petepetrash/Code/pete-2025`.
- Ghostty detached-session reuse proof:
  - starting from `session=dev pane=%0`, clicking `ax.project-card.sanctuary` attached the existing detached session and moved `/dev/ttys009` to `session=1 pane=%2 path=/Users/petepetrash/Code/sanctuary`.
- Ghostty cross-tab route proof:
  - Ghostty front window `tab-group-600003dfc2d0` was forced from selected tab `index=1 id=tab-145654640` to non-target tab `index=2 id=tab-130846cc0 name="pnpm dev"`.
  - clicking `ax.project-card.sanctuary` reselected tab `index=1 id=tab-145654640` and left tmux client `/dev/ttys009` on the routed sanctuary surface.
- Ghostty stale-pane fallback proof:
  - split session `1` to create replacement pane `%5`, killed routed pane `%2`, then clicked `ax.project-card.sanctuary`.
  - app log captured `[TmuxRouter] stale pane during select-window pane=%2`.
  - tmux client `/dev/ttys009` still landed on `session=1 pane=%5 path=/Users/petepetrash/Code/sanctuary`, proving session-level success after pane selection failed.
- Live Terminal host-driver proof:
  - seeded Terminal client `/dev/ttys017` on `session=capacitor pane=%6`.
  - clicking `ax.project-card.capacitor` made Terminal frontmost and logged `[ScriptedTerminalDriver] app=Terminal tty=/dev/ttys017 matched=true`.
- Live iTerm host-driver proof:
  - seeded iTerm client `/dev/ttys030` on `session=mcp-app-studio-starter pane=%7`.
  - clicking `ax.project-card.mcp-app-studio-starter` made iTerm2 frontmost, moved that client to `session=dev pane=%1 path=/Users/petepetrash/Code/aui/mcp-app-studio-starter`, and logged `[ScriptedTerminalDriver] app=iTerm2 tty=/dev/ttys030 matched=true`.

### Manual Gate Status

- Ghostty same-tab route proof captured
- Ghostty cross-tab route proof captured
- Ghostty detached-session reuse proof captured
- Ghostty stale-pane fallback proof captured
- One live iTerm activation proof captured
- One live Terminal activation proof captured

## 2026-03-13 Host Adapter Follow-Up

### Root Cause

- The new host-adapter launch refactor surfaced a real live bug in the retained host launch mechanism.
- iTerm and Terminal.app both selected the correct app and came frontmost, but the old `System Events` keystroke path was still too brittle for no-client attach-or-create proof.
- In Terminal.app, the live buffer captured a mangled tmux command:
  - expected: `tmux new-session -A -s 'capacitor' -c '/Users/petepetrash/Code/capacitor'`
  - actual: `tmux newsession A s 'capacitor' c '/Users/petepetrash/Code/capacitor'`
- The fix was to keep the same open-plus-delay launch strategy but replace `System Events` keystrokes with direct app automation:
  - iTerm: `write text`
  - Terminal.app: `do script ... in front window`

### Additional Automated Checks Completed

- `cd apps/swift && swift test --filter 'TerminalLauncherTests|ITermTerminalDriverTests|TerminalAppTerminalDriverTests'`
- `bash scripts/dev/restart-app.sh --alpha --swift-only`

### Final Host-Adapter Live Evidence

- iTerm no-client attach-or-create proof:
  - starting from zero tmux clients and a fresh iTerm shell on `pete-2025`, clicking `ax.project-card.pete-2025` logged `[TerminalLauncher] launchTerminalWithTmuxSession app=iTerm2 session=dev path=/Users/petepetrash/Code/pete-2025`.
  - iTerm2 became frontmost.
  - tmux client `/dev/ttys041` attached to session `dev`.
- iTerm existing-client focus proof:
  - with tmux client `/dev/ttys041` already attached to `dev`, clicking `ax.project-card.pete-2025` kept iTerm2 frontmost and logged `[ITermTerminalDriver] tty=/dev/ttys041 matched=true`.
- Terminal.app no-client attach-or-create proof:
  - starting from zero tmux clients and a fresh Terminal shell on `capacitor`, clicking `ax.project-card.capacitor` logged `[TerminalLauncher] launchTerminalWithTmuxSession app=Terminal session=capacitor path=/Users/petepetrash/Code/capacitor`.
  - Terminal became frontmost.
  - tmux client `/dev/ttys042` attached to session `capacitor`.
- Terminal.app existing-client focus proof:
  - with tmux client `/dev/ttys042` already attached to `capacitor`, clicking `ax.project-card.capacitor` kept Terminal frontmost and logged `[TerminalAppTerminalDriver] tty=/dev/ttys042 matched=true`.

### Manual Gate Status After Host Adapter Follow-Up

- Ghostty same-tab route proof captured
- Ghostty cross-tab route proof captured
- Ghostty detached-session reuse proof captured
- Ghostty stale-pane fallback proof captured
- iTerm no-client attach-or-create proof captured
- iTerm existing-client focus proof captured
- Terminal.app no-client attach-or-create proof captured
- Terminal.app existing-client focus proof captured

## 2026-03-13 Rigorous All-Terminals QA

### Additional Live Evidence

- Ghostty no-client attach-or-create proof:
  - starting from zero tmux clients and a fresh Ghostty window on `pete-2025`, clicking `ax.project-card.pete-2025` made Ghostty frontmost.
  - tmux client `/dev/ttys043` attached to session `dev`.
  - app log captured `[TerminalLauncher] launchTerminalWithTmuxSession app=Ghostty session=dev path=/Users/petepetrash/Code/pete-2025`.
- Ghostty existing-client session-switch proof:
  - with Ghostty client `/dev/ttys043` already attached to `dev`, clicking `ax.project-card.sanctuary` kept Ghostty frontmost.
  - the same tmux client moved to session `1`.
- Ghostty stale-pane fallback proof rerun:
  - created replacement pane `%22` in session `1`, killed routed pane `%5`, then clicked `ax.project-card.sanctuary`.
  - app log captured `[TmuxRouter] stale pane during select-window pane=%5`.
  - tmux client `/dev/ttys043` stayed on session `1` and landed on replacement pane `%22`.

### QA Harness Note

- During the Ghostty rerun pass, the app window briefly disappeared from the AX tree after a restart cycle.
- Reopening the app from the Dock `Open` action restored the window and allowed the Ghostty card-click rerun to complete.
- This was treated as a transient QA harness recovery step, not a terminal integration failure.
