# Async Idea Delegation UX Exploration

Status: exploratory, non-prescriptive

Last updated: 2026-03-13

## Purpose

Capture the current thinking around an async idea-delegation feature for Capacitor in a way that is easy to resume later.

This document intentionally records possibilities, tensions, and working hypotheses rather than decisions. The goal is to preserve momentum and context without prematurely hardening the feature into a spec.

## Working Frame

We are exploring a feature where a user can quickly capture an idea when inspiration strikes, let Claude interpret it asynchronously, and then move from rough thought to concrete work with very little ceremony.

The hoped-for feeling is:

> "I delegated this to an experienced teammate. They mostly got it. They showed me something concrete fast. Correcting them was cheap. I stayed in flow."

## What We Are Not Trying To Build

At least for the current exploration phase, this should not drift into:

- a full task manager
- a kanban board
- a multi-column backlog UI
- a visible dependency graph editor
- a second product surface detached from Capacitor's sidecar model
- a workflow that requires the user to manually structure ideas before the agent can be useful

The internal implementation may eventually use structured execution state, but the user-facing experience should stay much lighter than the machinery behind it.

## North Star UX

The ideal loop is:

1. User drops in a rough idea with almost no friction.
2. The agent interprets it and returns one strong recommended direction.
3. The user sees a succinct explanation and a concrete example artifact.
4. The user either:
   - approves the direction
   - clicks a predictive pivot
   - answers one high-signal clarifying question
5. The agent begins work and stays out of the way until there is something meaningful to review or a decision that materially changes the implementation.
6. The user reviews the result, nudges if needed, and moves on.

The user should feel like they are delegating, not managing.

## Product Posture

The agent should usually:

- recommend one interpretation, not many
- only ask questions when the answer materially changes execution
- use examples, diagrams, wireframes, or other concrete artifacts to reduce ambiguity
- surface likely misunderstandings as clickable pivots
- avoid forcing the user to read long proposal documents

The agent should not usually:

- ask broad "what did you mean?" questions
- silently go build a risky interpretation of a vague prompt
- produce three or four equally-weighted proposals unless the ambiguity is truly irreducible
- require the user to become a project manager

## How This Could Fit Into The Current App

The most plausible near-term fit is within Capacitor's existing sidecar shell.

Current surfaces that seem relevant:

- project-card home in `ProjectsView`
- per-project detail in `ProjectDetailView`
- full-window capture overlay in `IdeaCapturePopover`
- existing idea detail modal pattern in `IdeaDetailModal`

Working hypothesis:

- keep project cards as the main home view
- keep fast idea capture as an overlay
- add lightweight per-project async delegation status to the cards
- use full-window overlays for proposal and review moments
- keep deeper execution machinery mostly out of sight

This suggests a future experience that still feels like Capacitor, not a separate app mode.

## Candidate User-Facing States

These are candidate user-visible states only. They are not meant to mirror the full internal lifecycle.

- `Thinking`
- `Proposal ready`
- `Needs your input`
- `Building`
- `Ready for review`

Working hypothesis:

These five are probably enough for trust and comprehension.

States we probably want to avoid surfacing:

- `triaged`
- `decomposed`
- `queued`
- `blocked`
- `hydrating`
- `routing`
- any internal agent orchestration jargon

## Candidate Information The User Should Always Be Able To Answer

At a glance, the user should be able to tell:

- What is Claude working on right now?
- Is Claude still interpreting, or has it started real implementation work?
- Does Claude need anything from me?
- Is there something ready to review?
- Where can I jump in if I want to inspect the real work?

Working hypothesis:

If we fail these five questions, the feature will feel spooky or cumbersome even if the underlying automation is strong.

## Candidate Main Surfaces

### 1. Project Card Async Status

Potential addition to each project card:

- one lightweight line showing the latest delegation state
- examples:
  - `Proposal ready: cleaner project details`
  - `Building: onboarding refresh`
  - `Needs your input: resume direction`
  - `Ready for review: details redesign`

