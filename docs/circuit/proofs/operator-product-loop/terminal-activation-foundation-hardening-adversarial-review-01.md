# Terminal Activation Foundation Hardening - Adversarial Review 01

Date: 2026-05-25 local.

## Scope

Reviewed the in-flight terminal activation foundation changes for:

- Project-card primary action routing.
- Work Batch card, checkpoint row, and terminal icon routing.
- Ghostty direct focus, selected/background tab behavior, and tmux switch fallback.
- Claude Code Work Batch focus/resume behavior.
- duplicate Debug app process handling.
- structured activation trace coverage.
- focused automated tests and live manual proof notes.

## Findings

### Medium - Work Batch row parent tap could double-run nested button actions

- Location: `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`
- Evidence: the row used a parent `.onTapGesture` while also rendering a terminal icon button and done-task unresolve buttons inside the same row. A click on a nested control could be interpreted as both the nested button action and the row open action.
- Why it matters: the affected actions can focus, wake, or resume a Claude Code Work Batch session. Double-running them is exactly the kind of session plumbing leak this slice is trying to remove.
- Fix applied: removed the parent row tap gesture and made the summary/header the single `onOpen` button. The terminal icon remains a separate cockpit button, and done-task unresolve buttons stay independent.
- Verification: focused Swift slice passed after the fix with 37 tests and 0 failures. A live terminal-icon click then focused the existing `Mobile Prototype Polish` cockpit with `surface="terminal_icon"` and did not create a new Ghostty window or Claude process.

## Post-Fix Findings

No medium, high, or critical findings remain in this review.

## Residual Low Risk

- `DebugLog.setTestObserver` still writes activation trace test lines into the real app debug log. This makes the helper output noisier after test runs, but it does not affect routing behavior or the live click result.

## Verdict

Clean after the medium finding was resolved.
