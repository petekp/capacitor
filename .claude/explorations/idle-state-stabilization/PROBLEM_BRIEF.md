# Problem Brief: Idle State Stabilization

## Problem statement

The Capacitor HUD occasionally shows a project card as "idle" for a brief moment while a Claude Code session is still active. The card then returns to its correct state on the next polling cycle. This creates a jarring visual flicker that undermines trust in the dashboard — the user sees their active session briefly disappear or go gray, suggesting a disconnection that didn't actually happen.

The underlying need: **the UI should reflect the user's perceived reality of session liveness, not the transient internal state of the event pipeline.**

## Dimensions

| Axis | Current state | Notes |
|------|--------------|-------|
| **Latency of real idle detection** | ~2s (one polling cycle) | Making idle transitions slower delays showing genuinely ended sessions |
| **False idle suppression** | None for individual projects | Only fully-empty snapshots are stabilized (2 consecutive empties) |
| **Complexity budget** | Low-moderate | This is a UX polish fix, not a feature. Should not add significant architectural weight |
| **Integration surface** | Rust reducer + Swift SessionStateManager | Two languages, two processes, one JSON file boundary |
| **Fix location** | Could be Rust-side, Swift-side, or both | Each has different tradeoffs (see solution map) |
| **State machine correctness** | The reducer is correct — SessionEnd *should* delete the session | The bug is in how the UI interprets transient state, not in the state itself |

## Success criteria

### Must
- Eliminate visible idle flicker when a session transiently ends and restarts (e.g., context compression restart, hook timing gap)
- Preserve correct idle display when a session genuinely ends (user exits Claude Code)
- Not break existing tests (`swift test`, `cargo test`)
- Not add perceptible latency (>4s) to showing a genuinely ended session as idle

### Should
- Keep the fix localized (ideally one file, max two)
- Work for both single-session and multi-session projects
- Be testable with unit tests (not just manual observation)
- Degrade gracefully — if the stabilization logic has a bug, the worst case is showing idle briefly (current behavior), not hiding a real idle state forever

### Nice
- Reuse existing patterns in the codebase (the empty-snapshot stabilization is a natural template)
- Add diagnostic logging so we can observe stabilization decisions in DebugLog
- Handle the project-identity-drift scenario (tool events resolving to a different project path)

## Assumptions

1. **SessionEnd fires when Claude Code truly exits** — not during context compression or reconnection. Status: **unconfirmed** — need to verify whether Claude Code fires SessionEnd during internal restarts. If it does, the gap between SessionEnd and SessionStart is the primary trigger. If it doesn't, the root cause is elsewhere.

2. **The 2-second polling interval is the observation window** — the flicker is visible because Swift polls every 2s and catches the snapshot in a transient state. Status: **confirmed** from AppState.swift line 265 (`withTimeInterval: 2.0`).

3. **The idle flash lasts exactly one polling cycle (~2s)** — not longer. Status: **unconfirmed** — could be 1 cycle or 2 depending on timing. Need user confirmation.

4. **Project identity drift (cause #2 from diagnosis) is a separate, less frequent issue** — the primary cause is the SessionEnd → gap → SessionStart sequence. Status: **unconfirmed** — both causes could be contributing.

## Constraints

- **Rust ↔ Swift boundary is a JSON file** — no in-process communication, no callbacks. Any Rust-side fix must be expressible in the snapshot format. Any Swift-side fix must work from snapshot polling alone.
- **hud-hook is a separate binary** — it holds flock during writes, but Swift reads are not coordinated with write timing.
- **No new IPC channels** — adding WebSocket/pipe between Rust and Swift would be a major architectural change, out of scope.
- **Backward compatibility** — the snapshot format is consumed by both Swift and the transparent-ui-server. Changes to the format must be additive.