Why this feels promising:

- stays inside the current home screen
- makes async work visible without building a separate dashboard
- preserves project cards as the primary navigation object

### 2. Full-Window Proposal Overlay

Potential role:

- open when the agent has a recommendation ready
- show the raw idea, interpreted intent, one concrete artifact, one primary CTA, and a few predictive pivots

Working content shape:

- raw idea
- `I think you mean...`
- example artifact
- `I'd build it by...`
- pivot chips
- primary action: `Build it`

### 3. Full-Window Review Overlay

Potential role:

- open when work is ready for review
- show what the agent thought the goal was, what changed, what evidence exists, and what the user can do next

Working content shape:

- interpreted goal
- result preview
- summary of changes
- evidence or checks
- CTAs:
  - `Accept`
  - `Polish it`
  - `Try another direction`

### 4. Compact "Needs You" Strip

Potential role:

- sit above the project list when there are unresolved high-signal questions or ready-for-review items
- act as a lightweight inbox, but only for important interruptions

Working hypothesis:

This may be enough to keep async work discoverable without inventing a dedicated inbox screen.

## Candidate Proposal Pattern

We have repeatedly gravitated toward the following structure because it seems both high-signal and low-friction:

1. One recommended interpretation
2. One concrete example artifact
3. A small set of predictive pivots
4. One primary approval action

Example shape:

```text
I think you want the project details page to feel more intentional and less like an internal debug surface.

That would likely look like:
- a stronger top section
- a clearer hierarchy
- secondary information grouped more quietly

[wireframe / diagram / mock]

[Build it] [More minimal] [Keep structure] [More native Mac]
```

Working hypothesis:

Showing one strong read plus cheap corrections may be better than showing several long proposals.

## Candidate Review Pattern

The review moment seems especially important for trust.

Working hypothesis:

The review surface should answer four questions quickly:

- What did you think I meant?
- What did you actually do?
- What evidence do we have?
- What should I decide next?

Potential shape:

```text
Goal I executed:
Make the details page feel less like a debug panel.

What changed:
- stronger hierarchy
- integrated ideas area
- quieter secondary metadata

Evidence:
- tests passed
- 4 files changed
- preview attached

[Accept] [Polish it] [Try another direction]
```

## Mock User Journeys

These are not final flows. They are intended to preserve promising directions for later exploration.

### Journey A: Clear Idea, Fast Approval

User input:

> "Make the project details page feel less like a debug panel."

Potential experience:

1. User captures the idea from the project card.
2. Card briefly shows `Thinking`.
3. Card updates to `Proposal ready`.
4. User opens proposal overlay.
5. Agent shows one interpretation plus a wireframe.
6. User clicks `Build it`.
7. Card updates to `Building`.
8. Later, card updates to `Ready for review`.

Why it matters:

This is the ideal path. It should feel nearly effortless.

### Journey B: Ambiguous Idea, Cheap Correction

User input:

> "Make onboarding less awkward."

Potential experience:

1. Agent returns one recommended interpretation.
2. The recommendation includes an example and a few likely pivots:
   - `Friendlier copy`
   - `Reduce setup steps`
   - `Visual polish only`
3. User clicks `Reduce setup steps`.
4. Agent updates the proposal without forcing a full re-prompt.

Why it matters:

Misinterpretation is inevitable. The cost of correction is central to the UX.

### Journey C: A Real Fork Requires Input

User input:

> "Help me resume interrupted work."

Potential experience:

1. Agent identifies two materially different interpretations:
   - restore product/task context
   - restore terminal/session context
2. Instead of asking an open question, the agent presents both with consequences.
3. User clicks the intended direction.

Why it matters:

This is the kind of interruption that may actually feel helpful instead of annoying.

### Journey D: Returning Later

Potential experience when the user reopens the app:

- one project card says `Building: onboarding refresh`
- another says `Needs your input: resume direction`
- a top strip says `Ready for review: project details redesign`

