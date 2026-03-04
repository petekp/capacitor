# Solution Map: Idle State Stabilization

## Paradigm 1: Presentation-Layer Stabilization (Swift-side)
**Core bet:** The data layer (Rust reducer) is correct — the problem is that the UI reacts too eagerly to transient state. Smooth the rendering, not the data.

This mirrors game engine buffered interpolation and Alertmanager notification batching: the authoritative state is accurate, but the consumer adds a stabilization window before reflecting changes to the user.

### Approach 1a: Per-Project Idle Hold Counter (Swift)

- **How it works:** In `SessionStateManager`, after `mergeRuntimeProjectStates()` produces the merged map, add per-project stabilization. If a project was previously in an active state (Working/Ready/Compacting/Waiting) and the new snapshot shows it as Idle, increment a `consecutiveIdleCount[projectPath]` counter. Only commit the idle transition after N consecutive idle snapshots (e.g., N=2, meaning 4 seconds at 2s polling). Reset the counter when any non-idle state arrives.
- **Gains:** Mirrors the existing `stabilizeEmptyRuntimeSnapshotIfNeeded` pattern. Localized to one file. No Rust changes. No snapshot format changes. Easy to test.
- **Gives up:** Delays showing genuinely ended sessions by 2-4 seconds. All stabilization logic lives in Swift, invisible to the transparent-ui-server and other consumers.
- **Shines when:** The primary cause is a brief SessionEnd→SessionStart gap (1-2 polling cycles). The simplest fix for the most common case.
- **Risks:** If the idle flash lasts longer than the hold window (e.g., 3+ polling cycles), stabilization fails and the flicker still appears. Doesn't fix the transparent-ui-server (browser UI) since it reads the same snapshot directly.
- **Complexity:** Simple (~30 lines of Swift)

### Approach 1b: Hysteresis with Asymmetric Thresholds (Swift)

- **How it works:** Instead of a simple counter, use Datadog-style hysteresis. Entering idle requires N consecutive idle snapshots (entry threshold = 2-3). But once idle, returning to active is immediate (exit threshold = 1). This is directional: slow to go idle, instant to come back.
- **Gains:** More robust than a simple counter — explicitly models the asymmetry between "going idle" (should be conservative) and "becoming active" (should be instant). Same locality benefits as 1a.
- **Gives up:** Slightly more complex than 1a. Same blind spot for other snapshot consumers.
- **Shines when:** There are multiple transition patterns to handle (not just SessionEnd gaps, but also project identity drift causing momentary orphaning).
- **Risks:** The asymmetry could hide real idle transitions for too long if the threshold is set too high. Hysteresis is simple to get right but slightly harder to reason about in edge cases.
- **Complexity:** Simple (~40 lines of Swift)

---

## Paradigm 2: Data-Layer Tombstoning (Rust-side)
**Core bet:** The root cause is that `SessionEnd` is too aggressive — deleting a session immediately leaves no trace. The reducer should retain ended sessions temporarily so downstream consumers see a graceful transition.

This mirrors SWIM/Lifeguard's multi-phase suspicion: instead of binary alive/dead, maintain an intermediate "suspected" state (or in this case, "recently ended") that gives other events time to arrive.

### Approach 2a: Session Tombstone with TTL (Rust)

- **How it works:** Instead of `sessions.remove(session_id)` on `SessionEnd`, transition the session to a new state (e.g., `SessionState::Ended` or reuse `Ready` with `last_event: "session_end"`). Set a `tombstone_expires_at` timestamp (e.g., now + 10 seconds). In `recompute_projects()`, include tombstoned sessions in the project's session list (they contribute a Ready/Idle state rather than disappearing). A cleanup pass removes expired tombstones on each `apply_hook_event()` call.
- **Gains:** Fixes the problem at the source. All consumers (Swift app, transparent-ui-server, future consumers) benefit automatically. No polling-dependent logic. The session's existence in the snapshot means the project never drops to zero sessions during the tombstone window.
- **Gives up:** Adds a new concept (tombstoning) to the reducer's state model. Requires adding a field to `SessionSummary` (the `tombstone_expires_at` or similar). Changes the snapshot format (additive — new field, not breaking). More Rust code to maintain. Cleanup logic adds some complexity.
- **Shines when:** Multiple consumers read the snapshot and all need stabilization. When the idle flash is caused by the session literally not existing, rather than by the project having an idle state.
- **Risks:** Tombstone cleanup timing is tricky. If TTL is too short, still flickers. If too long, ended sessions linger visually. The `Ready` state with `last_event: "session_end"` is semantically confusing. Adding `SessionState::Ended` requires UniFFI binding regeneration and Swift-side handling.
- **Complexity:** Moderate (~60 lines of Rust + binding regen + Swift-side handling)

