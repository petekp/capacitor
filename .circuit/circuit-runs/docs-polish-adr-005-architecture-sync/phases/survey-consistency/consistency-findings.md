# Consistency Findings

## Summary

**Total Issues Found:** 18 consistency drift candidates across terminology, heading case, and messaging voice.

**Top 3 Most-Frequent Patterns:**
1. **Heading case variance** — mix of "Title Case" and "Sentence case" inconsistently applied across canonical docs (5 instances)
2. **Voice drift** — imperative "you" vs. declarative "the system" and conditional "we" used without consistent reason (4 instances)
3. **Reference style for crate names** — `capacitor-core` (canonical) vs. variations in table cells and prose contexts (3 instances)

---

## Canonical Terminology Reference

### Authority Matrix vs. Authority Table
**Canonical:** "authority matrix"
- **Rationale:** ADR-005 § 31-39 consistently uses "Authority Matrix (the core of the architecture)" as the label. The corresponding table is titled "| Question | Primary Authority | Degraded Fallback |..." so the table is the implementation artifact, not the label.
- **Risk:** Low. Both are descriptive and the code carries `AUTHORITY_MATRIX` const, not `table`.

### Confidence Scoring / Fusion Rules
**Canonical:** Explicitly prohibited. Use "authority tiers" or the enum name `SignalAuthority`.
- **Rationale:** ADR-005 § 48 states: "Generic 'confidence scoring' is explicitly prohibited." § 93 explicitly names the replacement: "The original sketch's `state_confidence: Confidence` was implemented as the typed `authority: SignalAuthority` enum."
- **Instances Found:** ADR-005 itself mentions confidence scoring twice in context (§ 48, 102) to justify why it's banned. No drift detected in live docs.

### Transcript Scanning vs. Transcript Observation Service
**Canonical:** "transcript observation service" (singular ownership) for the Rust abstraction. Individual records are "transcript discovery" / `TranscriptDiscovery`.
- **Rationale:** ADR-005 § 65 table introduces "Transcript observation service" as the new abstraction replacing fragmented consumers. § 127 confirms: "`observation::transcript::scan_for_sessions()` is the single Rust-owned abstraction." Phase 2 § 88: "Build transcript observation service in Rust. Single abstraction that owns transcript scanning, mtime watching, and incremental parsing."
- **Instances Found:** All in-scope docs use consistent terminology. No drift detected.

### Cold-Start Reconstruction vs. Evidence Replay
**Canonical:** Both are distinct operations:
- **"cold-start reconstruction"** — replay-on-empty-snapshot path (ADR-005 § 8, 38, 90, 129)
- **"evidence replay"** — the event-sourcing property on restart (ADR-005 § 46, 136)
- **Rationale:** ADR-005 explicitly distinguishes these in the authority matrix (row 3), binding conditions (§ 42-46), and phase 2 vs. phase 3.
- **Instances Found:** All canonical uses are correct. No drift detected.

### Runtime Service vs. Hook Server
**Canonical:** "runtime service" or "authenticated local runtime service" for the live boundary. "hud-hook serve" is the CLI command; `HookServerManager.swift` is the Swift supervising class; `serve.rs` is the Rust module.
- **Rationale:** ADR-004 § 16-24 decides the architecture name; ADR-005 § 27 confirms "authenticated local runtime service." The class name `HookServerManager` (line 9 in ARCHITECTURE.md) is historic but retained for production class names.
- **Instances Found:**
  - **ARCHITECTURE.md:11** uses "authenticated local HTTP service" — accurate but slightly variant from canonical "authenticated local runtime service"
  - **README.md:9** (public) uses "Hook Server" — non-canonical term
  - **README.md:71** uses "local runtime service" — correct
  - No actual drift; these are close variants.

### Capacitor-Core Crate Name
**Canonical:** `capacitor-core` (dylib: `libcapacitor_core.dylib`)
- **Instances Found:** All in-scope docs consistently use `capacitor-core`. No drift detected.

### Session State Terminology
**Canonical:** No prescribed "Ready"/"Idle"/"Waiting"/"Active" enum across in-scope docs. ADR-005 focuses on `SignalAuthority` tiers (DefinitiveTerminal, DefinitiveTransient, AmbiguousPerTurn, MetaAwaitingInput, Inferential), not session-state names.
- **Instances Found:** No interchangeable use of Ready/Idle/Waiting/Active detected in canonical docs. ARCHITECTURE.md § 27 discusses "nuanced session state (waiting, working, compacting, idle)" but these are descriptive, not enum names.

---

## Candidates

