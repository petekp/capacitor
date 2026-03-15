# Activation Boundary Closeout - 2026-03-15

## Automated Checks Completed

- `swift test --package-path apps/swift`
- `cargo test -p capacitor-core --quiet`
- `cargo test -p hud-hook --quiet`
- `./scripts/verify/verify.sh --layers 1,2,3 --json`
- `bash docs/plans/rust-swift-boundary-legibility/SHIP_CHECKLIST.md`

## Live Runtime Evidence Captured

- Runtime service was live at `127.0.0.1:7474` with an authenticated connection file in `~/.capacitor/runtime/runtime-service.json`.
- `bash docs/plans/rust-swift-boundary-legibility/SHIP_CHECKLIST.md` completed and printed the live runtime summary.
- The live summary confirmed the exact activation shapes relevant to the cleanup:
  - attached `tmux_pane` routes for:
    - `/users/petepetrash/code/attune`
    - `/users/petepetrash/code/pete-2025`
    - `/users/petepetrash/code/sanctuary`
    - `/users/petepetrash/code/capacitor`
  - detached `terminal_app` routes for:
    - `/users/petepetrash/code/claude-code-setup`
    - `/users/petepetrash/code/capacitor/apps/www`
- Attached routes still carried `terminal_app = null`, which is the intended runtime shape after the Swift shell-ranking seam removal.
- The live shell inventory showed attached tmux shell evidence for the same projects via `tmux_client_tty = /dev/ttys057`, which is consistent with Rust still owning route derivation while Swift now owns only explicit fallback.

## Manual QA Attempted

### Goal

Exercise the real project-card activation path through `scripts/ax/ax_runner.swift` and verify:

1. attached `tmux_pane` reuse for a route with `terminal_app = nil`
2. detached direct-shell activation for a routed `terminal_app`
3. activation log wording after the click

### Commands Attempted

- `swift scripts/ax/ax_runner.swift --scenario <tmp-scenario> --click-mode ax --process-timeout 30`
- `open -a /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`
- `./scripts/dev/restart-app.sh --alpha --swift-only`
- repeated AX window probes with a no-op `wait` scenario

### Blocker

- `ax_runner` consistently failed with:
  - `No AX windows were found for com.capacitor.app.debug.`
- This reproduced both before and after:
  - reopening the app bundle via `open -a ...`
  - a clean relaunch via `./scripts/dev/restart-app.sh --alpha --swift-only`
- Additional diagnosis showed this is not a simple “no window created” failure:
  - `CGWindowListCopyWindowInfo` still reported one onscreen `Capacitor` window for the debug-app pid.
  - The failure is specifically that the AX application tree exposes only recursive `AXApplication` and `AXMenuBar` nodes, with no `AXWindow` and no `ax.project-card.*` identifiers.
  - Temporarily forcing `floatingMode = false` and `alwaysOnTop = false` did not restore AX visibility; after a clean relaunch the app still had one ordinary layer-0 onscreen CG window, but `ax_runner` still reported no AX windows.
  - Direct AX attribute probes were also unstable across relaunches and sometimes returned `kAXErrorCannotComplete` for the live app pid, which reinforces that this is an accessibility/window-introspection issue rather than an activation-routing issue.
  - A follow-up experiment that explicitly set `NSWindow` accessibility role/subrole/element state in the app did not change the observed behavior and was reverted, so the remaining bug is likely deeper than missing default window accessibility metadata.
  - Even manually invoking the app’s own `Window > Capacitor` menu item through `System Events` left the process at `count of windows = 0` from the accessibility perspective.
- Because the app had no discoverable AX windows, the runner could not reach any `ax.project-card.*` element and no project-card click proof could be earned from the shell in this session.

## What Was Still Proven

- The cleanup is fully covered by automated tests and the verifier.
- The live runtime summary reflects the intended post-cleanup architecture:
  - Rust is still emitting attached route facts and detached direct-shell terminal-app facts.
  - Swift is no longer being asked to reconstruct terminal-app ranking from shell state in production code.