### Approach 2b: Soft Delete with Grace Period (Rust)

- **How it works:** On `SessionEnd`, instead of deleting, mark the session with `ended_at: now()` and keep it in the sessions map. In `recompute_projects()`, treat sessions with `ended_at` set as NOT contributing to project state (so the project correctly shows idle if all sessions have ended). BUT: add a separate `recently_had_session` flag or `last_session_ended_at` to `ProjectSummary`. Swift-side (or any consumer) checks: if the project is idle AND `last_session_ended_at` is within the grace period, hold previous visual state.
- **Gains:** Clean separation: Rust accurately tracks when sessions ended, consumers decide how to present it. The `last_session_ended_at` field in the snapshot gives consumers the information to make stabilization decisions without Rust imposing a policy.
- **Gives up:** More complex than tombstoning because it requires both Rust and Swift changes. Adds fields to both `SessionSummary` and `ProjectSummary`. Consumers must opt into using the new field.
- **Shines when:** You want the data layer to be descriptive (not prescriptive) and let each consumer choose its stabilization policy.
- **Risks:** Requires coordinated changes across Rust and Swift. The soft-deleted sessions need eventual cleanup (same issue as tombstones). More fields in the snapshot means more surface area for bugs.
- **Complexity:** Moderate-complex (~80 lines across Rust and Swift + binding regen)

---

## Paradigm 3: Pipeline-Level Fix (Prevent the Transient State)
**Core bet:** The real fix is to prevent the problematic state from ever appearing in the snapshot. If SessionEnd never produces a zero-session project, there's nothing to stabilize.

This mirrors Raft's approach: don't let the system enter the problematic state in the first place, rather than detecting and recovering from it.

### Approach 3a: Suppress SessionEnd in the Reducer (Rust)

- **How it works:** In `reduce_session()`, instead of `SessionEnd => SessionUpdate::Delete`, transition to `SessionUpdate::Upsert(upsert_session(current, event, SessionState::Ready, Some("session_ended")))`. The session stays in the map with state Ready and `last_event: "session_end"`. Add a separate cleanup mechanism: sessions with `last_event: "session_end"` that haven't received a new event within N seconds are removed during the next `apply_hook_event()` call.
- **Gains:** The simplest conceptual fix — session never disappears, so project never goes idle unexpectedly. No new state enum variants. No snapshot format changes (just different values). Handles all consumers automatically.
- **Gives up:** `Ready` with `last_event: "session_end"` is semantically misleading — the session isn't really "ready." Cleanup logic needed (similar complexity to tombstoning). A session that truly ended will show as Ready for the cleanup duration, which may confuse users if they're looking at session details.
- **Shines when:** You want zero changes to the snapshot schema and the simplest possible Rust change.
- **Risks:** The "session is Ready but actually ended" state is a semantic lie. If the project card shows "Ready" for a genuinely ended session for N seconds, that's arguably worse than a brief idle flash. The cleanup timing problem is the same as tombstoning.
- **Complexity:** Simple-moderate (~40 lines of Rust)

### Approach 3b: Batch SessionEnd with Deferred Deletion (Rust)

- **How it works:** Instead of processing `SessionEnd` immediately, queue it. Add a `pending_deletions: HashMap<String, DateTime>` to `ReducerState`. On `SessionEnd`, insert `(session_id, now + grace_period)`. On each subsequent `apply_hook_event()`, check pending deletions — if any have expired, execute the delete. If a new event arrives for a pending-deletion session, cancel the deletion.
- **Gains:** The session stays alive during the grace period. If a `SessionStart` arrives for the same session (or a new session in the same project), the deletion is preempted. Genuinely ended sessions are cleaned up after the grace period.
- **Gives up:** Adds internal state (`pending_deletions`) that doesn't appear in the snapshot but affects behavior. Deletions only execute when a new event triggers `apply_hook_event()`, so if no new events arrive, the deletion is deferred indefinitely until the next event. This is a real problem — a genuinely ended session could linger forever if no other hook events fire.
- **Shines when:** Sessions frequently end and restart quickly (e.g., context compression). The grace period absorbs the gap.
- **Risks:** The "deletion only on next event" timing issue is a significant design flaw. No events = no cleanup. Could add a separate timer, but hud-hook is a CLI binary (no long-running process), so timers aren't feasible. The Rust core is also invoked on-demand, not as a daemon.
- **Complexity:** Moderate (~50 lines of Rust, but the timing issue is architecturally problematic)

