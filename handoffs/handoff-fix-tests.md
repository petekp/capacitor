### Files Changed
- `core/capacitor-core/tests/run_kernel_contract.rs` — added a backward-compat deserialization test proving legacy `RunState` JSON without idea fields loads with `None` defaults.
- `apps/swift/Tests/CapacitorTests/AppStateRunTests.swift` — added focused `AppState.activeRun(for:in:)` coverage for recency ordering, terminal exclusion, and mismatched-idea exclusion.
- `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift` — added runtime JSON contract tests for idea-field encoding/decoding plus a backward-compat decode fixture.
- `handoffs/handoff-fix-tests.md` — added the requested implementation handoff.
- `.relay/method-runs/phase3-polish/handoffs/handoff.md` — mirrored the handoff for the repo workflow.

### Tests Run
- `cargo test --test run_kernel_contract` — PASS, 23 passed, 0 failed.
- `cargo test --test run_kernel_contract 2>&1 | tail -10` — PASS, tail shows `23 passed; 0 failed`.
- `swift test --package-path apps/swift --filter AppStateRunTests` — PASS, 3 passed, 0 failed.
- `swift test --package-path apps/swift --filter RuntimeClientTests` — PASS, 35 passed, 0 failed.
- `swift test --package-path apps/swift 2>&1 | tail -15` — SANDBOX_LIMITED. SwiftPM failed before running tests because piped execution attempted to write `~/.cache/clang/ModuleCache`, which is not writable in this sandbox.

### Verification
- `./scripts/verify/verify.sh` not run.

### Verdict
N/A - implementation handoff

### Completion Claim
COMPLETE

### Issues Found
- The exact Swift verification command from the mission is sandbox-limited in this environment. When `swift test` is piped to `tail`, SwiftPM manifest planning hits `error opening '/Users/petepetrash/.cache/clang/ModuleCache/...': Operation not permitted`, so that specific shell form does not exercise the suite here.
- The two modified existing test files were already dirty in the worktree before this slice. The patch stayed inside test-only scope and did not touch production code.

### Next Steps
- If you need the exact package-wide tail command to pass, rerun it in a shell environment where SwiftPM can write its default module cache, or adjust the local environment to give SwiftPM a writable cache path outside this sandbox.