- The debug app and runtime service both launched successfully after the relaunch script.

## Later Recovery In The Same Session

- After additional relaunches, the AX-visible main window recovered and `scripts/ax/ax_runner.swift` started succeeding again.
- Broad repo-owned AX smoke then passed:
  - `bash scripts/ci/non-demo-ax-smoke.sh`
  - stable-profile card interactions completed for:
    - `ax.project-card.capacitor`
    - `ax.project-card.pete-2025`
  - frontier-profile details navigation completed for:
    - `ax.project-details.capacitor`
    - `ax.project-details.pete-2025`
    - `ax.nav.back-projects`
- Focused attached-route proof earned:
  - clicking `ax.project-card.pete-2025` succeeded through the named `Open in Terminal` accessibility action
  - frontmost app changed to `ghostty`
  - tmux client state changed from:
    - `/dev/ttys011 -> capacitor`
    - to `/dev/ttys011 -> dev`
- Later in the same session, a controlled state setup surfaced the detached-route card and the missing proofs were earned:
  - temporarily pinned `/Users/petepetrash/Code/claude-code-setup` in `~/.capacitor/projects.json`
  - temporarily removed `/Users/petepetrash/Code/claude-code-setup` from `com.capacitor.app.debug` `manuallyDormantProjects`
  - restored both pieces of user state after the proof and relaunched the app
- Detached `terminal_app` proof earned:
  - `ax.project-card.claude-code-setup` became visible in the AX tree
  - pre-click runtime route was:
    - `status = detached`
    - `kind = terminal_app`
    - `terminal_app = ghostty`
    - `session_name = null`
    - `pane_id = null`
    - `host_tty = null`
  - clicking `ax.project-card.claude-code-setup` succeeded through the named `Open in Terminal` accessibility action
  - frontmost app changed to `ghostty`
  - tmux client state changed from:
    - `/dev/ttys057 -> capacitor`
    - to `/dev/ttys057 -> claude-code-setup`
  - a new tmux session for `claude-code-setup` existed immediately after the click
  - the runtime route then converged to:
    - `status = attached`
    - `kind = tmux_pane`
    - `session_name = claude-code-setup`
    - `pane_id = %32`
    - `host_tty = /dev/ttys057`
- No-client fallback-ladder proof earned:
  - detached the sole tmux client `/dev/ttys057 -> claude-code-setup`
  - verified `tmux list-clients` returned no clients before the click
  - clicking `ax.project-card.pete-2025` succeeded through the named `Open in Terminal` accessibility action
  - app debug log captured:
    - `[TerminalLauncher] runActivationFlow noClient, launching attach-or-create session=dev`
    - `[TerminalLauncher] launchTerminalWithTmuxSession app=Ghostty session=dev path=/Users/petepetrash/Code/pete-2025`
  - frontmost app changed to `ghostty`
  - a fresh tmux client appeared as `/dev/ttys015 -> dev`
  - the runtime snapshot for `pete-2025` still reported the older attached route host tty (`/dev/ttys057`) immediately after the launch, so the authoritative proof here is the no-client log line plus the new tmux client rather than the stale cached `host_tty` field

## Remaining Manual Checks

- None for the activation-boundary cleanup itself.
- Residual QA caveat:
  - the debug app AX window tree can still intermittently disappear even when a real CG window exists
  - immediately after the no-client fallback launch, the routing snapshot's cached `host_tty` lagged behind the newly created tmux client

## Recommended Next Step

If the AX window disappears again, treat it as an intermittent accessibility/window-introspection bug in the debug app and recover it before trusting shell-driven UI QA. Follow-up work, if any, should focus on the intermittent AX window-tree disappearance and on whether the runtime snapshot should refresh `host_tty` more quickly after a no-client fallback launch.
