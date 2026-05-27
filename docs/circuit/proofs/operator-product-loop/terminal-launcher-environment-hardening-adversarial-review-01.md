# Terminal Launcher Hardening Adversarial Review 01

Date: 2026-05-26

## Reviewed Scope

- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift`
- `scripts/dev/restart-app.sh`
- `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
- `apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift`
- `tests/dev-scripts/restart-app.bats`
- `tests/dev-scripts/check-terminal-activation-state.bats`
- `docs/circuit/terminal-activation-state-machine.md`
- `docs/circuit/proofs/operator-product-loop/terminal-launcher-environment-hardening-2026-05-26.md`

## Findings

No medium, high, or critical findings.

## Attack Notes

- Host env leak path: `DefaultAppleScriptClient.runOutput` now sets a narrow `process.environment`; `TerminalLauncher.runBashScriptWithResult` no longer copies `ProcessInfo.processInfo.environment`; restart uses `env -i` before opening the Debug app.
- Dirty terminal parent path: `terminalUserCommand` wraps terminal-launched commands with `env -i` and a safe PATH, so a polluted Ghostty parent does not pass `NO_COLOR`, Codex env, Capacitor env, or API-style secrets into new Capacitor-launched commands.
- Re-entry path: live trace for the `capacitor` Project card ended at `outcome="focused_existing"` with `evidence="batch_binding,batch_worktree"` and did not emit a launch trace.
- Legacy direct-focus path: live trace for `pete-2025` fell through to legacy terminal activation and then focused an existing Ghostty match by snapshot/title evidence.
- Wrong-build path: restart and check scripts now reject installed release or non-Debug Capacitor processes before manual verification.

## Verification Reviewed

- `swift test --package-path apps/swift --filter 'TerminalLauncherTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|WorkBatchTaskSessionTests'`
- `bats tests/dev-scripts/restart-app.bats`
- `bats tests/dev-scripts/check-terminal-activation-state.bats`
- `./scripts/ci/swiftformat-lint.sh apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift`
- `bash -n scripts/dev/restart-app.sh scripts/dev/restart-alpha-stable.sh`
- `git diff --check -- ...`
- `./scripts/verify/verify.sh --layers 1`
- Live Debug build restart and `check-terminal-activation-state`.
- Live Ghostty wrapper proof at `docs/circuit/proofs/operator-product-loop/live-ghostty-wrapper-sanitized-2026-05-26.txt`.

## Residual Risk

- Existing already-running terminal shells and Claude processes keep their old environment. This is intentional to preserve user sessions, but those old sessions may remain desaturated until the user closes or resumes them through a fresh clean launch.
- iTerm and Terminal.app use the same command wrapper and tests cover the generated scripts, but this manual pass focused on Ghostty because Ghostty is the active product path for this slice.
