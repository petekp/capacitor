# Batch 2: Accuracy Corrections with Evidence

## Items

| # | File | Action | Evidence | Result |
|---|---|---|---|---|
| B2.1 | `docs/architecture-decisions/005-*.md:119-122` | Phase 1 verification boxes populated with `[x]` + completion notes matching Phase 2/3 style | Commit `50b81fc1` (2026-03-29): "fix(setup): unblock app launch from hook-gating (ADR-005 Phase 1)" | COMPLETE |
| B2.2 | ADR-005 Current-State Snapshot header | Added clarifying note preserving historical intent while pointing readers to current state | Brief.md high-risk boundary rule: preserve frozen contents, clarify framing only | COMPLETE |
| B2.3 | `docs/ARCHITECTURE.md:27` (Runtime Data Flow step 3) | Rewrote "Phase 1 shipped / multi-signal planned" → "ADR-005 complete (Phases 1-3)" with authority-matrix summary | git log b7c0b0b9 confirms Phase 3 Q4 shipped | COMPLETE |
| B2.4 | `docs/ARCHITECTURE.md:31-39` (State Detection Architecture section) | Full rewrite: "Today only Phase 1 is shipped" → per-phase summary (shipped dates, commits, key functions) + authority matrix of what-signal-answers-what-question | All 3 phases verified complete in ADR-005 verification questions | COMPLETE (folds B2.3+B3.3+B5.4) |
| B2.5 | `CONTRIBUTING.md:86` | Routing fix: architecture → `.claude/docs/architecture-primer.md`; CLAUDE.md positioned as commands/workflow/gotchas | architecture-primer.md exists; CLAUDE.md self-describes as `task-runbook` | COMPLETE |
| B2.6 | `docs/ARCHITECTURE.md` Orchestration section intro | **DEFERRED** — existing line 52 already provides adequate context-setting ("two independent review flows that share a common window structure") | Adjudication re-read; no clear win | DEFERRED |
| B2.7 | `README.md:53-55` (Developing Capacitor) | Added intro clause explaining what formal verification does and why | Improves onboarding for non-verifier readers | COMPLETE |
| B2.8 | `AGENT_CHANGELOG.md:14` | Expanded ADR-005 entry with brief definitions of "nuanced-state authority" / "existence and recovery" / "routing-only" | Clarity fix for changelog readers without ADR context | COMPLETE |

## Verification

```bash
grep -rn "only Phase 1 is shipped\|still planned\|evidence replay/backfill" docs/ .claude/docs/ *.md
# → expected: zero matches (all retired framings gone)
```

Re-read ARCHITECTURE.md end-to-end: State Detection section now summarizes all 3 shipped phases + authority matrix; Runtime Data Flow step 3 reflects shipped state; "evidence replay/backfill" no longer appears.

## Disposition: COMPLETE (7 of 8 applied; 1 deferred)
