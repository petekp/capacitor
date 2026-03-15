# Resume: Continue Verifier-Backed Hardening

## Mission
Continue hardening Capacitor with TDD- and verifier-backed slices. Two uncommitted hardening slices are already complete in this worktree: the runtime bootstrap health contract and the hook/setup relative-symlink boundary.

## Resume Point
- Last meaningful action: fixed relative `hud-hook` symlink handling in `runtime_setup.rs`, added `.verifier/specs/HookSetupContracts.py`, then ran `cargo test -p capacitor-core runtime_setup::tests:: -- --nocapture`, `./scripts/verify/verify.sh`, and `./scripts/verify/verify.sh --layers 1 --evolve`, all green.
- Next command or file to open: `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs:213`
- Success criterion for the next step: choose the next high-value invariant to harden, express it first as a failing test or verifier rule, and keep the current green checks green.

## Current State
- Done: runtime health now proves identity plus liveness. Rust and Swift both require `status=ok`, `protocol_version=1`, `auth_mode=bearer`, and `service_mode=bootstrap_only`.
- Done: valid relative `~/.local/bin/hud-hook` symlinks are now resolved relative to the symlink parent, so they no longer surface as false `SymlinkBroken` failures and reinstall logic stays idempotent.
- In progress: broader architectural hardening pass. The strongest next candidate is still `runtime_setup.rs`, because it remains one of the Layer 3 nesting warnings and still concentrates status synthesis, binary probing, and settings mutation.
- Not yet decided: whether the next slice should stay in setup/policy/settings ownership or move to another subsystem with a better evidence-backed gap.

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `pkp/activation-boundary-closeout`
- Working tree: dirty
- Current hardening changes:
  - `/Users/petepetrash/Code/capacitor/.verifier/specs/RuntimeBoundaryContracts.py`
  - `/Users/petepetrash/Code/capacitor/.verifier/structural.yaml`
  - `/Users/petepetrash/Code/capacitor/.verifier/specs/HookSetupContracts.py`
  - `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_service/mod.rs`
  - `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs`
  - `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/HookServerManager.swift`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/AppStateTerminalActivationTests.swift`
- Unrelated dirty-tree changes to preserve:
  - `/Users/petepetrash/Code/capacitor/CLAUDE.md`
  - `/Users/petepetrash/Code/capacitor/README.md`
  - `/Users/petepetrash/Code/capacitor/apps/www/app/guide/page.tsx`
  - `/Users/petepetrash/Code/capacitor/apps/www/public/logo.svg`
  - `/Users/petepetrash/Code/capacitor/assets/logo.svg`
  - `/Users/petepetrash/Code/capacitor/docs/manual-qa/activation-boundary-closeout-2026-03-15.md`
  - `/Users/petepetrash/Code/capacitor/guide-full-page.jpeg`
  - untracked `/Users/petepetrash/Code/capacitor/.claude/worktrees/`
- Recent commit: `ce0aced Finish activation boundary cleanup and verifier rollout`

## Key Artifacts
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_service/mod.rs:148`
  - `probe_health()` now validates the bootstrap contract before accepting health.
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:3`
  - `RuntimeHealth` now decodes `auth_mode` and `service_mode` and centralizes compatibility.
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/HookServerManager.swift:390`
  - health checks now reuse the same bootstrap compatibility rule instead of `status == "ok"`.
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs:213`
  - hook status now resolves symlink targets through a shared helper.
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs:741`
  - `resolve_symlink_target(...)` is the new shared symlink boundary.
- `/Users/petepetrash/Code/capacitor/.verifier/specs/HookSetupContracts.py`
  - Layer 2 guard for the setup symlink contract and its regression tests.
- `/Users/petepetrash/Code/capacitor/.verifier/reports/last-run.json`
  - most recent full verify is green; only pre-existing Layer 3 nesting warnings remain.

## Project Rules
- Start bug and hardening loops with a failing test or failing verifier artifact when a good seam exists.
- Run `git worktree list` first in fresh sessions.
- Do not revert unrelated user changes.
- Bias toward TDD and verifier-backed changes instead of reasoning-only edits.
- Use `apply_patch` for manual file edits.
- Branches should use the `pkp/` prefix.

## Established Decisions
- Runtime health is an architectural identity contract, not just a liveness ping.
- Relative hook symlinks are valid installs and must resolve relative to the symlink’s parent directory.
- The verifier is the place to lock these seams so they cannot silently loosen later.

## Assumptions
- The next best hardening slice is probably further decomposition or boundary ratcheting inside `runtime_setup.rs`, because Layer 3 still flags it and it still owns multiple responsibilities.
- `runtime_state/snapshot.rs` is another candidate because it still carries a Layer 3 warning, but its contract surface is now materially better protected than before.

## Verification State
- Passed: `cargo test -p capacitor-core runtime_health_ -- --nocapture`
- Passed: `cargo test -p capacitor-core validate_bootstrap_contract -- --nocapture`
- Passed: `cd apps/swift && swift test --filter 'RuntimeClientTests|HookServerManagerTests|AppStateTerminalActivationTests'`
- Passed: `cargo test -p capacitor-core runtime_setup::tests:: -- --nocapture`
- Passed: `./scripts/verify/verify.sh`
- Passed: `./scripts/verify/verify.sh --layers 1 --evolve`
- Failed during red phase:
  - `cargo test -p capacitor-core runtime_health_rejects_unexpected_ -- --nocapture`
    - proved the old health path was accepting status-only responses.
  - `cargo test -p capacitor-core relative_symlink -- --nocapture`
    - failed with `SymlinkBroken { target: "../../build/hud-hook", reason: "Symlink target no longer exists..." }`, which was the decisive setup bug.
- Not run:
  - `cd apps/swift && swift test` after the relative-symlink slice, because that slice only touched Rust setup code
  - any manual QA after the setup slice

## Rejected Paths
- Do not reintroduce status-only runtime health checks in Rust or Swift.
- Do not use raw `read_link(...).exists()` logic for hook health; it misclassifies valid relative symlinks.
- Do not revert unrelated dirty-tree changes while continuing the hardening work.

## Open Questions / Risks
- `runtime_setup.rs` still exceeds the Layer 3 nesting threshold, so correctness may be improving faster than legibility.
- `runtime_state/snapshot.rs` also still exceeds the Layer 3 nesting threshold.
- The worktree contains unrelated app/docs/assets changes, so future edits should stay tightly scoped.

## Notes for the Next Agent
- `scripts/gather-git-state.sh` does not exist in this repo.
- There is no repo `copy-to-clipboard.sh`; use `pbcopy` on this machine.
- `pbcopy` is available at `/usr/bin/pbcopy`.
