# Rewrite Decisions Log

This file records architecture decisions that are locked for the rewrite.

## D-001: No Daemon Core
- Date: 2026-02-28
- Status: accepted
- Decision: Remove daemon IPC as the primary runtime path; use a single UniFFI-exposed Rust runtime.
- Why: Eliminates duplicate state ownership, transport complexity, and schema drift.

## D-002: Strangler with Hard Gates
- Date: 2026-02-28
- Status: accepted
- Decision: Migrate capability-by-capability with strict per-slice deletion and CI enforcement.
- Why: Prevents partial migration drift and vestigial remnants.

## D-003: Replay-Diff + E2E Smoke as Acceptance Oracle
- Date: 2026-02-28
- Status: accepted
- Decision: Functional parity is proven by replay-diff corpus plus scenario smoke checks.
- Why: Provides deterministic confidence across sessions and context compaction.

## D-004: Rust Owns Domain Semantics
- Date: 2026-02-28
- Status: accepted
- Decision: Rust is canonical for path/workspace identity, session/project state derivation, and activation planning.
- Why: Prevents cross-language policy duplication.

## D-005: No Legacy Compatibility Constraint
- Date: 2026-02-28
- Status: accepted
- Decision: Breaking internal API changes are allowed when they reduce complexity and improve architecture.
- Why: Single-user product with explicit rewrite intent.

## Change Control
1. New decisions must be appended with a unique ID.
2. Reversals require a superseding decision entry, not silent edits.
3. Any decision change must reference affected slices in `rewrite/SLICES.yaml`.
