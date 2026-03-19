# Review Iteration — Design Spec

**Date:** 2026-03-19
**Status:** Approved for implementation
**Author:** Pete Petrash + Claude (collaborative brainstorming)

## Overview

Enable true review iteration in Capacitor's delegation system. After requesting changes
on a milestone, the worker produces a revised milestone that returns for re-review.
Multiple rounds of feedback are possible. The review surface moves from an inline panel
view to a dedicated zen-mode window optimized for deep artifact assessment.

## Problem

When a user requests changes on a delegation milestone, the worker resumes but is
instructed to finish and exit — it cannot produce a revised milestone for re-review.
The resume prompt says "Do not open another review checkpoint in this slice." This makes
request-changes effectively terminal: one round of feedback, then done.

Additionally, the current review UI is embedded in the floating HUD panel, which constrains
the space available for reading briefs, examining artifacts, and writing substantive feedback.

## Design

### 1. Standalone Review Window

The review surface becomes its own macOS window, independent of the floating HUD panel.

- New `Window(id: "delegation-review")` scene in the SwiftUI app
- Opened via `openWindow(id:)` when the project card routes to review
- The HUD project card shows a "Review Ready" badge; tapping it opens the review window
- The window dismisses after the user submits a decision
- Full screen real estate for reading and decision-making

### 2. Zen Layout with Decision Rail

The window uses a two-pane layout: scrollable content on the left, static decision rail
on the right.

**Left pane (scrollable content, ~65-70% width):**
- Artifact hero at top — screenshot, recording, or summary text (future: rich media)
- Milestone summary — the worker's description of what changed
- Metadata line: artifact count, test status
- Artifacts list — label + file path pairs from manifest.json
- Full brief text — loaded from brief.md
- Previous round context (revision 2+ only) — shows the user's last decision and note

**Right rail (static, ~30-35% width):**
- Each option is a card with a title and 1-2 line description
- Default cards:
  - **Approve** — "Ship this milestone and move on."
  - **Request Changes** — "Worker will address your feedback and submit a new revision."
  - **Write a Response** — "Provide custom instructions to the worker."
- Clicking Request Changes or Write a Response expands a text editor within the rail
- Single "Submit Decision" button at the bottom of the rail
- On revision 2+, cards adapt: pre-filled feedback from previous round, contextual labels
- Future: worker manifest can include suggested response options with descriptions

**Responsive behavior:** On very narrow windows, the rail collapses below the content pane.

### 3. Numbered Milestones Data Model

Milestone ID becomes dynamic. Each review round gets its own numbered directory.

**Disk layout:**
```
.capacitor/delegations/<worker>/
  status.md
  completion.json
  launch-prompt.md
  resume-prompt.md
  milestones/
    01/                          # first milestone
      brief.md
      manifest.json
      decision.json              # user's decision (immutable after write)
      decision.md
    02/                          # revision after request-changes
      brief.md
      manifest.json
      decision.json
      decision.md
    03/                          # current active review
      brief.md
      manifest.json
                                 # no decision.json — this is active
```

**Rules:**
- Each `request_changes` decision creates the next numbered directory
- The worker writes revision artifacts into the next number
- The highest-numbered milestone without `decision.json` is the active review
- Milestones with `decision.json` are immutable history
- `approve` on any milestone triggers completion — no new milestone created
- At most one milestone at a time lacks a `decision.json` (the active one)

**Rust reducer impact:**
- `MutateDelegationCommand` already carries `milestone_id: Option<String>`
- `DelegationReviewState` already has `milestone_id: String`
- The reducer's `ReviewReady` handler stores whichever milestone ID is passed
- The `Resume` handler clears `current_review` — correct for iteration (review state
  is wiped, new milestone pending)
- No new mutation kinds needed. No reducer behavior changes.

**Swift changes:**
- `Constants.milestoneID = "01"` replaced by computed `nextMilestoneID()` that scans
  the milestones directory
- `workerPaths()` takes a milestone ID parameter instead of using the constant
- `submitReviewDecision()` writes `decision.json` to the current milestone, then
  (for request-changes) passes the next milestone number in the resume prompt
- Previous round context read from prior milestone's `decision.json`

**Worker prompt changes:**
- Launch prompt: "Write milestone artifacts to milestones/01/" (unchanged)
- Resume after request-changes: "Write revised artifacts to milestones/02/" (new —
  replaces "do not open another review checkpoint")
- Resume after approve: "Finalize and write completion marker" (unchanged intent)

### 4. Reconciliation Loop Changes

The reconciliation scanner in `DelegationLoopManager.reconcile()` changes from
fixed-path checks to a milestone directory scan.

For each active delegation:
1. Check for `completion.json` → if found, mutate to `complete` (unchanged)
2. Scan `milestones/` for the highest-numbered directory
3. If that milestone has `decision.json` → skip (worker is addressing feedback)
4. If that milestone has `brief.md` + `manifest.json` but no `decision.json` →
   new or revised milestone ready for review. Mutate to `review_ready` with this
   milestone's ID
5. If the highest directory is incomplete (missing brief/manifest) → skip (worker
   still writing)

**Key invariant:** At most one milestone at a time lacks a `decision.json`. All
previous milestones have decisions. This makes the scan deterministic.

The reducer doesn't need to know about milestone numbering. It stores whatever
`milestone_id` Swift passes. The intelligence lives in the reconciliation scanner
and the resume prompt. This respects the architecture invariant: Rust owns truth,
Swift owns projection and reconciliation.

### 5. Testing Strategy

**Rust tests (unchanged):**
- Existing `delegation_contract.rs` tests pass various `milestone_id` values and
  continue to work. No new Rust tests needed since the reducer doesn't change behavior.

**Swift unit tests (new):**
1. Milestone scanning — `nextMilestoneID()` returns correct values for empty dir,
   dir with one decided milestone, dir with multiple decided milestones
2. Reconciliation with numbered milestones — detects highest undecided milestone
3. Reconciliation skips incomplete milestones — brief without manifest doesn't
   trigger review_ready
4. Decision write isolation — writes to correct milestone directory only
5. Resume prompt includes correct next milestone number

**Integration test (extend existing DelegationLoopManagerTests):**
- Full cycle: start → milestone 01 → review_ready → request_changes → resume →
  milestone 02 → review_ready → approve → complete

**Review window tests:**
- Window opens with correct milestone data
- Previous round context displays when revision > 1
- Decision rail actions dispatch correctly

## Architectural Notes

- The Rust reducer is already milestone-ID-agnostic — no changes needed
- Numbered milestones are a Swift-side filesystem convention, not a reducer concept
- This model is concurrency-ready: each worker already has its own milestone directory
  tree under `.capacitor/delegations/<worker>/milestones/`
- Milestone history is stored (all directories preserved) but a milestone archive UI
  is deferred — the previous round context in the review window is sufficient for now
- Rich artifact support (screenshots, recordings) is a future enhancement to the
  manifest format and review window hero area

## Non-Goals

- Milestone archive/history browser UI (deferred)
- Rich artifact rendering beyond file paths (deferred, manifest format extension)
- Orchestrator layer (register/reconnect/event journal) — not needed for this feature
- Multiple workers per project (concurrency) — model supports it but UI doesn't yet
- Snapshot fsync hardening (separate concern)
