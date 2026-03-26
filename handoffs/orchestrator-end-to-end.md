# Resume: Orchestrator End-to-End — Idea to Method to Run to Review

## Mission
Close the orchestrator loop in Capacitor so a user can add an idea, assign a method template, have it execute in the background via the method runner binary, and receive review packages at key milestones via the checkpoint bridge. Then exhaustively test the end-to-end flow and iterate on agent behavior quality.

## Instructions for the Next Agent

Execute this work as a multi-phase campaign. Each phase uses the research-to-implementation method skill pattern (research current state, design, implement, verify). Create task lists for each phase.

### Phase A: Research and Overview

Use the `/research-to-implementation` method skill to research the current state of the orchestrator system end-to-end and produce an implementation overview.

**Scope:** Read every file in the "Key Artifacts" section below. Map the complete flow from idea capture through method selection, run creation, subprocess launch, phase execution, checkpoint bridge, review UI, decision relay, and gate unblock. Identify every gap, every missing seam, and every integration point. Produce a concrete implementation plan with ordered steps.

**Expected output:** A numbered list of implementation steps, each with:
- What it does
- What files it touches (Rust and Swift)
- What it depends on
- How to verify it works

### Phase B: Implement Each Step

For each step from the Phase A plan, use the `/research-to-implementation` method skill individually. The steps (from prior session analysis) are approximately:

1. **Expose method templates to Swift** -- Add `list_builtin_methods()` to `CoreRuntime` FFI surface (`core/capacitor-core/src/lib.rs`). Around 10 lines Rust. UniFFI regen required.
2. **Method selector UI** -- New `MethodSelectorView.swift` showing 4 built-in methods. Add `onRunMethod` callback to `IdeaDetailModal.swift`. Wire in `ProjectDetailView.swift`. Around 170 lines Swift.
3. **Run creation mutation from Swift** -- New `AppState.runMethodOnIdea()` that calls `runtimeClient.mutateRun()` with `kind: "create"`. Around 30 lines. No Rust changes -- the `run_reducer.rs:59-108` Create handler already works.
4. **Method runner subprocess coordinator** -- New `MethodRunCoordinator.swift` that spawns `method-runner run --root <path> --definition <yaml> --real --bridge-run-id <id> --bridge-project-path <path>`. Lifecycle monitoring, crash detection, resume support. Around 250 lines. This is the hardest step -- pattern after `DelegationLoopManager.swift:326-410`.
5. **Checkpoint bridge wiring verification** -- The bridge already works end-to-end. Verify: `BridgeInteractiveIO` posts `EmitCheckpoint` mutation, `AppState.reconcileRunCheckpointWindowTarget()` auto-detects paused run, `RunCheckpointReviewWindow` renders, decision relay writes file, bridge polls and unblocks gate. May need around 20 lines to ensure run transitions to `Paused` on checkpoint emit.
6. **Run status in project card** -- Show active method runs on `ProjectCardView.swift`. Add run-state badges to `IdeaQueueStatusResolver.swift`. Around 50 lines.

**For each step:** Research the exact current code, design the change, implement, write tests, verify with `cargo test` / `swift test` / `cargo clippy` / `cargo fmt`.

### Phase C: End-to-End Testing and Agent Behavior Assessment

After all steps are implemented:

1. **End-to-end manual flow test** -- Create an idea, select a method, watch it run, review checkpoints, approve/reject, verify completion. Use `scripts/ci/ax-automation-verify.sh` for automated verification where possible.
2. **Create test scenarios** -- Write tests that exercise:
   - Happy path: idea, method, all phases complete, done
   - Checkpoint review: idea, method, gate, review, approve, continue
   - Request changes: idea, method, gate, review, request changes, revised checkpoint
   - Crash recovery: method runner crashes mid-phase, app restart, resume
   - Concurrent runs: two ideas running different methods simultaneously
   - Edge cases: invalid method ID, runtime service unreachable, subprocess timeout
3. **Agent behavior report** -- Produce a detailed report identifying:
   - What works well
   - Where agent behavior is suboptimal (slow, wrong decisions, poor prompts)
   - Specific improvement opportunities with file:line references
   - Prioritized recommendations

### Phase D: Iterate on Report Findings

Break the Phase C report into individual tasks. For each finding:
1. Use `/research-to-implementation` to research and implement the fix
2. Re-run the relevant tests to verify improvement

After all findings are addressed, run the full end-to-end test suite again to confirm no regressions and produce a final quality assessment.

## Current State

### What Is Done (this session)
- Documentation sweep complete: 5 new canonical docs under `docs/orchestrator/`, 3 doc updates, 16 retirements, 3 module doc comments
- All 5 known contradictions verified and documented
- Implementation plan for the idea-to-method-to-run loop analyzed and validated against source code
- Checkpoint bridge fully implemented and reviewed (7 commits on main)
- `cargo build`, `cargo clippy -D warnings`, `cargo fmt --check` all pass
- `cargo test -p capacitor-core` (729 tests), `cargo test -p hud-hook` (36 tests) pass
- `swift build --package-path apps/swift` and `swift test` (429 tests) pass

### What Is NOT Done
- No code changes for the idea-to-method-to-run loop yet -- only documentation and analysis
- The uncommitted doc sweep changes need to be committed before starting implementation
- The `docs/superpowers/specs/2026-03-20-orchestrator-card-design.md` still diverges from code (hover-reveal vs always-visible action bar) -- design intent, not a blocker

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `3db10d1` (fix: path sanitization, poll timeout, action validation)
- Working tree: dirty -- 22 files changed (doc sweep: 5 new docs, 3 updated docs, 16 retirements, 3 module doc comments). Plus 5 untracked handoff files in `handoffs/`.
- 7 unpushed commits (checkpoint bridge work)