Why it matters:

Async delegation only works if re-entry is effortless.

## Things To Emphasize

- recommendation-first UX
- examples over explanations
- very cheap correction paths
- one clear active item per project
- clear linkage to the real session, worktree, or execution context
- concise review moments
- agent autonomy with explicit escape hatches

## Things To Avoid

- anything that feels like backlog grooming
- forcing users to title, prioritize, or categorize every idea manually
- overexposing internal agent machinery
- large branching proposal trees
- long clarifying questionnaires
- concurrent visible work exploding into a dashboard
- async activity that is invisible until it surprises the user

## Tensions Worth Revisiting Later

These are unresolved on purpose.

### How much should happen automatically?

Open tension:

- Should the agent stop at proposal by default?
- Should some low-risk ideas auto-start after proposal generation?
- Should there be per-project autonomy levels?

### How much history should be visible?

Open tension:

- Do users want a quiet archive of past delegations?
- Or should only active and review-ready items be visible most of the time?

### How much should the feature live at the project level vs global level?

Open tension:

- Should all delegation start from a project?
- Could there be a lightweight global inbox later?

### How visual should the proposals be?

Open tension:

- How often can we realistically produce a useful wireframe or diagram in the sidecar footprint?
- When is a text example better than a visual artifact?

### How much correction should come from chips vs freeform text?

Open tension:

- Predictive pivots feel promising, but only if they are usually right.
- Overly generic chips could feel canned or patronizing.

## Working UX Principles

These are not commitments. They are current design instincts that feel worth preserving.

### Invisible orchestration, visible intent

The user should not need to understand the internal execution model, but they should never be confused about what the agent thinks it is doing.

### Preserve the raw idea

The original thought should remain visible even after the agent interprets it.

### One strong read is better than several weak ones

When possible, the agent should recommend a direction rather than present a menu of equally-weighted options.

### Use questions sparingly, but make them count

If the agent asks something, the user should immediately understand why it matters.

### Keep the correction loop cheap

Redirection should feel like steering, not restarting.

### Review is part of the product, not an afterthought

The review surface may be where trust is won or lost.

## Candidate UI Shape Inside The Current Sidecar

Working hypothesis for a near-term prototype:

1. Keep the current project list home.
2. Add a compact top strip for `Needs your input` and `Ready for review`.
3. Add one async delegation row to project cards.
4. Use a full-window overlay for proposal and review moments.
5. Add a small `Agent Delegation` module near the top of project detail.
6. Keep the current idea queue/history quieter than the new active delegation surface.

This feels like the least disruptive way to explore the feature while staying grounded in the current app.

## Open Product Questions

- What kinds of ideas should always stop at proposal?
- What kinds of ideas might be safe to auto-build?
- How should we indicate that a proposal is still speculative?
- How many active delegations per project should we allow before the sidecar feels noisy?
- What should the user see when the agent loses confidence mid-build?
- How should this interact with existing workstreams and project creation flows?
- Does the user need an explicit "pause" action?
- When should the app proactively notify vs stay quiet?

## Good Restart Points For A Future Session

If we revisit this later, likely good next threads are:

- compare the `project-card + overlay` approach against a more delegation-first project detail
- sketch concrete proposal-overlay copy for 3 idea types:
  - UI redesign
  - bug fix
  - architecture idea
- explore how a review overlay should link into the real terminal/session/worktree context
- decide whether predictive pivots should be static patterns or generated per idea
- identify the minimum hidden execution model needed to support the visible UX

## Summary

The strongest current direction is a lightweight delegation experience inside Capacitor's existing sidecar shell:

- capture rough ideas quickly
- return one strong recommendation
- make corrections cheap
- keep active work visible
- make review compact and trustworthy

The core aspiration is not "manage tasks better."

It is:

> "Capacitor helps me delegate rough ideas to an agent that mostly gets me, shows me something concrete fast, and only interrupts me when it really should."
