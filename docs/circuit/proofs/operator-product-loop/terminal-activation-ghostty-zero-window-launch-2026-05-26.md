# Terminal Activation: Ghostty Zero-Window Launch

Date: 2026-05-26

## Scenario

Clicking a Project card should re-enter or launch the intended terminal cockpit. A live manual check found a bad edge case: Ghostty was running with no visible windows, the `pete-2025` tmux session existed but had no attached client, and clicking the `pete-2025` Project card failed to launch the cockpit.

## Failure Evidence

Before the fix, the clean live diagnostic showed:

```text
ghostty_windows:
tmux_clients:
tmux_sessions:
pete-2025|0|1
```

Clicking the `pete-2025` card produced:

```text
[TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="relaunch_needed" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="none" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_absent"
[TerminalActivation] surface="activation_flow" route="launch" action="launch_terminal" outcome="failed" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="terminal_driver:Ghostty,tmux_attach_command" reason="ghosttyAutomationUnavailable(Optional(\"318:346: execution error: Ghostty got an error: Can’t get window 1 whose id = \\\" \\\". Invalid index. (-1719)\"))"
```

The important clue is the whitespace-only Ghostty window id.

## Product Policy

- Ghostty snapshot rows with whitespace-only window IDs are not valid cockpit evidence.
- If Ghostty is running but its snapshot has no usable window IDs, Capacitor should create a new Ghostty window instead of trying to create a tab inside an invalid window.
- The operator should not need to understand this distinction; clicking the card should either foreground the right cockpit or launch it.

## Source Changes

- `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
  - Trims Ghostty window, tab, and terminal IDs while parsing snapshots.
  - Drops snapshot rows with blank or whitespace-only window IDs.
- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift`
  - Ignores blank or whitespace-only Ghostty window IDs when deciding whether a launch can reuse an existing window.
- `apps/swift/Tests/CapacitorTests/GhosttyAutomationClientTests.swift`
  - Added parser coverage for whitespace-only window IDs.
- `apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift`
  - Added launch coverage proving whitespace-only window IDs fall back to native window creation rather than tab creation.

## Verification

Passed:

```bash
swift test --package-path apps/swift --filter 'GhosttyAutomationClientTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests'
./scripts/dev/restart-alpha-stable.sh
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift
```

Focused Swift result:

- 66 tests passed.

Broad Swift result:

- The first broad Swift run exposed a transient timeout in `SessionSummarizerTests.testFingerprintCacheSkipsRedundantHaikuCall`.
- The failed test passed when rerun by itself.
- A second full `swift test --package-path apps/swift` run passed: 923 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing cases passed.

Restart result:

- `CapacitorDebug.app` relaunched from `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.
- Runtime service was reaped and restarted.

## Live Retest

After rebuilding and relaunching, Ghostty was returned to the same zero-window state:

```text
ghostty_windows:
tmux_clients:
pete-2025|0|1
```

Clicking the `pete-2025` Project card then produced:

```text
[TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="relaunch_needed" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="none" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_absent"
[TerminalActivation] surface="activation_flow" route="launch" action="launch_terminal" outcome="launched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="terminal_driver:Ghostty,tmux_attach_command"
[TerminalActivation] surface="activation_flow" route="launch" action="launch_tmux_attach" outcome="launched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="no_existing_terminal,no_tmux_client"
```

Terminal/process evidence after the click:

```text
ghostty_windows:
pete-2025:1:zsh - ""
tmux_clients:
/dev/ttys001|pete-2025|1779829746
tmux_sessions:
pete-2025|1|1
```

A narrow diagnostic window after the retest showed only the successful `21:09:04Z` activation sequence:

```bash
CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS=240 scripts/dev/check-terminal-activation-state.sh
```

## Remaining Risk

- Computer Use cannot inspect Ghostty directly in this environment, so the manual proof uses AppleScript/system diagnostics, tmux clients, and Capacitor activation traces.
- This verifies the Project-card launch path for a project with no Work Batches. Work Batch-card cockpit re-entry still needs a fresh live check with a real bound batch session.
