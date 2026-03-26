# Resume: Checkpoint Bridge — Step 9 Implementation via manage-codex

## Mission
Build the checkpoint bridge that connects the method runner's synchronous gates to the run kernel's async checkpoint UI. This is Step 9 of the research-to-implementation method — implementing the execution packet's 6 slices using manage-codex.

## Resume Point
- Last meaningful action: Step 8 seam proof passed — reducer now supports caller-supplied `checkpoint_id` + idempotent re-emission + decision validation (commit pending, changes in working tree)
- Next action: Commit the seam proof changes, then execute Step 9 of the research-to-implementation method — dispatch manage-codex to implement slices 2-6 against the execution packet
- Success criterion: All 14 test obligations (T1-T14) pass, full gate→checkpoint→decision→unblock loop works end-to-end

## Instructions

**Before doing anything else:**

1. Commit the uncommitted seam proof changes (Slice 1):
```bash
git add core/capacitor-core/src/reduce/run_reducer.rs \
  core/capacitor-core/tests/run_kernel_contract.rs \
  core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs
git commit -m "feat(run-kernel): add caller-supplied checkpoint_id, idempotent re-emission, and decision validation (Slice 1)"
```

2. Read the execution packet — it is the CHARTER for all implementation work:
   `.relay/method-runs/checkpoint-bridge/artifacts/execution-packet.md`

3. Execute Step 9 of the research-to-implementation method skill. The execution packet has 6 slices:
   - **Slice 1**: ✅ DONE (checkpoint identity + idempotence — seam proof)
   - **Slice 2**: Runtime-service client + bridge adapter skeleton (`BridgeInteractiveIO`)
   - **Slice 3**: Gate artifact synthesis + executor integration (`GateCheckpointContext`, manifest wiring)
   - **Slice 4**: `hud-hook` decision relay (post-`SubmitDecision` file write)
   - **Slice 5**: Swift run-checkpoint presentation (`RunCheckpointReviewWindow`)
   - **Slice 6**: Crash recovery + concurrent-run hardening

4. Use the research-to-implementation method's Step 9 protocol:
   - Copy the execution packet as the CHARTER
   - Dispatch manage-codex for implement → review → converge cycle
   - The execution packet has all invariants, test obligations, constraints, and verification commands

## Current State
- **Done:** Full research-to-implementation artifact chain (intent-brief → external-digest → internal-digest → constraints → options → decision-packet → adr → execution-packet → seam-proof)
- **Done:** Slice 1 — reducer supports `checkpoint_id`, idempotent re-emission, decision validation (3 new tests: T1, T2, T3)
- **Done (prior session):** Contract audit of real adapter layer, product flow validation (FileInteractiveIO, idea-to-ship YAML, CLI --real flag, checkpoint manifest generator)
- **In progress:** Slices 2-6 not yet started
- **Not done:** Step 10 ship review

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `1415832 Merge branch 'worktree-ui-refinement'`
- Working tree: dirty — 3 modified files from seam proof (run_reducer.rs, 2 test files)
- Test count: 719 tests pass, 0 failures

## Key Artifacts

### Research-to-Implementation Artifact Chain
All at `.relay/method-runs/checkpoint-bridge/artifacts/`:
- `execution-packet.md` — **THE CHARTER**: 9 invariants, 6 slices, 14 test obligations (T1-T14), 15 constraints (C-1 to C-15), 4 harness contracts, 10 verification commands
- `adr.md` — Decision: Option 4 (Enriched InteractiveIO Trait), `ureq` accepted, full scope including Swift UI
- `seam-proof.md` — Verdict: DESIGN HOLDS. Reducer handles caller-supplied checkpoint_id + idempotence
- `internal-digest.md` — 7 incongruencies (IC1-IC7) between method runner and run kernel
- `constraints.md` — 6 seams, hard invariants, open questions

### Implementation Files (already modified)
- `core/capacitor-core/src/reduce/run_reducer.rs` — checkpoint_id support + idempotence added
- `core/capacitor-core/tests/run_kernel_contract.rs` — T1, T2, T3 added + legacy tests updated
- `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs` — updated for checkpoint_id