---

## Paradigm 4: Observability-Enhanced Detection (Hybrid)
**Core bet:** The problem isn't just about stabilization — it's about having enough information to make the right decision. Enrich the snapshot with metadata that lets consumers distinguish "truly idle" from "transiently idle."

### Approach 4a: Add `state_age_hint` to ProjectSummary (Rust + Swift)

- **How it works:** In `recompute_projects()`, when a project's state is Idle, compute how long ago it last had an active session (from the `state_changed_at` field). Add this as a `state_age_seconds: u64` field to `ProjectSummary`. On the Swift side, if `state == Idle && state_age_seconds < threshold`, hold the previous visual state.
- **Gains:** Purely additive snapshot change. Swift makes stabilization decisions based on concrete timing data rather than counting polling cycles. Works for all consumers. No semantic lies about session state.
- **Gives up:** Requires Rust and Swift changes. The `state_age_seconds` is approximate (computed at snapshot generation time, stale by the time Swift reads it). Adds a field to `ProjectSummary`.
- **Shines when:** You want the data layer to provide information, not impose policy, and the consumer uses real timestamps rather than polling counters.
- **Risks:** The staleness of `state_age_seconds` depends on how frequently snapshots are generated. If events stop arriving, the age value in the snapshot is frozen. But this is actually fine — Swift can compute `actual_age = state_age_seconds + time_since_snapshot_generated_at` for accurate timing.
- **Complexity:** Moderate (~40 lines across Rust and Swift)

---

## Non-obvious options

### Reframing: Is the problem actually SessionEnd?

A closer look at the data suggests the problem might not be SessionEnd at all. Consider:
- Claude Code's `SessionEnd` hook fires only when the session genuinely exits
- Context compression fires `PreCompact` (which transitions to `Compacting`), not `SessionEnd`
- The idle flash might actually be caused by **project identity drift** — a tool event with a `file_path` that resolves to a different project boundary, temporarily "moving" the session to a different project bucket

If this is the real cause, none of the SessionEnd-focused fixes help. The correct fix would be in `derive_project_identity()` — either pinning the project path after the first resolution, or requiring multiple consistent resolutions before allowing a project path change.

### Hybrid: Swift-side hold + Rust-side timestamp enrichment

Combine Approach 1b (hysteresis in Swift) with a lightweight Rust change: add `last_session_ended_at: Option<String>` to `ProjectSummary`. Swift uses this timestamp for precise stabilization decisions rather than counting polling cycles. The Rust change is small (set the field in `recompute_projects()` when a project drops to zero sessions), and Swift gets accurate timing without guessing.

### The laziest possible fix

Add a single check in `SessionStateManager.applyRuntimeProjectStates()`:
```swift
// If project was active and is now idle, skip this one update
if previousState.isActive && newState == .idle {
    // Hold previous state for exactly one polling cycle
    continue
}
```
This is ~5 lines, fixes the most common case (1-cycle idle flash), and has minimal risk. It delays all idle transitions by exactly one polling cycle (2 seconds). The tradeoff: genuinely ended sessions take 2 extra seconds to show as idle. For a glanceable dashboard, this is likely imperceptible.

## Eliminated early

- **WebSocket/pipe IPC between Rust and Swift**: Would allow push-based updates (no polling gap), but is a major architectural change far out of scope for this issue.
- **Heartbeat from hud-hook**: hud-hook is a CLI binary invoked per-event, not a daemon. Can't maintain heartbeats.
- **Swift-side extrapolation (game engine style)**: Predicting session state from velocity of change is over-engineered for this domain. Sessions are discrete states, not continuous values.
