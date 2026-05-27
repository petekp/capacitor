# Terminal Launcher Environment Hardening

Date: 2026-05-26

## Source-Backed Failure Inventory

| Failure mode | Evidence | Policy | Change |
|---|---|---|---|
| Capacitor Debug launched from Codex inherits host-only env such as `NO_COLOR=1`, `TERM=dumb`, Codex temp `PATH`, and API-style secrets. | Live process inspection showed the debug app had Codex-flavored env. `scripts/dev/restart-app.sh` previously used `env -u` for only a few color keys. | The debug app should start from a narrow launch env; app feature/channel config belongs in Info.plist/config, not inherited host env. | `build_sanitized_debug_app_env` now launches the debug app with `env -i` plus only user/shell basics. |
| AppleScript automation inherits Capacitor's app env. | `DefaultAppleScriptClient.runOutput` previously did not set `process.environment`, so `/usr/bin/osascript` inherited the whole app env. | Terminal automation should not receive Codex/app secrets or no-color flags. | `DefaultAppleScriptClient` now uses `TerminalAutomationEnvironment.make()`. |
| Shell helper automation inherits Capacitor's app env. | `TerminalLauncher.runBashScriptWithResult` previously copied `ProcessInfo.processInfo.environment`. | Helper commands need only a controlled PATH and basic user context. | `TerminalLauncher.terminalAutomationEnvironment` now builds an allowlist environment. |
| Existing polluted Ghostty process keeps polluting new tabs. | Live process inspection showed Ghostty itself had `NO_COLOR=1`, `TERM=dumb`, Codex vars, app vars, API-style secrets, and a Codex-flavored `PATH`; already-open processes cannot be retroactively fixed. | New Claude/tmux commands launched by Capacitor should start from a narrow env even if Ghostty is already polluted. Existing shells keep their old env until closed. | `terminalUserCommand` wraps terminal-launched commands with `env -i HOME=... TERM=... PATH=... /bin/sh -c ...`. |
| Existing already-running Claude process remains desaturated. | Live process inspection showed the old Work Batch Claude process still had `NO_COLOR=1`. | Do not mutate or kill existing user sessions automatically. Re-entry should preserve sessions; relaunch/resume creates clean future processes. | Documented as residual live-state behavior; no automatic destructive cleanup. |

## Acceptance Criteria

- Project and Work Batch activation still prefer existing Ghostty/tmux cockpits before launch.
- Fresh terminal launches do not forward `NO_COLOR`, `TERM=dumb`, Codex env, Capacitor env, or API-style secrets from the app process.
- New Claude/tmux commands start with a narrow env and a normal PATH even if Ghostty itself is already running with polluted env.
- Existing terminal sessions are not killed or reset by the hardening.
- The correct repo-built Capacitor Debug app is restarted before manual checks.

## Verification

- `swift test --package-path apps/swift --filter 'TerminalLauncherTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|WorkBatchTaskSessionTests'`
- `bats tests/dev-scripts/restart-app.bats`
- `bats tests/dev-scripts/check-terminal-activation-state.bats`
- `./scripts/ci/swiftformat-lint.sh apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift`
- `bash -n scripts/dev/restart-app.sh scripts/dev/restart-alpha-stable.sh`
- `git diff --check -- apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift apps/swift/Tests/CapacitorTests/GhosttyTerminalDriverTests.swift scripts/dev/restart-app.sh tests/dev-scripts/restart-app.bats docs/circuit/terminal-activation-state-machine.md docs/circuit/proofs/operator-product-loop/terminal-launcher-environment-hardening-2026-05-26.md docs/circuit/proofs/operator-product-loop/live-ghostty-wrapper-sanitized-2026-05-26.txt`
- `./scripts/verify/verify.sh --layers 1`
- `./scripts/dev/restart-alpha-stable.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`
  - Confirmed front app path: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.
  - Confirmed no installed release or non-Debug Capacitor process was running.
- Running Capacitor Debug process environment after restart:
  - Present: `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `PATH`, `SSH_AUTH_SOCK`.
  - Absent: `NO_COLOR`, `TERM`, `COLORTERM`, `CODEX_*`, `OPENAI_*`, `CAPACITOR_*`, `LC_CTYPE`.
- Live dirty-Ghostty wrapper proof: `docs/circuit/proofs/operator-product-loop/live-ghostty-wrapper-sanitized-2026-05-26.txt`
  - Confirmed new terminal-launched command saw no `NO_COLOR`, no Codex env, no OpenAI/API-style secret presence, a safe PATH, `TERM=xterm-ghostty`, and `COLORTERM=truecolor`.
- Live Project-card click from the correct Debug build:
  - Clicked `capacitor` project card.
  - Trace recorded `route="work_batch_primary" action="open_work_batch" outcome="cockpit"`.
  - Trace recorded `route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing"` with `evidence="batch_binding,batch_worktree"`.
  - Ghostty became frontmost; no launch trace was emitted.
- Live legacy Project-card click from the correct Debug build:
  - Clicked `pete-2025` project card with no active Work Batch.
  - Trace recorded `route="legacy_project_terminal" action="activate_terminal" outcome="started"`.
  - Activation flow then recorded `route="direct_focus" action="focus_existing" outcome="focused"` with `evidence="ghostty_snapshot,working_directory_or_title"`.
- Adversarial reviews:
  - `docs/circuit/proofs/operator-product-loop/terminal-launcher-environment-hardening-adversarial-review-01.md`: no medium, high, or critical findings.
  - `docs/circuit/proofs/operator-product-loop/terminal-launcher-environment-hardening-adversarial-review-02.md`: no medium, high, or critical findings.