### Files to Create/Modify (from execution packet Module Split)
- Create: `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs` — shared path helpers
- Create: `core/capacitor-core/src/method_runner/bridge_interactive_io.rs` — BridgeInteractiveIO adapter
- Modify: `core/capacitor-core/src/method_runner/adapters.rs` — add `emit_gate_checkpoint()` + `GateCheckpointContext`
- Modify: `core/capacitor-core/src/method_runner/executor.rs` — wire gate context + manifest generation
- Modify: `core/capacitor-core/src/method_runner/checkpoint_manifest.rs` — extend for gate artifacts
- Create: `core/hud-hook/src/checkpoint_bridge_relay.rs` — decision file relay
- Modify: `core/hud-hook/src/serve.rs` — call relay after SubmitDecision
- Create: `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift`
- Modify: `apps/swift/Sources/Capacitor/Models/AppState.swift` — run checkpoint routing

## Project Rules
- `cargo fmt` required before commits
- Do NOT modify `run_types.rs` MutateRunCommand fields (C-2)
- Do NOT modify `DelegationReviewWindow.swift` or `DelegationReviewManifest.swift` (C-13, C-14)
- No async/tokio in method runner (C-1)
- User has ADHD — keep findings focused and actionable
- User prefers long-term structurally sound solutions over quick fixes
- Use `./scripts/dev/restart-alpha-stable.sh` after Swift changes

## Established Decisions
- **Option 4 chosen:** Enriched InteractiveIO trait with `emit_gate_checkpoint(GateCheckpointContext)`
- **`ureq` accepted:** Sync HTTP client for runtime service communication (but execution packet says to reuse `RuntimeServiceEndpoint` from hud-hook instead — C-12)
- **Full scope:** Including Swift `RunCheckpointReviewWindow` — no deferred UI work
- **File-poll for decisions:** 500ms poll interval, `FileInteractiveIO`-style pattern
- **Vocabulary normalization:** "approve"→"approved", "request_changes"→"rejected" at the bridge boundary
- **Gate type mapping:** approval→AlignmentReview, manual_test_complete→ImplementationMilestone
- **`checkpoint_id == gate_id`** for bridge-managed checkpoints (C-6)
- **Decision relay in hud-hook:** ~40 lines, writes per-gate decision files after successful SubmitDecision

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -p capacitor-core -- -D warnings`, `cargo test -p capacitor-core` (719 tests)
- Passed: T1 (checkpoint_id preserved), T2 (idempotent re-emission), T3 (decision validation)
- Passed: All existing run_kernel_contract + run_kernel_checkpoint_scenario tests (updated for checkpoint_id)
- Not run: T4-T14 (slices 2-6 not implemented yet)
- Not run: Swift tests, hud-hook tests

## Open Questions / Risks
- **C-12 tension:** Execution packet says "Reuse `RuntimeServiceEndpoint`; no new HTTP client dependency in Cargo.toml" — but the ADR accepted adding `ureq`. The implementer should check if `RuntimeServiceEndpoint` already exists in hud-hook and can be extracted, or if `ureq` is needed
- **Run ID correlation (C-10):** Bridge mode needs `--bridge-run-id` CLI flag to receive the run kernel's run_id
- **Swift checkpoint UI:** The execution packet says to build `RunCheckpointReviewWindow` separate from `DelegationReviewWindow` — check that `RuntimeCheckpointState` carries enough data for the manifest loading pattern

## Notes for the Next Agent
- The execution packet is 585 lines and extremely detailed — read it thoroughly before starting
- Slices 2 and 4 are independent (can be parallelized)
- Slice 5 (Swift) depends on Slices 1 and 4
- The seam proof (Slice 1) already updated existing tests to pass `checkpoint_id` — this change propagated cleanly
- The `checkpoint_id` field on `MutateRunCommand` already existed but was previously ignored by the reducer — the seam proof activated it
