### Files Changed
- `core/capacitor-core/src/reduce/mod.rs`
- `core/capacitor-core/src/reduce/tests.rs`
- `.relay/method-runs/stale-delegation-session/phases/step-7/handoffs/handoff-slice1-rust-routing.md`
- `handoffs/handoff-slice1-rust-routing.md`

### Tests Run
- `cargo test -p capacitor-core --lib reduce::tests::test_delegation_worktree_deprioritized_in_routing -- --exact` - passed
- `cargo test -p capacitor-core --lib reduce::tests::test_delegation_session_fallback_when_only_candidate -- --exact` - passed
- `cargo test -p capacitor-core --lib reduce::tests::test_delegation_worktree_state_priority_doesnt_override -- --exact` - passed
- `cargo test -p capacitor-core --lib reduce::tests::routing_deprioritizes_working_worktree_over_idle_main_session -- --exact` - passed
- `cargo test -p capacitor-core` - passed
- `cargo fmt -p capacitor-core --check` - passed
- `cargo clippy -p capacitor-core -- -D warnings` - passed

### Verification
- Added the three requested reducer regression tests for routing preference and fallback behavior in `core/capacitor-core/src/reduce/tests.rs`.
- Reproduced the bug first: the project-root shell lost to the managed-worktree shell until the reducer treated worktree status as a higher-order ranking signal.
- Fixed `managed_worktree_root()` so it recognizes a worktree root path itself, not only descendants beneath it.
- Reused `managed_worktree_root()` via `is_path_in_managed_worktree()` so shell and tmux inventory selection share the same detection seam.
- Changed routing selection so non-worktree shells and tmux panes outrank managed-worktree candidates, while worktree candidates remain eligible as fallback evidence.
- Updated the broader `routing_deprioritizes_working_worktree_over_idle_main_session` test to use snapshot fixtures, because the reducer has no hook event that directly materializes an `Idle` session.

### Verdict
CLEAN

### Completion Claim
COMPLETE

### Issues Found
None

### Next Steps
- Slice 2 should decide whether activation-time shell selection in `select_shell_for_activation()` should mirror the same managed-worktree deprioritization, or remain scoped to persisted project routing only.
- If we keep the behavior scoped to persisted routing, add a narrow activation test that locks in that boundary explicitly.
