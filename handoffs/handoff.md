### Files Changed
- `core/capacitor-core/src/reduce/run_reducer.rs`
- `core/capacitor-core/tests/run_kernel_contract.rs`
- `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs`
- `.relay/method-runs/checkpoint-bridge/phases/step-8/seam-proof.md`
- `handoffs/handoff.md`

### Tests Run
- `cargo test -p capacitor-core --test run_kernel_contract scenario_emit_checkpoint_preserves_caller_supplied_checkpoint_id` — passed
- `cargo test -p capacitor-core --test run_kernel_contract scenario_reemitting_same_checkpoint_is_idempotent` — passed
- `cargo test -p capacitor-core --test run_kernel_contract scenario_submit_decision_validates_checkpoint_id` — passed
- `cargo test -p capacitor-core` — passed
- `cargo fmt --check` — passed
- `cargo clippy -p capacitor-core -- -D warnings` — passed

### Verification
Wrote the three Slice 1 seam regression tests first, observed them fail for the expected reasons, then made the reducer changes and reran the focused seam tests plus the full `capacitor-core` test suite, formatting check, and clippy gate. Wrote the proof artifact at `.relay/method-runs/checkpoint-bridge/phases/step-8/seam-proof.md`.

### Verdict
ISSUES FOUND

### Completion Claim
COMPLETE

### Issues Found
- The execution packet contains a contract inconsistency: its implementation note says `SubmitDecision` may accept `checkpoint_id = None` for backward compatibility, but Invariant 8 and Test Obligation `T3` require rejection. The code follows the stricter invariant/test contract.

### Next Steps
- Update the execution packet wording so the implementation notes match Invariant 8 and `T3`.
- Carry Slice 1’s stable checkpoint identity through the bridge emitter and Swift submission path without reintroducing implicit checkpoint selection.
