# Freshness Findings

## Summary
4 findings: 3 "pending work that shipped" + 1 stale inventory snapshot

## Candidates

| # | File | Line/Anchor | Issue | Suggested Fix | Confidence | Risk | Uncertainty Note |
|---|------|----------|-------|----------------|------------|------|------------------|
| 1 | `docs/ARCHITECTURE.md` | 27 | "the broader multi-signal authority model is still planned" — All 3 ADR-005 phases (Phase 1, Phase 2, Phase 3) shipped 2026-03-29 through 2026-04-15 (commits 77ebe7f through b7c0b0b9); authority matrix implementation, transcript observation service, evidence replay, and cold-start all delivered and verified. This sentence frames multi-signal as future work when it is now live. | Replace "still planned" with "shipped in phases 2-3 (2026-04-15)" or similar; or restructure to: "ADR-005 decided the authority-based multi-signal direction. Phase 1 (late March) unblocked hooks at startup. Phases 2-3 (April 12-15) delivered transcript observation, authority enforcement, and evidence replay as contract-tested completions." | High | Low | Commit history proves all phases are complete via verification checkboxes |
| 2 | `docs/ARCHITECTURE.md` | 33 | "ADR-005 defines the planned state-detection direction. Today, only Phase 1 is shipped." — This is outdated as of 2026-04-15. All three phases are shipped and verified. Phase 2 (transcript observation, cold-start) and Phase 3 (provenance fields, authority enforcement, evidence replay) completed April 12-15, with final Q4 test (evidence replay equivalence) landing April 15 (b7c0b0b9). | Replace with: "ADR-005 authority-based multi-signal state detection is complete. All three phases shipped April 2026: Phase 1 unblocked startup (late March), Phase 2 added transcript observation and cold-start (April 12-14), Phase 3 enforced authority matrix and evidence replay (April 15)." | High | Low | Verification checkboxes in ADR-005 all marked [x]; commit log confirms final landing |
| 3 | `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md` | 88 | "Replace the 4+ fragmented consumers" — Current count is 6 fragmented consumers (3 Rust, 3 Swift), per line 126 in the same document ("6 existing fragmented consumers remain"). The "4+" is a stale lower-bound estimate from early Phase 2 work. | Update line 88 from "4+ fragmented" to "6 fragmented" (matches the verified count at line 126). | High | Low | Line 126 contains current inventory count verified against source code (runtime_stats.rs, runtime/projects.rs, core_query.rs, ProjectCreationCoordinator.swift, DelegationLoopManager.swift, SessionSummarizer.swift) |
| 4 | `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md` | 14 | Current-state snapshot table row line 18 labels "Hook lifecycle callbacks" as outdated in context: table is dated 2026-03-29 (decision date), but it shadows the modern hook count. The snapshot says "(18 events, 14 managed)" per ADR decision snapshot; this is the pre-ship inventory and is no longer synchronized with today's running code. Acceptable to leave as historical snapshot of the decision moment, but should be flagged as "as decided" to avoid confusion with live state. | Add footnote to table title: "**Current-State Snapshot (as of 2026-03-29, the ADR decision date)**" or move table to an "Original Decision Snapshot" subsection with a note that line 126 contains post-implementation counts. | Low | Low | This is a historical snapshot section that is correctly dated in the header (line 14), so risk of confusion is lower if the role is clarified. Not wrong, just potentially confusing. |

## Detailed Notes

### Stale framing across ARCHITECTURE.md

Lines 27 and 33 both claim the multi-signal authority model is "still planned" or only "Phase 1 is shipped," but:

- ADR-005 binding conditions (lines 40-49 in the ADR doc) all have [x] checkboxes
- Phase 1 verification questions (lines 119-122): all checked complete ✓
- Phase 2 verification questions (lines 124-130): all checked complete ✓, 2026-04-16 timestamps
- Phase 3 verification questions (lines 132-137): all checked complete ✓, 2026-04-15 final integration test (evidence replay equivalence)
- Commit b7c0b0b9 (latest) explicitly states "evidence replay equivalent to continuous live ingest (ADR-005 Phase 3 Q4)"

The architecture spec is now out of sync with the decision document and the shipped code. ARCHITECTURE.md needs a refresh to reflect that Phases 2 and 3 are complete.

### Inventory snapshot (fragmented consumers)

Line 88 of ADR-005 says "4+" but line 126 of the same document (part of the Phase 2 verification answer) says "6 existing fragmented consumers remain." This is not a bug—the 6 count is more recent and precise. The "4+" was a working estimate when Phase 2 was being scoped. No code change needed; the Phase 2 step description just needs the inventory updated.

---

*Survey run: 2026-04-15 (post-b7c0b0b9 commit) | Scope: ADR-005, ARCHITECTURE.md, and 10 doc files | Focus: Shipped work framed as pending; stale inventory counts; verification checkboxes*
