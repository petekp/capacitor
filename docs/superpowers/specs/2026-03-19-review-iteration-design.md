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
- **"Write a Response" is a UI alias for Request Changes** — both produce
  `ReviewDecision.requestChanges` with a note. The distinction is ergonomic:
  Request Changes conveys "this needs fixing," Write a Response conveys "here are
  instructions." No new enum variant is needed. The note text is always passed
  through regardless of which card the user picks.
- Clicking Request Changes or Write a Response expands a text editor within the rail
- Single "Submit Decision" button at the bottom of the rail
- On revision 2+, cards adapt: pre-filled feedback from previous round, contextual labels
- Future: worker manifest can include suggested response options with descriptions

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
- `Constants.milestoneID = "01"` replaced by a `nextMilestoneID(workerRoot:)` function
  that scans the milestones directory, sorts numerically, and returns the next ID.
  Format: 2-digit zero-padded strings ("01", "02", ..., "99"). For an empty directory,
  returns "01". Sorting is numeric (not lexicographic) to avoid "10" sorting before "02".
- `WorkerPaths` struct is split: worker-root paths (status, completion, prompts) are
  computed once per worker; milestone-specific paths (brief, manifest, decision) are
  computed per milestone ID. A new `milestonePaths(workerRoot:milestoneID:)` function
  returns only the milestone-specific subset. `workerPaths()` composes both for
  backward compatibility.
- Reconciliation calls a new `activeMilestoneID(workerRoot:)` function that scans
  the milestones directory and returns the highest-numbered directory lacking
  `decision.json`. Returns nil if all milestones have decisions (worker is working).
- `submitReviewDecision()` writes `decision.json` to the current milestone, then
  (for request-changes) passes the next milestone number in the resume prompt
- Previous round context: the review window reads `decision.json` from milestone
  N-1 (where N is the current active milestone's numeric ID, zero-padded). For
  milestone "01" there is no previous round. The lookup is: parse current ID as
  Int, subtract 1, format as "%02d", read from that directory.
- `decision.md` is written alongside `decision.json` for human readability only.
  It has no control-flow role — reconciliation and state transitions check only
  `decision.json`.

**Worker prompt changes — `buildResumePrompt()` full rewrite for request-changes:**

The current `buildResumePrompt()` (lines 953-988) has 8 requirements all oriented
around "finish and exit." For the request-changes path, most of these must change.
The function will branch on the decision:

*After approve:*
- Requirements 3, 6-8 stay: finalize, update status, write completion marker, exit
- Requirement 5 stays: do not open another review checkpoint

*After request-changes:*
- Requirement 4 changes: "Address the requested delta and produce a new milestone"
- Requirement 5 inverts: "You MUST produce a new review checkpoint in milestones/{next}/"
- Requirements 7-8 do NOT apply: no completion marker, no exit after writing milestone
- New requirements: write `brief.md` and `manifest.json` to `milestones/{next}/`,
  then exit (the reconciliation loop will detect the new milestone)

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
previous milestones have decisions. This makes the scan deterministic. The invariant
is enforced by the flow: the worker can only create milestone N+1 after the user
decides milestone N and the resume prompt instructs the worker to write to N+1.

**Idempotency:** If two reconciliation cycles overlap and both detect the same
undecided milestone, the `review_ready` mutation will succeed twice — the reducer
overwrites `current_review` with the same data. This is safe (idempotent) but
wasteful. No guard is needed since the cost is negligible.

**Edge case — empty milestones directory:** If `milestones/` exists but has no
subdirectories (worker killed before creating `01/`), `activeMilestoneID()` returns
nil and reconciliation skips the delegation. The worker will eventually create `01/`.

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

## Implementation Phasing

This spec bundles two largely independent changes: the numbered milestone data model
(core feature) and the standalone review window (UX improvement). They can be
implemented and tested in sequence:

1. **Phase 1: Numbered milestones + reconciliation** — data model, scanning,
   resume prompt rewrite, reconciliation changes. Test with the existing inline
   review view (update it to pass the dynamic milestone ID). This phase delivers
   the core review iteration loop.
2. **Phase 2: Standalone review window** — new Window scene, zen layout, decision
   rail, previous round context display. This phase delivers the UX improvement.

Phase 1 is the critical path. Phase 2 can follow immediately or be deferred.

## Non-Goals

- Milestone archive/history browser UI (deferred)
- Rich artifact rendering beyond file paths (deferred, manifest format extension)
- Orchestrator layer (register/reconnect/event journal) — not needed for this feature
- Multiple workers per project (concurrency) — model supports it but UI doesn't yet
- Snapshot fsync hardening (separate concern)
