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

## D-006: Claude Hook Capability Matrix Is A Checked-In Contract
- Date: 2026-03-09
- Status: accepted
- Decision: Claude hook capabilities are represented as a checked-in contract artifact that drives installer generation, health validation, and contract tests.
- Why: Prevents drift between external docs, install behavior, and health reporting.
- Affected slices: RW-102, RW-103

## D-007: Observation Journal Is The Target Runtime Input Model
- Date: 2026-03-09
- Status: accepted
- Decision: The target runtime model is append-only observations plus derived read models; exported snapshots may remain as derived artifacts during migration but are not the long-term canonical store.
- Why: Improves replayability, explainability, and migration safety.
- Affected slices: RW-102, RW-104, RW-106

## D-008: Mixed Transport Is Allowed, But Only One Semantic Path
- Date: 2026-03-09
- Status: accepted
- Decision: Mixed Claude transports are allowed when required by the capability matrix, but every transport must normalize into the same observation model and projector path.
- Why: Preserves event coverage without reintroducing parallel policy logic.
- Affected slices: RW-102, RW-103, RW-104, RW-105

## D-009: Adapters Are Forwarders, Not Reducers
- Date: 2026-03-09
- Status: accepted
- Decision: Hook adapters, shell submitters, and runtime hosts may validate and normalize external input, but they may not own lifecycle or attribution semantics.
- Why: Prevents policy drift and keeps domain truth in one place.
- Affected slices: RW-102, RW-104, RW-105

## D-010: Process Boundary Remains Open Until Prototype Gate
- Date: 2026-03-09
- Status: accepted
- Decision: The domain and application layers must remain host-agnostic until a prototype slice explicitly decides between an in-process runtime host and a dedicated runtime service.
- Why: Keeps the architecture blank-slate enough to evaluate the process model honestly without forcing an early reversal of D-001.
- Affected slices: RW-102, RW-105

## D-011: Hook Decision Control Is Out Of Scope For Tracking
- Date: 2026-03-09
- Status: accepted
- Decision: Capacitor's tracking subsystem does not depend on Claude hook decision-control features; if future product work needs them, that must be modeled as a separate bounded capability.
- Why: Keeps command and HTTP adapters observational and thin.
- Affected slices: RW-102, RW-105

## D-012: Durable Audit Artifacts Are Tracked Docs, Not `.claude` Scratch
- Date: 2026-03-09
- Status: accepted
- Decision: `.claude/*` remains local-only scratch space for explorations, temporary migration notes, and session artifacts. Durable audit outputs and migration design packages belong in tracked repo docs under `docs/audits/` and `docs/plans/`.
- Why: Preserves repo hygiene without making future audit-and-migrate sessions throw away useful architectural evidence.
- Affected slices: RW-102, RW-108

## D-013: Dedicated Local Runtime Service Is The Chosen Foundation
- Date: 2026-03-09
- Status: accepted
- Decision: The target architecture uses a dedicated local runtime service as the application boundary for tracking. The Swift app is a client of that runtime. This supersedes D-010's open process-boundary posture and supersedes D-001 for the hook/runtime subsystem.
- Why: We want to finish the expensive ownership-boundary work before feature growth makes the migration harder. Runtime continuity and boundary clarity are being treated as foundation, not premature optimization.
- Affected slices: RW-109, RW-110, RW-111, RW-112

## Change Control
1. New decisions must be appended with a unique ID.
2. Reversals require a superseding decision entry, not silent edits.
3. Any decision change must reference affected slices in `rewrite/SLICES.yaml`.