## Key Artifacts

### Architecture and Orientation
- `.claude/docs/architecture-primer.md` -- Start here. Orchestrator read path now included.
- `docs/ARCHITECTURE.md` -- Canonical spec with new orchestrator section
- `docs/orchestrator/checkpoint-bridge.md` -- Gate to checkpoint to decision to unblock pipeline (just written)
- `docs/orchestrator/review-surfaces.md` -- Shared review window contract
- `docs/orchestrator/appstate-checkpoint-policy.md` -- AppState routing policy
- `docs/orchestrator/terminology.md` -- Normalized glossary (disambiguates Run/Checkpoint/Review/Gate)
- `docs/orchestrator/idea-to-run-gap.md` -- Exact gap analysis with what exists vs what is needed

### Swift (idea capture to delegation to review)
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift:68` -- "Delegate" button; add "Run Method" here
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift:69` -- `onDelegate` callback pattern to replicate
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift:112-116` -- Where callbacks are wired
- `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:326-410` -- Subprocess launch pattern to replicate
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1659` -- `delegateIdea()` method to replicate as `runMethodOnIdea()`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1776-1814` -- Checkpoint reconciliation (already works)
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:1261-1285` -- `mutateRun()` already exists
- `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift` -- Already implemented
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift:633` -- Hover-reveal opacity for actions

### Rust (method runner and checkpoint bridge)
- `core/capacitor-core/src/bin/method_runner.rs` -- CLI binary: `run`, `normalize`, `resume` commands
- `core/capacitor-core/src/bin/method_runner.rs:449-477` -- `make_interactive_io()` bridge selection logic
- `core/capacitor-core/src/domain/method_registry.rs` -- 4 built-in templates: execution_only, shape_and_execute, deep_debug, greenfield_build
- `core/capacitor-core/src/domain/run_types.rs:108-115` -- `MethodTemplate` (already `uniffi::Record`)
- `core/capacitor-core/src/reduce/run_reducer.rs:59-108` -- Create handler (already works)
- `core/capacitor-core/src/method_runner/checkpoint_bridge.rs:30` -- `BridgeInteractiveIO`
- `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs` -- JSON file protocol
- `core/hud-hook/src/checkpoint_bridge_relay.rs:20` -- Decision relay (fail-open, known limitation)
- `core/capacitor-core/src/lib.rs` -- CoreRuntime FFI surface; add `list_builtin_methods()` here

### Method Templates and Fixtures
- `methods/fixtures/*.yaml` -- 16+ real YAML fixtures (spec-hardening, idea-to-ship, minimal-dispatch, etc.)
- `core/capacitor-core/src/method_runner/definition.rs` -- YAML definition loading

### Specs (kept, future-facing)
- `docs/method-runner-spec/amended-spec.md` -- Authoritative method runner spec
- `docs/method-runner-spec/execution-packet.md` -- Build contract with invariants
- `docs/method-runner-spec/BUILD_BOUNDARY.md` -- Subsystem boundary decisions
- `docs/method-runner-spec/hardened-sequence.md` -- Forward-facing guidance for next phases

## Project Rules
- User has ADHD -- keep findings focused and actionable
- User prefers long-term structurally sound solutions over quick hacks
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-stable.sh` after Swift changes (default profile)
- Skip hooks (`--no-verify`) for `apps/www/` commits only
- `.relay/` is gitignored -- working state, not tracked
- Never call Anthropic API directly -- invoke `claude` CLI instead
- Write to `~/.capacitor/`, read from `~/.claude/`

## Established Decisions
- Delegation review and run checkpoint review are deliberately separate windows (C-14)
- Both share `DelegationReviewManifest` as the decoder contract
- `AppState` routes them independently (`reviewWindowTarget` vs `runCheckpointWindowTarget`)
- Checkpoint bridge uses file-based decision relay, not snapshot polling
- Method runner is a standalone CLI binary -- Step 4 adds Swift invocation
- `checkpoint_id == gate_id` for bridge-managed checkpoints
- Relay side is fail-open (known limitation, documented)
- The 4 built-in method templates are sufficient for the initial implementation; custom YAML methods are future work

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -p capacitor-core -- -D warnings`, `cargo clippy -p hud-hook -- -D warnings`
- Passed: `cargo test -p capacitor-core` (729 tests), `cargo test -p hud-hook` (36 tests)
- Passed: `swift build --package-path apps/swift`, `swift test --package-path apps/swift` (429 tests)
- Not run: `./scripts/verify/verify.sh --layers 1,2` (timed out in previous sessions)
- Not run: `./scripts/dev/restart-alpha-stable.sh` after doc-only changes (not needed, no Swift code changed)

## Open Questions / Risks
- **Subprocess management complexity** -- Step 4 (MethodRunCoordinator) is the hardest piece. Pattern after DelegationLoopManager but the method runner is a different beast (deterministic phases vs open-ended Claude session). May need `AdvancePhase` mutations to track phase transitions.
- **Resume semantics** -- If the method runner crashes, does `method-runner resume --root <path>` pick up correctly? The `resume.rs` module exists but is scaffolded (per step-6-closeout, now archived). Needs verification.
- **YAML definition path** -- The method runner binary needs `--definition <path>`. For built-in templates, we would either: (a) write the template to a temp YAML file, or (b) add a `--method-id` flag that looks up from the registry. Option (b) is cleaner.
- **UniFFI regen** -- Step 1 adds a new FFI export. Need to verify the UniFFI binding generation pipeline works smoothly with `./scripts/dev/restart-app.sh --force`.