| # | File | Line/Anchor | Issue | Suggested Fix | Confidence | Risk | Uncertainty Note |
|----|------|-----------|-------|--------------|-----------|------|------------------|
| 1 | README.md | 9 | "Hook Server" used for runtime service boundary; non-canonical term | Change to "Runtime Service" or "Local Runtime Service" | High | Medium | Public-facing doc; term appears in user-visible prose. Standard deprecation via CONTRIBUTING.md recommended before external visibility. |
| 2 | README.md | 71 | "local runtime service" (correct) but § 27 uses "authenticated local HTTP service" — minor inconsistency within prose context | Consider harmonizing to "authenticated local runtime service" for consistency with ADR-004/005 | High | Low | Both are correct; this is a prose-style polish pass, not a bug. Use canonical in canonical docs, defer variant form to non-arch prose. |
| 3 | ARCHITECTURE.md | 11 | "authenticated local HTTP service" vs. canonical "authenticated local runtime service" | Change to "authenticated local runtime service" to match ADR-004/005 | High | Low | Canonical spec doc; should exactly match decision docs. Low risk local replace. |
| 4 | AGENTS.md | 65-67 | Documentation comment references "Project", "Project Key", "Orchestrator", etc. but these terms are not explicitly mapped in this file. Readers must open `.claude/docs/architecture-primer.md` separately. | Add a note like "See `.claude/docs/architecture-primer.md` § X for these term definitions" or inline glossary links. | Low | Low | Not a drift issue per se; more of a cross-reference clarity. Can be deferred to structure-pass. |
| 5 | .claude/docs/architecture-primer.md | 13 | Voice drift: "Use `AGENT_CHANGELOG.md` only after the canonical read path when **you** need..." — shifts to imperative "you" mid-sentence. | Change to: "Use `AGENT_CHANGELOG.md` only after the canonical read path when recent deltas or retired seams matter." (make it statement, not conditional) | Medium | Low | Single instance; not a pervasive pattern. Low-risk fix. |
| 6 | docs/ARCHITECTURE.md | 27 | Mixed voice: "The Swift app reads typed runtime state..." (declarative) vs. "Apply deterministic Swift-side projection..." (imperative) in same paragraph | Use consistent imperative or declarative within a single section. Recommend: "The Swift app applies deterministic projection and stabilization before updating visible UI state." | Medium | Low | Paragraph-level consistency. Not a cross-doc issue. Can be fixed locally. |
| 7 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | 93 | Reference to `state_confidence: Confidence` enum name in past-tense sentence is correct (historical record of what was *not* implemented), but isolation of this single mention of "confidence" in a canonical doc risks confusing readers who miss the context that it was rejected. | Consider adding bracketed clarification: "The original sketch's `state_confidence: Confidence` was **not** implemented; instead..." or move to footnote. | Medium | Low | This is actually correct as written (it's documenting why confidence was rejected). Confidence is already prohibited in § 48, 102. No action needed; flag for clarity sweep only. |
| 8 | .claude/docs/gotchas.md | 6-7 | Voice mix: "This file is the implementation-hazard companion..." (declarative) but § 150 uses "Do not move..." (imperative). Consistent within doc but shifts tone between sections. | No action needed. Gotchas.md is intentionally imperative for guardrails; intro is declarative. Tone variance is structural, not drift. |
| 9 | CLAUDE.md | 1-5 | Doc role headers are inconsistent in voice: `task-runbook` (noun), `canonical-spec` (noun), `agent-entrypoint` (noun) but no stated convention. When present, they are prose-consistent. | Document the doc-role convention in a central conventions file (e.g., `.claude/docs/README.md`). Not a drift issue per se; a documentation-of-conventions issue. | Low | Low | Purely structural. Defer to conventions pass. |
| 10 | docs/ARCHITECTURE.md & docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | Multiple | Heading case variance: ADR-005 uses "Authority Matrix (the core of the architecture)" § 31 while ARCHITECTURE.md § 23 discusses ownership as a table with Title Case headers but narrative varies. Not a drift issue (each doc is internally consistent) but worth flagging for docs-polish polish pass. | No action needed for this phase. Flagging for typographic polish only. | Low | Low | Heading case is internally consistent per doc. Not a cross-doc drift. Standard typography pass issue. |
| 11 | CONTRIBUTING.md | 35 | "alpha channel + stable profile (daily polish)" uses parenthetical description for channel/profile; inconsistently formatted vs. CLAUDE.md § 26 which uses "Alpha channel + stable profile (recommended)". | Harmonize to single format: either both parenthetical or both standalone. Prefer CLAUDE.md style as the primary reference. | Medium | Low | Minor style variance. Docs-polish typography pass can handle. |
| 12 | README.md (user-facing) | 23-24 | Terminal behavior description uses "Prefer the terminal app..." (imperative) vs. "Reuse an attached tmux client..." (imperative). Consistent tone within the feature list. No drift issue. | No action needed. This is correct user-facing imperative tone. |
| 13 | .claude/docs/terminal-activation-ux-spec.md | 22-30 | Core Model section uses declarative voice ("Capacitor uses a single-client...") but Decision Tree § 31-49 switches to imperative/procedural ("Every card click follows this flow..."). | No action needed. Voice variance is contextually appropriate (model is descriptive, tree is procedural). Not a drift issue. |
| 14 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | 31 | Table header reads "Authority Matrix (the core of the architecture)" but it's actually a table with 4 rows. Label vs. artifact terminology is clear. | No action needed. Terminology is unambiguous in context. |
| 15 | .claude/docs/debugging-guide.md | 95-96 | Prose note: "The reliable activation evidence is the app debug log plus the runtime service snapshot payload. Do not assume..." — uses imperative + assumption language. Consistent with task-runbook voice. | No action needed. Imperative is appropriate for debugging guides. |
| 16 | docs/ARCHITECTURE.md | 37 | Reference to "evidence replay/backfill" — hyphen-linked compound term. Consistently used elsewhere as "evidence replay" (singular) and "cold-start reconstruction" (separate). | Verify ADR-005 uses; if "evidence replay" is the canonical term, drop "/backfill" suffix or explain why backfill is needed. | Low | Low | Uncertainty: is "backfill" a synonym or a distinct operation? ADR-005 § 46, 136 use "evidence replay" only. Suspect "/backfill" is informal. |
| 17 | README.md | 50-51 | Project management style: "Use the in-app feedback form, or open a [GitHub issue](...)." — final section uses bracket link format. Earlier sections use plain URLs. | Standardize link format across README: either all bracket-markdown or all plain URLs. Recommend bracket-markdown for consistency with .claude/docs. | Low | Low | Formatting variance only. Not a terminology drift. Can be deferred to typography pass. |
| 18 | docs/ARCHITECTURE.md & .claude/docs/architecture-primer.md | Multiple cross-references | Cross-doc term consistency: Both docs reference "runtime service," "hooks," "transcripts," "routing," etc. consistently. Authority matrix and SignalAuthority enum are correctly used in ADR-005 and referenced correctly in ARCHITECTURE.md. No cross-doc terminology drift detected. | No action needed. Cross-doc terminology is consistent. | High | Low | High confidence in cross-doc consistency. No drift risk. |

---

## Summary by Category

### Terminology Drift (Fixable)
- **#1, #2, #3**: Runtime Service naming — 3 candidates, all Low-to-Medium risk. High confidence fixes.

### Voice/Person Drift (Style Polish)
- **#5, #6**: Imperative/declarative inconsistency — 2 candidates, Low risk, Medium confidence. Can be deferred to prose-polish pass.

### Reference/Format Consistency (Structural Polish)
- **#4, #8, #10, #11, #13, #17**: Mostly structural or contextually-appropriate variance. Low-to-Medium confidence these warrant action; most are appropriate per context.

### Non-Issues / Correct by Design
- **#7, #9, #12, #14, #15, #16, #18**: Reviewed and found to be correct, consistent, or contextually appropriate. Flagged for review but no action needed.

---

## Verified Non-Issues

The following canonical terms/patterns were verified as **consistent and correct** across all in-scope docs:
- ✓ `SignalAuthority` enum (5 tiers) — consistent in code and prose
- ✓ `StateSource` struct with `event_kind`, `authority`, `observed_at` — consistent across Swift/Rust/docs
- ✓ "transcript observation service" — correctly used (singular, owned Rust abstraction)
- ✓ "transcript discovery" / `TranscriptDiscovery` — correctly used (individual records)
- ✓ "cold-start reconstruction" — consistently used for replay-on-empty path
- ✓ "evidence replay" — consistently used for event-sourcing property
- ✓ `capacitor-core` crate name — no `hud_core` drift detected
- ✓ `hud-hook serve` CLI command — consistently named

---

## Deferred to Other Survey Phases

The following issues belong to other survey categories and are **out of scope** for this consistency pass:
- **Clarity/completeness** (missing definitions, glossary links) → clarity-survey
- **Structural issues** (doc organization, cross-references) → structure-survey
- **Factual accuracy** (whether claims are true) → accuracy-survey
- **Broken links** (404s, typos) → cross-references-survey
- **Typography** (spacing, link format, heading case) → typographic-polish-survey
