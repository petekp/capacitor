# Migration Charter: Holistic Reliability + Simplicity

## Mission

Migrate Capacitor from its current mixed-risk state to a production-grade baseline by eliminating audited correctness defects and reducing accidental architectural complexity across Rust core and Swift client, without removing in-development features.

## Invariants

1. All existing capabilities remain available (including ideas, project creation, workstreams, debug tooling) unless explicitly superseded in `DECISIONS.md`.
2. Every correctness fix starts with a failing regression test, then implementation, then passing proof.
3. All Rust tests pass for touched crates (`cargo test -p capacitor-core -p hud-hook`).
4. All Swift tests pass for touched modules (`swift test` in `apps/swift`).
5. No slice closes unless `.claude/migration/guard.sh` passes.
6. Snapshot ingest semantics remain deterministic and replay-safe.
7. Hook management preserves user-defined hooks and keeps `hud-hook cwd` behavior intact.
8. No replaced architecture survives as vestigial code after the slice that introduces its replacement.
9. `DECISIONS.md` remains append-only.

## Non-Goals

- Removing in-development feature surfaces to create artificial simplification.
- Rewriting the entire runtime/snapshot architecture from scratch.
- Introducing parallel ownership of the same responsibility across Rust and Swift.
- Shipping behavior changes without corresponding regression tests and control-plane updates.

## Guardrails

- One active slice at a time in `SLICES.yaml`.
- Every slice declares deletion targets before implementation.
- Ratchet budgets decrease monotonically.
- If a decision changes, add a new decision entry that supersedes prior entries.
- Every session ends with `HANDOFF.md` updates containing changed/true/remains/next steps.
