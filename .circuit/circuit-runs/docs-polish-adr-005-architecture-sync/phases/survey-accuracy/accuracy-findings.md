# Accuracy Findings

## Summary
5 findings; 3 high-confidence, 2 low-confidence; 3 high-risk (canonical specs). Phase 2-3 completion claim mismatch between ADR-005 (complete) and ARCHITECTURE.md (Phase 1 only), plus stale hook count in ADR-005 Current-State table.

## Candidates

| # | File | Line/Anchor | Issue | Suggested Fix | Confidence | Risk | Uncertainty Note |
|---|---|---|---|---|---|---|---|
| 1 | docs/ARCHITECTURE.md | L33 | Claims "Today, only Phase 1 is shipped" but ADR-005 shows Phases 1-3 complete as of 2026-04-15 | Update to "ADR-005 Phases 1-3 are complete" with brief phase summary; link to ADR-005 verification sections | High | High | ARCHITECTURE.md last updated 2026-03-29 (commit 50b81fc1); current codebase at 2026-04-15 with Phase 2-3 verification boxes checked |
| 2 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | L18 (Current-State Snapshot table) | Claims hook events as "18 events, 14 managed" but actual HookEventType has 19 discriminants (17 real + 2 sentinels: Unknown, TranscriptActivity) | Update table to "19 events total (17 live + 2 sentinels), 14 managed" or "17 real events" to match current code at domain/types.rs:255-275 | High | Low | Line 27 claims "18 hook events" (also stale). TranscriptActivity added 2026-04-15 per Phase 2 Step 5 commit. Snapshot table is marked "as of 2026-03-29" (decision date), predates TranscriptActivity addition. |
| 3 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | L27 | Claims "Capacitor hardcodes 18 hook events" but current count is 19 (17 real + 2 sentinels) | Change to "17 real hook events + 2 sentinels (Unknown, TranscriptActivity)" | High | Low | Companion to finding #2; same root cause (snapshot predates Phase 2 Step 5) |
| 4 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | L119-122 | Phase 1 verification questions lack checkmarks despite Phase 1 work shipping in commit 50b81fc1 and ARCHITECTURE.md confirming hooks are optional | Check off Phase 1 boxes with completion notes (e.g., "[x] Complete (2026-03-29). Hook-gating removed; HookStatus now granular; isFirstRun uses setup marker." per commit 50b81fc1) | Low | Low | Phase 1 implementation is complete per ARCHITECTURE.md L35-36 and AGENT_CHANGELOG.md L14-16, but ADR checkboxes were never populated. Unclear if unchecked boxes indicate pending verification or oversight. |
| 5 | docs/ARCHITECTURE.md | L27 | Claims ADR-005 Phase 1 "keeps hooks as live state source while making hook setup non-blocking" as partial implementation; should acknowledge multi-signal authority (Phase 2-3) is complete | Revise to acknowledge Phase 1-3 completion and multi-signal architecture is now live: "ADR-005's Phases 1-3 are complete. Hooks remain authoritative for nuanced state; transcripts provide existence/recovery evidence; shell CWD provides routing only." | Low | High | L33 also claims Phase 1 is sole shipped phase, which contradicts the broader statement here. Both lines need alignment with current phase status. |

## Notes

- **Root cause of findings #1, #2, #3**: ARCHITECTURE.md last updated 2026-03-29 (Phase 1 only). Phases 2-3 shipped 2026-04-15. ADR-005 Current-State Snapshot and hook counts predate Phase 2 Step 5 (TranscriptActivity addition).
- **Phase verification status**: ADR-005 L119-137 shows Phase 2-3 fully verified (all checkboxes [x] complete). Phase 1 boxes remain empty despite work being complete. Recommend either: (a) populate Phase 1 completion notes, or (b) treat empty boxes as intentional (awaiting formal review outside scope of this ADR).
- **High-risk boundary**: ARCHITECTURE.md is marked "canonical-spec" and directly read-after architecture-primer. Stale phase claims here could mislead agents about which features are available.
- **No findings on**: `SessionSummary` structure (correct: `state_source`, `last_authoritative_event_at`, no `ready_reason`), `SignalAuthority` enum (correct 5 tiers), transcript consumer count (correct: ADR line 126 explicitly corrects "4+" to "6 existing"), cold-start reconstruction (verified in code), authority matrix enforcement (verified in code).
