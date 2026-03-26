## Summary

Completed the current frontier idea-to-run polish slice that was already in the worktree and validated it end-to-end.

Implemented behavior in the existing changes:
- Frontier profile now defaults to the curated idea-to-run surface: `workstreams` is off by default, while `methodRunner` and `windowAnchoring` stay on. Environment overrides still allow re-enabling `workstreams`.
- Project-card status presentation now prioritizes active or paused method runs over delegation review chips, so a live run or checkpoint is what the card surfaces first.
- The idea detail overlay and method selector were tightened for the run flow: the footer hides while a detail view is active, the overlay uses a denser action layout, and method selection scrolls within a bounded height.
- Method-runner real adapter launches now resolve worker cwd from the bridge project path when present, otherwise from the current directory, and they use a longer adapter timeout to better fit real execution.
- Added debug logging around built-in method listing and run launch to make frontier E2E diagnosis easier.

## Decisions

- Runs win over delegation chips in project-card presentation because the run/checkpoint state is the most urgent project-level signal.
- Frontier defaults now intentionally bias toward the idea-to-run loop instead of showing workstreams before that flow is integrated.
- Bridge mode should execute workers in the project root rather than the run root so prompt composition and worker subprocesses inherit the repo-local context they expect.

## Verification

- `swift test --package-path apps/swift --filter AppConfigTests` passed.
- `swift test --package-path apps/swift --filter StatusChipsRowTests` passed.
- `cargo test -p capacitor-core --bin method-runner` passed.
- `cargo fmt --check` passed.
- `cargo test -p capacitor-core` passed.
- `swift test --package-path apps/swift` failed once in `IdeaCapturePopoverTests.testFocusControllerDefersFocusUntilTextViewHasWindow`, then the isolated test passed and the full suite passed on rerun.

## Relay Artifact Note

The canonical relay output paths under `~/.capacitor/runs/...` were not writable in this sandbox, so this summary was written to the repo-local `handoffs/` directory instead.
