# Terminal Activation v2 Migration Charter

Operational spec: `.claude/docs/terminal-activation-ux-spec.md`
Implementation plan: `.claude/plans/2026-03-01-terminal-activation-v2-implementation.md`

## Purpose

Replace the multi-action-kind dispatch model (Rust resolver picks action kind, Swift executor dispatches to separate handlers) with a unified Swift-side flow: resolve managed TTY → ensure session + switch → focus terminal. The Rust resolver is retained for telemetry only.

## Invariants

1. All existing tests pass after each slice (253+ tests).
2. No user-facing behavior changes except those explicitly specified in the v2 UX spec.
3. Card clicks must satisfy all 8 behavioral invariants (B1–B8) in the spec.
4. Each slice must delete replaced logic in the same commit.
5. Rust FFI boundary is read-only for this migration (no Rust source changes).

## Non-Goals

1. Modifying Rust resolver logic or types.
2. Adding iTerm/Terminal.app AX tab routing (tracked separately per spec).
3. Changing the staleness guard mechanism (already works correctly).
4. Backward compatibility with removed internal Swift APIs.

## Guardrails

1. Every touched file must be mapped in MAP.csv.
2. Denylist patterns for completed slices are enforced by the guard script.
3. Slices marked `done` cannot retain any declared deletion targets.
4. No temporary adapters without an owning slice and explicit removal target.

## Anti-Pattern Budgets (baseline)

| Pattern | Grep | Count | Target |
|---------|------|-------|--------|
| Transient TTY resolution | `resolveAttachedTmuxClientTty` in Sources | 3 | 0 |
| Action-specific methods | `performSwitch\|performEnsure\|switchTmuxSessionAction\|ensureTmuxSessionAction\|launchTerminalWithAERSnapshot` in Sources | 11 | 0 |
| Executor references | `ActivationActionExecutor` in Sources | 3 | 0 |
| Action-specific test methods | same pattern in Tests | 9 | 0 |

## Session Protocol

Session start:
1. Read this charter.
2. Read DECISIONS.md.
3. Read all `in_progress` slices in SLICES.yaml.
4. Run `scripts/ci/terminal-activation-v2-guard.sh --status`.

Session end:
1. Update slice status, touched paths, and risks.
2. Record exact next command/test sequence.
3. Do not mark a slice `done` unless deletion targets are gone.
