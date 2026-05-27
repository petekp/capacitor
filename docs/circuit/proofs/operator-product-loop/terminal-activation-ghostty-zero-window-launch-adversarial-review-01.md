# Adversarial Review: Ghostty Zero-Window Launch

Date: 2026-05-26

## Scope

Reviewed the live failure fix for Project-card terminal activation when Ghostty is running with no visible windows:

- `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift`
- `apps/swift/Tests/CapacitorTests/GhosttyAutomationClientTests.swift`
- `apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift`
- `docs/circuit/proofs/operator-product-loop/terminal-activation-ghostty-zero-window-launch-2026-05-26.md`

## Findings

No medium, high, or critical findings.

## Checks

- The failure was reproduced before the patch with a live `pete-2025` Project-card click.
- The patch rejects whitespace-only Ghostty window IDs at the snapshot boundary and defensively ignores them again at the launch-reuse boundary.
- Existing reuse behavior remains covered by `testLaunchUsesNewTabInFrontWindowWhenGhosttyIsAlreadyRunning`.
- The new fallback behavior is covered by `testLaunchIgnoresWhitespaceOnlyGhosttyWindowIDs`.
- The parser boundary is covered by `testParseSnapshotOutputSkipsWhitespaceOnlyWindowIDs`.
- The live retest produced a successful `launch_tmux_attach` route and attached `/dev/ttys001` to the `pete-2025` tmux session.

## Verification Reviewed

Passed:

```bash
swift test --package-path apps/swift --filter 'GhosttyAutomationClientTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests'
./scripts/dev/restart-alpha-stable.sh
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift
```

## Residual Risk

- The proof uses AppleScript/system diagnostics rather than direct Computer Use inspection of Ghostty because Computer Use is not allowed to use `com.mitchellh.ghostty` in this environment.
- Work Batch-card cockpit re-entry still needs a fresh live test with a real bound batch session.
