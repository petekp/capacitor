# Batch 4: Clarity Rewrites (paragraph-local)

## Scope Narrowing During Execute

Scope reduced from 12 to 6 items after re-reading context:

| Queue Item | Action | Reason |
|---|---|---|
| B4.2 ADR-005 L27 "reducer snapshot" pronoun | **DEFERRED** | Inside frozen Current-State Snapshot section per brief.md boundary rule |
| B4.5 ADR-005 L87-90 Phase 2 passive voice | **DEFERRED** | Migration Guidance is now historical plan text; shipped architecture documented in ARCHITECTURE.md rewrite with module paths |
| B4.6 ADR-005 L92 "original sketch" pronoun | **DEFERRED** | Historical plan context; local to step 8 which is also historical |
| B4.7 ARCHITECTURE.md dense ownership paragraph | **DEFERRED** | Low-confidence per original finding; existing structure is functional |
| B4.11 gotchas.md L113-120 ownership "why" | **DEFERRED** | Medium-confidence polish; rule is clear without added rationale |
| B4.12 README.md L70-79 flow paragraph split | **DEFERRED** | Low-confidence; current form is technically correct |

## Items Applied

| # | File | Action | Result |
|---|---|---|---|
| B4.1 | `docs/architecture-decisions/005-*.md:8` (ADR Summary) | Added inline gloss: "each signal source is designated as the authoritative answer to a specific question, and conflicts resolve by authority rank rather than recency or majority vote." + purpose-of-provenance sentence | COMPLETE |
| B4.3 | ADR-005 Authority Matrix table | **DEFERRED** — existing cell text ("Yes — degrades to coarse, never blocks") already conveys the trigger/consequence the worker wanted to add | DEFERRED |
| B4.4 | `docs/architecture-decisions/005-*.md` (Binding Conditions #1) | Added gloss: "Provenance (the origin and authorship of each state claim) must be visible to Swift; 'FFI boundary' here is the Rust↔Swift bridge exposed via UniFFI." + "so Swift can render which signal produced each state claim" | COMPLETE |
| B4.8 | `docs/ARCHITECTURE.md:44` (ActivationPolicy) | Replaced "explicit local fallback" jargon with named location + description of "documented local fallback ladder — explicit per-host rules in the policy itself" | COMPLETE |
| B4.9 | `.claude/docs/debugging-guide.md:10-16` (Runtime Surfaces) | Flat bullet list → per-item table with purpose/when-to-check for each runtime path | COMPLETE |
| B4.10 | `.claude/docs/debugging-guide.md:94-95` (activation evidence) | Passive "The reliable activation evidence is…" → active "To debug activation, collect two artifacts: (1) app debug log from TerminalLauncher…, (2) runtime service snapshot payload from /runtime/snapshot." | COMPLETE |

## Disposition: 6 applied, 6 deferred

## Verification

Re-read each edited passage end-to-end. All edits preserve semantics; no
factual claims changed. Authority/FFI jargon now has on-first-use definitions.
Debugging-guide runtime paths have explicit when-to-use guidance.
