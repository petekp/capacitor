# Charter

## Mission
Rebuild Capacitor terminal activation into one pane-aware, route-first system that Rust derives and Swift executes across Ghostty, iTerm, and Terminal.app.

## Invariants
- Rust is the single owner of routing semantics and route derivation.
- Swift is the single owner of tmux execution and macOS terminal automation.
- No parallel activation policy paths may remain after the migration.
- Ghostty native routing stays in place.
- Ghostty native launch stays deferred until upstream surface creation is reliable.
- Ghostty AX routing must not reappear.
- Internal route-contract breaking changes are allowed if all in-repo consumers move in the same slice.

## Non-Goals
- Reintroducing the Ghostty AX reader or any compatibility shim for it.
- Preserving the old `target_kind` / `target_value` route shape.
- Supporting terminals beyond Ghostty, iTerm, and Terminal.app in this migration.
- Replacing Ghostty’s launch path with native surface creation before that API proves reliable in live smoke tests.

## Guardrails
- Every migration slice must define deletion targets before implementation.
- Every slice must end with deterministic verification, not intuition.
- New architecture must shrink or isolate old seams; it must not add parallel helpers that keep the old path alive.
- Control-plane artifacts live under `docs/plans/terminal-routing-foundation/` and `docs/audits/terminal-routing-foundation/`, not `.claude/migration/`.
