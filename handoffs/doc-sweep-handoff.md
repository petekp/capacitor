# Resume: Orchestrator Documentation Sweep — Priorities 1-3

## Mission
Perform a comprehensive documentation sweep for the Capacitor orchestrator feature (delegation loop, run kernel, method runner, checkpoint bridge, idea capture). Fix contradictions (P1), fill gaps (P2), and unify cross-cutting concerns (P3). All documentation changes should be optimized for agent legibility.

## Resume Point
- Last meaningful action: Two Codex doc-audit workers completed a full inventory (399 Rust/relay docs, 51 Swift/product docs). Audit results are at `.relay/doc-audit/handoffs/rust-docs-audit.md` and `.relay/doc-audit/handoffs/swift-docs-audit.md`.
- Next action: Execute the 4-phase documentation pipeline described below
- Success criterion: All stale docs retired/updated, gaps filled, unified review-surface spec written, adversarial review passes

## Instructions for the Next Agent

**Create a task list with these 4 phases**, then execute them sequentially using Codex workers:

### Phase 1: Adversarial Documentation Review (Codex worker)

Dispatch a Codex worker to perform a rigorous adversarial review of ALL existing documentation related to the orchestration feature. The worker should:

1. Read every document listed in both audit files:
   - `.relay/doc-audit/handoffs/rust-docs-audit.md` (399 docs inventoried)
   - `.relay/doc-audit/handoffs/swift-docs-audit.md` (51 docs inventoried)
2. For each document marked "current", verify its claims against actual source code
3. For each document marked "stale/outdated/superseded", determine: retire to `docs/archive/` or update in place
4. Specifically verify these known contradictions:
   - `docs/plans/orchestrator-status.md` claims request-changes is terminal (false — DelegationLoopManager supports multi-round iteration)
   - `docs/method-runner-spec/step-6-closeout.md` claims real adapters/gates/bridge are deferred (false — all shipped)
   - `handoffs/overnight-audit-report.md` claims real adapters not wired to binary (false — CLI has --real, --bridge-run-id, --bridge-project-path)
   - `docs/superpowers/specs/2026-03-20-orchestrator-card-design.md` claims action bar always visible (code uses hover-reveal)
   - `.relay/.../ship-review.md` claims emit_gate_checkpoint is fail-open (partially fixed — bridge side fail-closed, relay side still best-effort)
5. Output: A findings report with specific file:line references, categorized as: retire, update, leave as-is

### Phase 2: Document Outline (Codex worker)

Using the adversarial review findings, produce an outline for a new canonical documentation set. The outline should cover:

**Documents to create:**
- `docs/orchestrator/checkpoint-bridge.md` — The gate→checkpoint→decision→unblock pipeline
- `docs/orchestrator/review-surfaces.md` — Shared spec for delegation review + run checkpoint review (manifest contract, left-pane/right-rail structure, action semantics, close/dismiss behavior)
- `docs/orchestrator/appstate-checkpoint-policy.md` — How AppState routes checkpoints (oldest-first, advance-on-clear, non-interference between delegation and run checkpoints)
- `docs/orchestrator/terminology.md` — Normalized glossary: delegation review, run checkpoint, milestone, gate, phase, method template, etc.
- `docs/orchestrator/idea-to-run-gap.md` — Documents the current state and what's needed to connect idea capture → method selection → run creation

**Documents to update:**
- `docs/ARCHITECTURE.md` — Add orchestrator/checkpoint section
- `.claude/docs/architecture-primer.md` — Add orchestrator read path
- `AGENT_CHANGELOG.md` — Record checkpoint bridge shipping and doc sweep

**Documents to retire to `docs/archive/`:**
- Based on Phase 1 findings

**Module doc comments to add:**
- `core/capacitor-core/src/method_runner/checkpoint_bridge.rs`
- `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs`
- `core/hud-hook/src/checkpoint_bridge_relay.rs`

The outline should specify: for each document, its audience (agent vs human), its sections, what source files it should reference, and what test contracts prove its claims.

### Phase 3: Fill the Outline (Codex worker)

