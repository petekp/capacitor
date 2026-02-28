### Terminal Activation Manual QA (Pane Focus Matrix)

- Date (UTC): 2026-02-16
- Tester: Codex
- Build/Commit: local branch `codex/pane-focus-by-project` (uncommitted at time of run)
- Environment: macOS 15.7.3, tmux 3.6a, Ghostty + iTerm2 + Terminal.app
- Fixture projects:
  - `/Users/petepetrash/cap-manual/pane-a`
  - `/Users/petepetrash/cap-manual/pane-b`
- Fixture tmux session: `cap-pane-focus` (single window, adjacent panes rooted at pane-a and pane-b)

#### Scenario Results
- Ghostty: PASS
  - Marker: `PANE-FOCUS-GHOSTTY-20260216T215248Z`
  - Window count: `before=1`, `after=1`
  - Active pane after click `pane-b`: `/Users/petepetrash/cap-manual/pane-b`
  - Active pane after click `pane-a`: `/Users/petepetrash/cap-manual/pane-a`
  - Log range: `~/.capacitor/daemon/app-debug.log:73304-73365`
- iTerm2: PASS
  - Marker: `PANE-FOCUS-ITERM2-20260216T215319Z`
  - Window count: `before=2`, `after=2`
  - Active pane after click `pane-b`: `/Users/petepetrash/cap-manual/pane-b`
  - Active pane after click `pane-a`: `/Users/petepetrash/cap-manual/pane-a`
  - Log range: `~/.capacitor/daemon/app-debug.log:73687-73730`
- Terminal.app: PASS (valid rerun)
  - Marker: `PANE-FOCUS-TERMINALAPP-RERUN-20260216T215455Z`
  - Window count: `before=2`, `after=2`
  - Active pane after click `pane-b`: `/Users/petepetrash/cap-manual/pane-b`
  - Active pane after click `pane-a`: `/Users/petepetrash/cap-manual/pane-a`
  - Log range: `~/.capacitor/daemon/app-debug.log:74745-74788`
- Terminal.app initial attempt: INVALID (daemon IPC unstable)
  - Marker: `PANE-FOCUS-TERMINALAPP-20260216T215348Z`
  - Failure mode: `DaemonClient.sendAndReceive ... Code=61 "Connection refused"`
  - Log range: `~/.capacitor/daemon/app-debug.log:74020-74062`

#### Routing Verification (Core)
- After HEM resolver patch, daemon snapshot resolution for fixture projects:
  - `/Users/petepetrash/cap-manual/pane-a` -> `attached tmux_session cap-pane-focus`
  - `/Users/petepetrash/cap-manual/pane-b` -> `detached tmux_session cap-pane-focus`
- This confirms non-first pane-path session matching is active before click testing.

#### UX/Behavior Notes
- No fan-out observed in valid runs: target terminal window count remained unchanged across both clicks in each host app.
- Click sequence `pane-b` then `pane-a` produced deterministic pane focus transitions in the same `cap-pane-focus` session.
- Ownership precedence logs matched host app:
  - iTerm2: `discoverTerminalOwningTTY iTerm owns tty=...`
  - Terminal.app: `discoverTerminalOwningTTY Terminal owns tty=...`
  - Ghostty: `activateTerminalByTTYDiscovery focused ghostty process tty=...`
