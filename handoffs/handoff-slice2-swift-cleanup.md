### Files Changed
- `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift`
- `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift`
- `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`
- `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
- `apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift`
- `.relay/method-runs/stale-delegation-session/phases/step-7/handoffs/handoff-slice2-swift-cleanup.md`

### Tests Run
- `swift test --package-path apps/swift --filter 'TerminalLauncherTests/testKillSessionTargetsNamedTmuxSession'` — passed
- `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests/testReconcileCompletionCleansUpDelegationResourcesEvenWhenCleanupFails'` — passed
- `swift test --package-path apps/swift` — passed (`426` tests, `1` skipped)
- `grep -R -n 'killSession' apps/swift/Sources/` — passed; showed the new method in `TmuxRouter.swift` and a live call in `DelegationLoopManager.swift`
- `./scripts/dev/restart-alpha-stable.sh` — failed in sandbox when writing `~/.capacitor/runtime-context.env`
- `CAPACITOR_RUNTIME_STATE_PERSIST=0 CAPACITOR_RUNTIME_DIR=/tmp/capacitor-runtime CAPACITOR_LEGACY_DAEMON_SOCKET=/tmp/capacitor-daemon.sock CAPACITOR_LEGACY_DAEMON_DIR=/tmp/capacitor-daemon ./scripts/dev/restart-alpha-stable.sh` — advanced past the write failure, then failed because an existing `hud-hook` listener was still bound to `127.0.0.1:7474` and the sandbox would not allow killing PID `7166`

### Verification
- `DelegationLoopManager` now funnels worker-completion mutations through a shared `completeDelegation(...)` helper so cleanup only runs after the runtime `complete` mutation succeeds.
- `cleanupCompletedDelegation(...)` clears cached attachment state, attempts tmux session kill, force-removes the managed worktree, and force-deletes the delegation branch as independent best-effort steps with logging.
- The new reconciliation test proves cleanup still attempts branch deletion even when forced worktree removal fails.

### Verdict
ISSUES FOUND

### Completion Claim
PARTIAL

### Issues Found
- `restart-alpha-stable.sh` could not be fully verified in this sandbox because it needs to write under `~/.capacitor/` and terminate an already-running `hud-hook` listener on port `7474`; both operations were denied by the environment rather than by the app code.

### Next Steps
- Re-run `./scripts/dev/restart-alpha-stable.sh` from an unsandboxed local shell, or first stop the existing `hud-hook` on port `7474` and allow writes to `~/.capacitor/`.
- Manually complete one real delegation and confirm the tmux session, worktree, and `pkp/delegation-*` branch disappear immediately after the runtime marks the worker `complete`.
