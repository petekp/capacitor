# Mission: Review Iteration

## Problem
When a user requests changes on a delegation milestone, the worker resumes but is
instructed to finish and exit — it cannot produce a revised milestone for re-review.
The resume prompt (DelegationLoopManager.swift:977) says "Do not open another review
checkpoint in this slice." This makes request-changes effectively terminal: one round
of feedback, then done.

## Goal
Enable true review iteration: after request-changes, the worker produces a revised
milestone that returns to review_ready, letting the user review again. Multiple rounds
of feedback should be possible.

## Current Flow
1. Worker produces milestone artifacts → reconciliation detects → review_ready
2. User sees DelegationReviewView → clicks "Request Changes" with note
3. submitReviewDecision() writes decision file, mutates state to "resume", launches
   `claude --resume` with feedback prompt
4. Worker addresses feedback → writes completion marker → done (NO re-review)

## Desired Flow
1-3: Same as above
4. Worker addresses feedback → produces NEW milestone artifacts → exits
5. Reconciliation detects new milestone → review_ready (again)
6. User sees updated review UI → can approve or request more changes
7. Repeat until approved

## Key Files
- DelegationLoopManager.swift:953-988 — buildResumePrompt (needs to allow new milestones)
- DelegationLoopManager.swift:495-571 — reconcile (needs to detect new milestones after resume)
- DelegationReviewView.swift — review UI (may need revision context)
- core/capacitor-core/src/reduce/mod.rs:233-452 — delegation reducer

## Constraints
- Must not break the approve flow (approve → complete → done)
- Must not break the existing reconciliation loop
- Worker must not loop forever producing milestones — the user controls the loop
- Milestone artifacts should have revision numbers so the user can see history
