# Terminal Session Resolution Hardening - Adversarial Review 01

Date: 2026-05-25

## Scope

Reviewed the terminal/session hardening changes for:

- Ghostty direct-focus routing
- tmux fallback behavior
- Work Batch cockpit opening
- Work Batch row click behavior
- debug app launch identity
- focused Swift tests and live manual verification

## Findings

### Medium - Row tap could double-open a Work Batch

- Location: `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`
- Evidence: the first row hit-area patch added a parent `.onTapGesture` while the summary area remained a nested `Button(action: onOpen)`. In SwiftUI, this can allow both the child button and parent gesture to run from one user click depending on the hit path.
- Why it matters: for a stale or waiting binding, duplicate open calls could race and potentially launch two resume attempts.
- Fix applied: no-checkpoint rows now use one row-level tap path, with the summary rendered as content rather than a nested button. Checkpoint rows keep their explicit summary button and cockpit button, while the parent row tap returns early.
- Verification: `swift test --package-path apps/swift --filter 'GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests|WorkBatchAutoRouterTests|WorkBatchTaskSessionTests|AppStateWorkBatchOpenTests'` passed with 110 tests and 0 failures.

## Post-Fix Review

No medium, high, or critical findings remain after the fix.

Residual low risk:

- Project-card plain left-click is harder to exercise through automation than the context-menu `Open in Terminal` action. The source path is covered by resolver tests and the live context action, but a human pass should still click the visible card directly.

## Verdict

Clean after the medium finding was resolved.
