# Terminal Launcher Hardening Adversarial Review 02

Date: 2026-05-26

## Reviewed Scope

Second-pass review of the same terminal-launcher hardening slice after Review 01:

- Terminal automation environment allowlist.
- Terminal command wrapper.
- Debug restart environment and wrong-build guardrails.
- Live proof artifacts and terminal activation documentation.

## Findings

No medium, high, or critical findings.

## Attack Notes

- Secret/host-env proof check: searched the changed source, tests, docs, and operator proof directory for concrete `OPENAI_API_KEY=`, `CAPACITOR_INGEST_KEY=`, `CODEX_THREAD_ID=`, `NO_COLOR=1`, `TERM=dumb`, and `sk-` style values. Matches were limited to test fixtures, policy text, and explicit `absent` proof markers; no captured secret values or dirty live env dumps were present.
- Environment policy check: the app launch env, AppleScript env, shell helper env, and terminal-launched command env now each use an allowlist or `env -i` wrapper. The remaining forwarded values are ordinary user/session basics needed for local terminal work: home/user/shell/tmp/locale/path and SSH agent socket.
- Manual-proof honesty check: the proof does not claim to repair already-running shells. It explicitly says existing sessions keep their old environment until closed or relaunched.
- Activation UX check: the live traces distinguish Work Batch cockpit re-entry from legacy project terminal fallback, and both reuse existing visible terminal evidence instead of launching blindly.

## Verification Reviewed

- Focused Swift launcher/session tests passed: 81 tests, 0 failures.
- Restart script Bats passed: 7 tests.
- Terminal activation state script Bats passed: 14 tests.
- SwiftFormat lint passed for touched Swift files.
- Shell syntax checks passed for restart scripts.
- Diff whitespace check passed for touched launcher/test/doc/proof files.
- Layer boundary verifier passed with `./scripts/verify/verify.sh --layers 1`.
- Correct Debug app live check confirmed `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app` was the running build during manual testing.

## Residual Risk

- Manual live coverage was strongest for Ghostty, tmux, and legacy project focus because those are the current product path. iTerm/Terminal.app behavior is covered by generated-script tests, not live app driving in this pass.
- Existing polluted Ghostty/Claude sessions may still look wrong until the user closes or resumes them through a clean launch. This is an intentional non-destructive tradeoff.