Take the outline from Phase 2 and produce the full document content. Requirements:
- Every claim must be verifiable against current source code (include file:line references)
- Use the current HEAD (`3db10d1`) as the baseline — verify all references against actual code
- Optimize for agent legibility: structured headers, concrete paths, no vague language
- Include the module doc comments as code changes
- For retirement: move files, don't delete (preserve history)
- For the terminology doc: reconcile all the different terms used across the codebase into canonical definitions

### Phase 4: Adversarial Review of New Docs (Codex worker)

Dispatch a final Codex worker to adversarially review everything produced in Phase 3:
- Verify every file:line reference is accurate
- Check that retired docs are actually moved
- Confirm module doc comments compile (`cargo build`, `cargo clippy`)
- Verify no contradictions between new docs and existing current docs
- Check that the terminology doc matches actual type/function names in code
- Output: findings report. If issues found, address them before committing.

## Current State
- Checkpoint bridge fully implemented and reviewed (7 commits, 69dee75..3db10d1)
- Two doc audits completed with full inventories
- 5 known contradictions identified
- 5 missing docs identified
- 3 unification opportunities identified
- No code changes needed — this is a documentation-only sweep

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `3db10d1` (fix: path sanitization, poll timeout, action validation)
- Working tree: clean (3 untracked handoff files in `handoffs/`)
- 7 unpushed commits (checkpoint bridge work)

## Key Artifacts
- `.relay/doc-audit/handoffs/rust-docs-audit.md` — Full Rust/relay doc inventory (399 docs, 58 current, 286 stale)
- `.relay/doc-audit/handoffs/swift-docs-audit.md` — Full Swift/product doc inventory (51 docs, 40 current, 11 stale)
- `.relay/method-runs/checkpoint-bridge/artifacts/execution-packet.md` — Checkpoint bridge execution packet (the implementation contract)
- `.relay/method-runs/checkpoint-bridge/artifacts/implementation-handoff.md` — What was built across all 6 slices
- `.relay/method-runs/checkpoint-bridge/phases/step-10-rerun/code-review.md` — Independent Codex code review findings

## Project Rules
- User has ADHD — keep findings focused and actionable
- User prefers long-term structurally sound solutions
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-stable.sh` after Swift changes
- Skip hooks (`--no-verify`) for `apps/www/` commits only
- `.relay/` is gitignored — doc audit results are working state, not tracked

## Established Decisions
- Delegation review and run checkpoint review are deliberately separate windows (C-14)
- They share `DelegationReviewManifest` as the decoder contract
- `AppState` routes them independently (`reviewWindowTarget` vs `runCheckpointWindowTarget`)
- The checkpoint bridge uses file-based decision relay, not snapshot polling
- Method runner is a standalone CLI binary — no Swift invocation yet (documented gap)
- `checkpoint_id == gate_id` for bridge-managed checkpoints

## What the Checkpoint Bridge Ships (for doc accuracy)
- Slice 1: Reducer supports caller-supplied checkpoint_id, idempotent re-emission, decision validation
- Slices 2-4: BridgeInteractiveIO adapter, checkpoint_bridge_protocol.rs, executor gate integration, hud-hook decision relay
- Slice 5: RunCheckpointReviewWindow.swift, AppState auto-open (oldest-first), submitRunCheckpointDecision
- Slice 6: Crash recovery + concurrent-run isolation tests
- Ship review fixes: fail-closed bridge, path sanitization, poll timeout, decision action validation

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -p capacitor-core -- -D warnings`, `cargo clippy -p hud-hook -- -D warnings`
- Passed: `cargo test -p capacitor-core` (729 tests), `cargo test -p hud-hook` (36 tests)
- Passed: `swift build --package-path apps/swift`, `swift test --filter AppStateRunCheckpointTests` (4 tests)
- Passed: `swift test --package-path apps/swift` (410 XCTest + 19 Testing Library = 429 tests)
- Not run: `./scripts/verify/verify.sh --layers 1,2` (timed out in review sessions)

## Open Questions / Risks
- The `docs/superpowers/specs/2026-03-20-orchestrator-card-design.md` spec diverges from code (hover-reveal vs always-visible action bar). The doc sweep should either update the spec or flag it as aspirational.
- The `.relay/` working artifacts contain valuable lineage but are gitignored. The doc sweep should promote the important bits to `docs/` without bloating the tracked tree.
- Some "current" method-runner-spec docs are "future-facing" (they describe the intended end state, not current shipping code). The sweep should clearly label these.
