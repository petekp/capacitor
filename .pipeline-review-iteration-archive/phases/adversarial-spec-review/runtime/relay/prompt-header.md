# Adversarial Review: Review Iteration Design Spec

## Your Role

You are an adversarial reviewer. Your job is to find problems, not validate the design.
Assume the spec authors are overconfident. Look for what they missed, what they
hand-waved, and where the design will break under real-world conditions.

## The Spec

Read `docs/superpowers/specs/2026-03-19-review-iteration-design.md` in full.

## Implementation Context

Read these files to understand what the spec is building on:

- `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` — the main file that will change
- `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift` — the view being replaced
- `core/capacitor-core/src/domain/types.rs` — Rust types the spec claims don't need changes
- `core/capacitor-core/src/reduce/mod.rs` — Rust reducer the spec claims doesn't need changes
- `apps/swift/Sources/Capacitor/Models/AppState.swift` — app composition root
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` — mutation transport
- `core/capacitor-core/tests/delegation_contract.rs` — existing delegation test contracts
- `apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift` — existing Swift tests
- `CLAUDE.md` — project rules and invariants
- `.claude/docs/architecture-primer.md` — architecture invariants

## Attack Vectors

Try to break the design on these fronts:

1. **Filesystem races** — The reconciliation loop polls the filesystem. The worker writes
   files. What TOCTOU bugs exist? Can the reconciler see a half-written manifest.json
   and trigger review_ready with corrupt data? What about atomic writes?

2. **State machine gaps** — Trace every possible state transition. Is there a path where
   the delegation gets stuck? Where the user can't get back to a reviewable state?
   What if the worker ignores the prompt and writes to the wrong milestone directory?

3. **The "worker ignores instructions" problem** — The worker is an LLM. It might:
   - Write to milestones/01/ instead of milestones/02/ (overwriting decided milestone)
   - Write a completion marker instead of a new milestone
   - Write both a milestone AND a completion marker
   - Create milestones/03/ when only milestones/02/ was expected
   - Never exit, leaving the delegation in limbo

4. **Window lifecycle** — The spec says the review window opens when the project card is
   tapped. What if:
   - The user opens two review windows for different projects?
   - The delegation state changes while the window is open (worker completes while user is reviewing)?
   - The user closes the window without deciding?
   - The app crashes with the window open — is the delegation stuck?

5. **Data model brittleness** — The 2-digit zero-padded milestone IDs. What if:
   - A non-numeric directory exists in milestones/ (e.g., "temp", ".DS_Store")?
   - The filesystem returns directories in an unexpected order?
   - milestone "01" is deleted but "02" exists?

6. **Reducer assumptions** — The spec claims no reducer changes are needed. Verify this
   by tracing the Resume → new ReviewReady cycle through the actual reducer code.
   Is there any validation that would reject a ReviewReady with milestone_id "02" after
   a Resume cleared current_review?

7. **Testing gaps** — The spec's testing strategy. What's NOT tested? What integration
   scenarios are missing? What would a QA engineer ask for that the spec doesn't cover?

## Output

Write your findings to:
- `.pipeline/phases/adversarial-spec-review/runtime/relay/review-findings/review-findings-adversarial.md`
- `.pipeline/phases/adversarial-spec-review/runtime/relay/handoffs/handoff-adversarial.md`

Be ruthless. If the design is actually solid, say so — but earn that conclusion.
