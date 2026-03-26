## Summary

Completed the current frontier idea-to-run polish slice already present in the worktree and revalidated it end-to-end for the second implementation attempt.

Implemented behavior in the existing changes:
- Frontier profile now defaults to the curated idea-to-run surface: `workstreams` is off by default, while `methodRunner` and `windowAnchoring` stay on. Environment overrides still allow re-enabling `workstreams`.
- Project-card status presentation now prioritizes active or paused method runs over delegation review chips, so a live run or checkpoint is what the card surfaces first.
- The idea detail overlay and method selector were tightened for the run flow: the footer hides while a detail view is active, the overlay uses a denser action layout, and method selection scrolls within a bounded height.
- Method-runner real adapter launches now resolve worker cwd from the bridge project path when present, otherwise from the current working directory, and they use a longer adapter timeout to better fit real execution.
- Added debug logging around built-in method listing and run launch to make frontier E2E diagnosis easier.

## Decisions

- Runs win over delegation chips in project-card presentation because the run or checkpoint state is the most urgent project-level signal.
- Frontier defaults now intentionally bias toward the idea-to-run loop instead of surfacing workstreams before that flow is integrated.
- Bridge mode should execute workers in the project root rather than the run root so prompt composition and worker subprocesses inherit the repo-local context they expect.
- The longer real-adapter timeout was kept at 900 seconds to match real execution latency better and reduce false timeout failures during end-to-end runs.

## Verification

- `swift test --package-path apps/swift --filter AppConfigTests` passed.
- `swift test --package-path apps/swift --filter StatusChipsRowTests` passed.
- `cargo test -p capacitor-core --bin method-runner` passed.
- `cargo fmt --check` passed.
- `cargo test -p capacitor-core` passed.
- `swift test --package-path apps/swift` passed.

## Relay Artifact Note

The canonical relay output paths under `~/.capacitor/runs/3c28881d-c1aa-40d8-b82a-32d2c8ac7c9f/` are not writable in this sandbox, so this summary was written to the repo-local `handoffs/` directory instead.
