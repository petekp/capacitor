# Work Batch Leftover Shell Clean Resume

Date: 2026-05-26

## Problem

Clicking the `capacitor` Project card still opened a black-and-white Claude Code cockpit after terminal environment hardening.

Live inspection showed the card was correctly re-entering the existing Work Batch cockpit, but the assigned Claude process was old and still had `NO_COLOR=1`:

- PID: `50890`
- cwd: `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-some-kind-of-menu-bar-has-become`
- env included `NO_COLOR=1`

## Policy Fix

For stale, waiting, or done Work Batch bindings, Capacitor should focus first only when it can prove the assigned Claude process is still alive. If the only focusable surface is a leftover shell in the Work Batch worktree, Capacitor should skip focus and launch a clean Claude resume.

## Source Changes

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
  - `openCockpit(binding:)` now computes whether resume is allowed and whether the assigned Claude process is live.
  - It no longer focuses a leftover worktree shell before resume when no assigned Claude process is alive.
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
  - Existing stale focus-first coverage now requires assigned-process evidence.
  - Added coverage for a done binding where a leftover worktree shell can focus but no assigned Claude process is alive; expected result is clean resume, no focus attempt.

## Live Verification

1. Confirmed the polluted Claude process:
   - `NO_COLOR=1`
   - worktree cwd matched the `capacitor` Work Batch.
2. Terminated only that Claude process.
3. Clicked the `capacitor` card before the policy fix:
   - Trace showed `focused_existing`.
   - No Claude resume launched because the leftover shell focus succeeded.
4. Patched the policy and restarted the correct Debug build:
   - `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`
5. Clicked the `capacitor` card again:
   - Trace showed `route="claude_resume" action="resume_claude" outcome="launched"`.
   - Trace showed `route="work_batch_cockpit" action="open_cockpit" outcome="resume_launched"`.
6. Inspected the new resumed Claude process:
   - command: `claude --resume a164a2e9-6e7a-4d78-9280-a7519e9459ed ...`
   - cwd: `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-some-kind-of-menu-bar-has-become`
   - `NO_COLOR` absent
   - `TERM=xterm-ghostty`
   - `COLORTERM=truecolor`
   - `PATH=/Users/petepetrash/.local/bin:/Users/petepetrash/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`

## Verification Commands

- `swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests|WorkBatchTaskSessionTests|TerminalLauncherTests|GhosttyTerminalDriverTests'`
- `./scripts/ci/swiftformat-lint.sh apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `./scripts/dev/restart-alpha-stable.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`
