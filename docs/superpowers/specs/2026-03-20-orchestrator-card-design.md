# Orchestrator Card Design

**Date:** 2026-03-20
**Status:** Draft

## 1. Vision

The project card should feel like a calm supervision instrument: easy to scan, quiet while work is healthy, and unmistakable when a decision is needed. It should help the user circuit across projects with minimal recall cost, routing them to the most useful next surface with one click.

## 2. Design Principles

- ADHD-friendly: reduce recall, keep targets stable, and make each card answer "what is happening here?" at a glance.
- Supervisor mode: the card is the primary loop, not the details view and not the terminal.
- Calm by default: active work should look alive without demanding attention; interruption is reserved for review, failure, and completion.
- One signal per concept: avoid duplicate indicators, competing badges, or hover-only controls.
- Runtime-backed truth: card state comes from runtime read models plus existing session indicators, not ad hoc file parsing in SwiftUI.

## 3. Card Layout

With orchestration enabled, the card has a fixed three-row layout with three interaction zones.

- Row 1: project name on the left in monospaced text; status badge on the right.
- Row 2: one-line orchestration context showing the active milestone title. This row exists only when orchestration is enabled.
- Row 3: always-visible action bar with two half-width buttons: `Idea` and `Details`.
- The action bar preserves room for future card-level actions without reusing the primary click zone.
- Rows 1-2 together form the primary click zone. Row 3 is a separate action zone. Targets do not overlap.
- The project name is display text only. Details are opened from the action bar, not from the name.

```text
+--------------------------------------------------+
| capacitor                              [WORKING] |
| Auth system refactor                             |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+

Primary zone: rows 1-2
Secondary zones: row 3 left = Idea, row 3 right = Details
```

Without orchestration:

```text
+--------------------------------------------------+
| capacitor                                [READY] |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

## 4. Card States

### Working

- Badge shows the live session state: `WORKING`, `WAITING`, `COMPACTING`, `READY`, or `IDLE`.
- Context line shows the current milestone title.
- Background treatment comes from the existing session-state system.
- Primary click routes to the orchestrator terminal.

```text
+--------------------------------------------------+
| capacitor                              [WORKING] |
| Auth system refactor                             |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

### Needs Decision

- Badge shows `REVIEW` or `FAILED`.
- Context line shows the milestone that needs intervention.
- Background treatment is review-specific or error-specific, not a generic live-session glow.
- Primary click opens the review surface for `REVIEW` and the orchestrator terminal for `FAILED`.

```text
+--------------------------------------------------+
| capacitor                               [REVIEW] |
| Settings page layout                              |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

```text
+--------------------------------------------------+
| capacitor                               [FAILED] |
| Settings page layout                              |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

### Done

- Badge shows `DONE`.
- Context line shows what completed.
- Background treatment settles into a dim green completion state.
- Primary click routes to the orchestrator terminal for the next step.
- The state lingers until the user acknowledges or parks it.

```text
+--------------------------------------------------+
| capacitor                                 [DONE] |
| Keyboard shortcuts                                 |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

### Orchestration Off

- Badge shows only the live session state.
- No context row is shown.
- Action bar remains available.
- Primary click preserves current terminal-routing behavior.

```text
+--------------------------------------------------+
| capacitor                              [WAITING] |
|--------------------------------------------------|
| [ Idea ]                              [ Details ]|
+--------------------------------------------------+
```

## 5. Indicator Composition

Two layers compose into one card:

- Session layer: always present. It answers what the agent process is doing right now and drives the existing badge/glow system.
- Orchestration layer: optional. It answers where the delegation loop is and whether the user needs to act.

Composition rules:

- In `Working`, the session layer carries the badge and motion because "alive" is the useful signal.
- In `Needs Decision`, the orchestration layer takes the badge slot with `REVIEW` or `FAILED`; a background session state like `IDLE` is not promoted.
- In `Done`, the orchestration layer takes the badge slot with `DONE`.
- With orchestration off, the session layer is the whole story and behavior stays as it is today.

## 6. Interactions

- Primary click on rows 1-2 routes to the most useful next surface.
- `Working` -> orchestrator terminal.
- `Review` -> review surface.
- `Failed` -> orchestrator terminal.
- `Done` -> orchestrator terminal.
- Orchestration off -> terminal.
- `Idea` opens idea capture for this project.
- `Details` opens the details view.
- The action bar is always visible; no hover-reveal controls.
- Right-click context menu remains: `Open in Terminal`, `Capture Idea...`, `View Details`, `Hide`, `Disconnect`.

## 7. Self-Healing

Stale orchestrator recovery is automatic and not a user-facing state. If Capacitor detects that the registered orchestrator is gone or disconnected, it silently relaunches or reconnects using prior context and runtime state; a brief loading state is acceptable, but a `stale_orchestrator` card mode is not.

## 8. Details View

The details view is the planning surface for the project's delegated task queue.

- Show an ordered list of delegated tasks with statuses such as `WORKING`, `REVIEW`, `DONE`, `NEXT`, and `FAILED`.
- The current task mirrors the state shown on the card.
- Queued tasks are visible ahead of time so the user can understand what is next without opening the terminal.
- Support three direct interactions: add a task, delete a task, and reorder by drag.
- Ideas captured from the card remain raw inputs; the details view shows the shaped task queue, not the raw idea backlog.
- This view may later expand with project configuration, delegation history, and worker details, but it is not the main supervision loop.

## 9. What's Removed and Why

- Hover-reveal buttons are removed. Actions now live in a stable action bar with separate hit targets.
- The project name is no longer clickable. Rows 1-2 are reserved for the primary route.
- Redundant delegation indicators are removed. The badge carries state and the context line carries the milestone title.
- `stale_orchestrator` is removed as a user-facing card state. Recovery happens behind the scenes.
- Scrapped PRD concepts remain out of scope: no urgency metadata, no attention lanes, no review queue navigation, no structured evidence contracts, and no notification escalation model.
