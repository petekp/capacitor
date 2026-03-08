# Capacitor Rewrite Charter

Operational procedure lives in `rewrite/PLAYBOOK.md`.

## Purpose
Capacitor is being rewritten to converge on one authoritative core and one clear UI shell. The rewrite optimizes for simplicity, coherence, and deletion of redundant paths.

## Invariants
1. Rust owns business rules, normalization, and state derivation.
2. Swift owns rendering, user intent capture, activation planning, and macOS-specific side effects.
3. No duplicate domain policy is allowed across Rust and Swift.
4. Each migration slice must delete replaced logic in the same PR.
5. Confidence comes from replay-diff + end-to-end smoke checks, not manual confidence.

## Non-Goals
1. Backward compatibility with legacy internal APIs.
2. Supporting non-macOS platforms.
3. Keeping daemon-era abstractions once replacement lands.

## Guardrails
1. Every touched file must be mapped in `rewrite/MAP.csv`.
2. Denylist patterns for active slices are hard CI failures.
3. Slices marked `done` cannot retain any declared deletion targets.
4. No temporary adapters without an owning slice and explicit removal target.

## Slice Completion Criteria
A slice is complete only when all are true:
1. Replay-diff checks for that slice pass.
2. E2E smoke checks for that slice pass.
3. Replacement call sites are migrated.
4. Legacy deletion targets are removed.
5. `rewrite/SLICES.yaml` and `rewrite/MAP.csv` are updated.

## Session Protocol
Session start:
1. Read `rewrite/CHARTER.md`.
2. Read `rewrite/DECISIONS.md`.
3. Read all `in_progress` slices in `rewrite/SLICES.yaml`.
4. Run `scripts/rewrite/check_rewrite_guards.sh --status`.

Session end:
1. Update slice status, touched paths, and risks.
2. Record exact next command/test sequence.
3. Do not mark a slice `done` unless deletion targets are gone.

## Handoff Format
1. What changed
2. What is now true
3. What remains
4. Exact next command/test sequence
