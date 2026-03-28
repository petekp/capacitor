### Files Changed
- `core/capacitor-core/src/domain/run_types.rs` — added `idea_id`, `idea_title`, and `idea_description` to `RunState` and `MutateRunCommand` with `#[serde(default)]`.
- `core/capacitor-core/src/reduce/run_reducer.rs` — persisted idea identity during `handle_create` and updated in-file `MutateRunCommand` test helpers.
- `core/capacitor-core/tests/run_kernel_contract.rs` — added idea identity roundtrip/default-`None` contract tests and updated command helpers.
- `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` — added `idea_*: None` in the runtime checkpoint mutation constructor to satisfy the expanded Rust struct.
- `core/capacitor-core/src/method_runner/run_status_reporter.rs` — added `idea_*: None` in the runtime status mutation constructor to satisfy the expanded Rust struct.
- `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs` — added `idea_*: None` in the test helper to satisfy the expanded Rust struct.
- `core/capacitor-core/tests/method_runner/checkpoint_bridge.rs` — added `idea_*: None` in the test helpers to satisfy the expanded Rust struct.
- `handoffs/handoff-item6-rust.md` — recorded this implementation handoff.

### Tests Run
- `cargo fmt --check` — PASS, 0 failures.
- `cargo test -p capacitor-core --test run_kernel_contract` — initial diagnostic FAIL, 0 tests executed, 2 compile errors from out-of-scope `MutateRunCommand` constructors missing `idea_*` fields; resolved with minimal follow-up edits listed above.
- `cargo clippy -- -D warnings` — PASS, 0 warnings, 0 failures.
- `cargo test` — PASS, 790 passed, 0 failed, 0 ignored, 0 measured; doc-tests: 0 passed, 0 failed.

### Verification
- Added contract coverage proving idea identity survives create plus snapshot recovery and defaults to `None` when omitted.
- Verified with the requested Rust commands: `cargo fmt --check`, `cargo clippy -- -D warnings`, and `cargo test`.
- `./scripts/verify/verify.sh` not run.

### Verdict
CLEAN

### Completion Claim
COMPLETE

### Issues Found
- None. Rust's exhaustive struct literals required four extra minimal `idea_*: None` constructor updates outside the requested slice; those compile fallouts are already resolved.

### Next Steps
- Thread real idea identity values from the higher-level run creation call sites so new runs can populate these fields from the product flow instead of defaulting to `None`.
