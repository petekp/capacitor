# Capacitor Rewrite Playbook

This playbook describes the exact slice-based process used for the large Capacitor rewrite. Use it for any future architecture migration where we want maximum confidence and zero vestigial drift.

## 1) Goals

1. One canonical implementation per capability.
2. No parallel policy paths across boundaries.
3. Every slice lands with deletion of replaced code in the same change.
4. Confidence is evidence-driven, not intuition-driven.

## 2) Operating Artifacts (Required)

1. `rewrite/CHARTER.md`  
   Mission, invariants, non-goals, guardrails.
2. `rewrite/DECISIONS.md`  
   Locked architecture decisions and reversals.
3. `rewrite/SLICES.yaml`  
   Machine-checkable rewrite ledger.
4. `rewrite/MAP.csv`  
   Source-of-truth path mapping (`current_path` -> `target_path`) and deletion intent.
5. `scripts/rewrite/check_rewrite_guards.sh`  
   Enforces mapping, denylist, and deletion targets.

If any artifact is missing, create it before implementation work.

## 3) Rewrite Bootstrap (PR-000 Equivalent)

1. Lock decisions first in `DECISIONS.md`.
2. Define global acceptance in `SLICES.yaml`:
   - replay-diff required
   - e2e smoke required
   - legacy deletion in same slice required
3. Seed `MAP.csv` with expected touched paths for all planned slices.
4. Add denylist patterns for legacy surfaces to prevent reintroduction.
5. Wire `check_rewrite_guards.sh` into CI before feature work begins.

## 4) Slice Design Rules

Each slice must be:

1. Vertical and outcome-based (a capability, not a file rename sweep).
2. Decision-complete (ownership of logic is explicit).
3. Independently verifiable with deterministic checks.
4. Bounded in blast radius (small enough to review and revert cleanly).

Each `SLICES.yaml` entry must include at minimum:

1. `id`, `name`, `status`, `depends_on`
2. `touched_paths`
3. `contracts` (`added`, `changed`, `removed`)
4. `replay_scenarios`, `smoke_scenarios`
5. `denylist_patterns`
6. `deletion_targets`
7. `risks`, `notes`

## 5) Slice Lifecycle

### A. Start

1. Mark slice `in_progress`.
2. Ensure all intended files are in `MAP.csv`.
3. Run:
   - `./scripts/rewrite/check_rewrite_guards.sh --status`

### B. Build (TDD-first for behavior changes)

1. Add/adjust tests that fail without the new behavior.
2. Implement canonical path.
3. Migrate call sites.
4. Delete replaced path in the same slice.

### C. Verify

Run the slice’s acceptance suite:

1. Rewrite guards:
   - `./scripts/rewrite/check_rewrite_guards.sh`
2. Rust/Swift/unit/integration checks relevant to touched surfaces.
3. Replay-diff scenarios for determinism and behavior parity.
4. E2E smoke scenarios for user-visible workflow parity.

### D. Close

A slice can be marked `done` only when:

1. All required checks pass.
2. All deletion targets are physically gone.
3. `MAP.csv` and `SLICES.yaml` are updated accurately.
4. Denylists cover the removed legacy surfaces.

## 6) Enforcement Model

The guard script is the hard gate. It must block merges when:

1. A touched file is not mapped in `MAP.csv`.
2. A denylist pattern matches existing code.
3. A slice marked `done` still has deletion targets present.

CI should run guard checks early so failures are fast and obvious.

## 7) Confidence Model (Acceptance Oracle)

Use layered evidence:

1. Replay-diff (deterministic core semantics)
2. Automated smoke (critical workflows)
3. Full test suites (Rust + Swift + script/test harnesses)
4. Targeted manual smoke for high-risk UX only

Priority order:
1. deterministic replay
2. automated smoke
3. full tests
4. manual checks

If evidence conflicts, deterministic replay + contract tests win over anecdotal manual observations.

## 8) Anti-Vestigial Discipline

For every slice:

1. Define `deletion_targets` before implementation.
2. Add denylist patterns for names/paths being removed.
3. Delete docs that describe removed architecture or move to explicit archive scope.
4. Remove obsolete scripts/config toggles/env fallbacks.
5. Regenerate generated artifacts after API/contract changes.

No “temporary” adapter without:

1. owning slice ID
2. explicit expiry condition
3. explicit deletion target

## 9) Session Protocol (Multi-Session + Compaction Safe)

### Session Start Ritual

1. Read `rewrite/CHARTER.md`
2. Read `rewrite/DECISIONS.md`
3. Read all `in_progress` slices in `rewrite/SLICES.yaml`
4. Run `./scripts/rewrite/check_rewrite_guards.sh --status`

### Session End Ritual

1. Update slice status and touched paths.
2. Record risks and what changed.
3. Record exact next command/test sequence.
4. Do not mark `done` if deletion targets remain.

## 10) Handoff Contract

Every handoff must include exactly:

1. What changed
2. What is now true
3. What remains
4. Exact next command/test sequence

This format is mandatory for continuity across context compaction.

## 11) Decision Governance

1. Append-only decisions in `DECISIONS.md` (no silent rewrites).
2. Reversals must be recorded as superseding decisions.
3. Decision updates must reference affected slice IDs.

## 12) PR Review Checklist

1. Scope matches slice contract.
2. No unmapped touched files.
3. Legacy path deleted in same slice.
4. Denylist updated for removed surfaces.
5. Replay + smoke evidence attached.
6. `SLICES.yaml` + `MAP.csv` updated.
7. Docs reflect current architecture only.

## 13) Closeout (End of Rewrite Program)

1. Run full guard, full tests, replay corpus, smoke suite.
2. Run vestigial grep sweeps for removed surfaces.
3. Remove transitional flags/scaffolding.
4. Publish final architecture doc and concise operator runbook.
5. Freeze denylist patterns that prevent regression.

## 14) Practical Command Set

```bash
# Status + guardrails
./scripts/rewrite/check_rewrite_guards.sh --status
./scripts/rewrite/check_rewrite_guards.sh

# Core verification (example baseline)
cargo test
cd apps/swift && swift test && cd -

# Targeted scans
rg -n "legacy_term_1|legacy_term_2" .
git diff --name-only
```

Use this playbook as process law for major refactors. If you need to bend a rule, record the exception as a decision with explicit scope and expiry.

## 15) Scenario Coverage Checklist (Table-Driven Tests)

Before merging table-driven test edits, run this checklist:

1. Enumerate branches in the production function being tested (`switch` arms, guards, early returns).
2. Keep exactly one scenario row per branch unless a row validates a distinct invariant for the same branch.
3. Include the "healthy/default/no-op" branch explicitly when it exists.
4. Remove branch-equivalent duplicate rows (same branch, same assertion outcome, no additional invariant).
5. Use branch-meaningful labels (`config-missing-shown`, `not-firing-hidden`) instead of data-shape labels.
6. If two rows intentionally target the same branch, document the extra invariant inline in the row label.
7. After pruning, rerun full suite and verify no method-level coverage loss in the audit metrics.
