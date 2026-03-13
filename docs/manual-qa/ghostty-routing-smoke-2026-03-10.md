# Ghostty Routing Smoke - 2026-03-10

> Historical note. The project-card AX automation limitation in this session was resolved on 2026-03-13. The authoritative closeout proof now lives in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`.
> Historical note. The negative Ghostty native-launch result in this session was superseded on 2026-03-13 by `docs/manual-qa/ghostty-native-surface-matrix-2026-03-13.md`, and current shipped behavior now uses native Ghostty launch.

## Automated Checks Completed

- `bash docs/plans/ghostty-applescript/guard.sh`
- `cd apps/swift && swift test --filter 'TerminalLauncherTests|Ghostty.*Tests'`
- `cd apps/swift && swift test`
- `bash scripts/dev/agent-observe.sh health`
- `bash scripts/dev/restart-app.sh --swift-only`
- Verified debug app process launched: `CapacitorDebug.app/Contents/MacOS/Capacitor`
- Verified fresh app log activity from `AppState`, `RuntimeClient`, and `HookServerManager`
- Attempted project-card click automation via `scripts/ax/ax_runner.swift`; the runner attached to the debug bundle but hung before completing the card-click scenario in this environment, so the remaining card-click verification is treated as GUI-only
- Follow-up AX diagnosis:
  - `ax_runner` had an infinite traversal bug in cyclic AX trees; that is now fixed
  - after the fix, `ax_runner` reports `No AX windows were found for com.capacitor.app.debug`
  - WindowServer still reports an onscreen `Capacitor` window, so the remaining blocker is AX exposure of the debug app window, not app startup
- Live Ghostty AppleScript smoke:
  - `focus terminal id ...` successfully reselected an existing project tab
  - native Ghostty surface creation produced inert `👻` tabs/windows on local Ghostty 1.3.0, so the launch flow stayed on the prior path in this session

## Manual Checks Remaining

1. Open Capacitor and click a project card whose Ghostty tab is already open.
   Expected: the existing Ghostty tab for that project comes to the front without opening a new Ghostty surface.

2. Switch Ghostty to a different tab, then click the same project card again.
   Expected: Capacitor reselects the correct Ghostty tab.

3. Click a project card for a detached tmux session with no currently attached client.
   Expected: Capacitor attaches to the existing session instead of creating a duplicate session.

4. Temporarily deny Ghostty Automation permission or disable `macos-applescript`, then click a project card.
   Expected: Capacitor shows the explicit Ghostty automation failure message.

5. Trigger the project creation / resume flow that uses `TerminalScripts.launchWithCommand`.
   Expected in this 2026-03-10 session: Ghostty launches the resume command through the then-current launch path.

## Notes

- Native Ghostty routing is the shipped change.
- In this 2026-03-10 session, native Ghostty launch had not shipped yet.
- Current shipped behavior is the later 2026-03-13 native Ghostty launch migration.
