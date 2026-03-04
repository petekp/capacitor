# Analysis: Idle State Stabilization

## Tradeoff Matrix

| Criterion | 1a: Per-Project Counter | 1b: Hysteresis | 2a: Tombstone | 2b: Soft Delete | 3a: Suppress SessionEnd | 3b: Deferred Delete | 4a: state_age_hint | Hybrid (1b+timestamp) | Laziest |
|-----------|------------------------|----------------|---------------|-----------------|------------------------|--------------------|--------------------|----------------------|---------|
| **MUST: No visible idle flicker** | Yes (2-cycle hold) | Yes (asymmetric hold) | Yes (session persists) | Yes (grace period) | Yes (session persists) | Yes (deferred delete) | Yes (age-based hold) | Yes (timestamp hold) | Yes (1-cycle hold) |
| **MUST: Show genuine idle** | Yes, after 4s | Yes, after 4-6s | Yes, after TTL (10s) | Yes, after grace | Yes, after cleanup | Depends on next event | Yes, after age threshold | Yes, after threshold | Yes, after 2s |
| **MUST: Don't break tests** | Yes (Swift-only) | Yes (Swift-only) | Needs new tests | Needs new tests | Needs new tests | Needs new tests | Needs new tests | Both sides need tests | Yes (Swift-only) |
| **MUST: <4s genuine idle delay** | Yes (4s) | Borderline (4-6s) | No (10s typical) | Configurable | Configurable | Unpredictable | Configurable | Configurable | Yes (2s) |
| **SHOULD: Localized change** | 1 file (Swift) | 1 file (Swift) | 2+ files (Rust + bindings) | 3+ files | 1 file (Rust) | 1 file (Rust) | 2 files (Rust + Swift) | 2 files (Rust + Swift) | 1 file (Swift) |
| **SHOULD: Works for all consumers** | No (Swift only) | No (Swift only) | Yes (in snapshot) | Yes (in snapshot) | Yes (in snapshot) | Yes (in snapshot) | Yes (in snapshot) | Partial (timestamp in snapshot, logic in Swift) | No (Swift only) |
| **SHOULD: Testable** | Yes (mock snapshots) | Yes (mock snapshots) | Yes (Rust unit tests) | Yes (Rust unit tests) | Yes (Rust unit tests) | Hard (timing-dependent) | Yes (both sides) | Yes (both sides) | Yes (trivial) |
| **SHOULD: Degrades gracefully** | Yes (worst: shows idle briefly) | Yes (worst: shows idle briefly) | No (tombstone leak risk) | No (soft-delete leak risk) | No (Ready lie persists) | No (stale sessions linger) | Yes (worst: shows idle briefly) | Yes (worst: shows idle briefly) | Yes (worst: shows idle briefly) |
| **NICE: Reuses existing pattern** | Yes (`consecutiveEmptySnapshotCount`) | Extends existing pattern | New concept | New concept | Reuses existing Upsert | New concept | New concept | Combines existing + new | Simplifies existing pattern |
| **NICE: Diagnostic logging** | Easy to add | Easy to add | Moderate | Complex | Moderate | Complex | Easy (field in snapshot) | Easy | Trivial |
| **NICE: Handles identity drift** | Partially (holds any idle) | Yes (holds any idle) | No (only SessionEnd) | No (only SessionEnd) | No (only SessionEnd) | No (only SessionEnd) | Partially | Partially | Partially (holds any idle) |

## Eliminated

- **2a: Session Tombstone**: Eliminated on MUST criteria. The natural TTL for tombstones (10s to be safe) exceeds the 4s maximum genuine-idle delay. A shorter TTL risks the flicker returning. Also requires `SessionState::Ended` variant → UniFFI binding regeneration → Swift handling, which is disproportionate complexity.

- **2b: Soft Delete with Grace Period**: Eliminated on complexity. Requires coordinated changes across 3+ files in 2 languages, new fields in both `SessionSummary` and `ProjectSummary`, and cleanup logic. Overkill for the observed symptom.

- **3a: Suppress SessionEnd**: Eliminated on semantic correctness. Showing a "Ready" state for a genuinely ended session is actively misleading. The gotcha doc already warns about the Idle/Ready distinction. Introducing a state where Ready means "actually ended" adds confusion.

- **3b: Deferred Delete**: Eliminated on architectural mismatch. hud-hook and capacitor-core are invoked on-demand (not daemons), so pending deletions only execute when the next event arrives. If no events arrive (session truly ended, user walked away), the session lingers indefinitely. This is a fundamental flaw for a CLI-invoked architecture.

- **4a: state_age_hint alone**: Eliminated as standalone — the computation `state_age_seconds + time_since_snapshot` adds complexity that a simple counter avoids. But the concept of enriching the snapshot with timing data has merit as part of the hybrid.

## Finalists

1. **Laziest (1-cycle hold)** — from Paradigm 1. Selected because: minimal code (~5 lines), fixes the most common case, 2s delay is imperceptible for a glanceable dashboard, and degrades gracefully. The question is whether 1 cycle is enough.

2. **1b: Hysteresis** — from Paradigm 1. Selected because: handles edge cases better than the laziest fix (e.g., idle flash lasting 2 polling cycles), models the directional asymmetry correctly (slow to idle, instant to active), and follows established industry patterns (Datadog recovery thresholds, Grafana Pending/Recovering).

3. **Hybrid (1b + Rust timestamp)** — from Paradigm 4. Selected because: if we want to future-proof for other consumers, adding `last_session_ended_at` to `ProjectSummary` gives precise timing data. But this requires Rust changes and is only worth it if the transparent-ui-server needs the same fix.

## Key differentiator

**Does the idle flash ever last more than one polling cycle (>2 seconds)?**

- If it's always exactly 1 cycle: the Laziest fix is sufficient.
- If it sometimes lasts 2+ cycles: Hysteresis (1b) is needed.
- If other consumers (transparent-ui-server) also show the flicker: the Hybrid is needed.

Since we can't easily measure this without instrumentation, and the difference between Laziest and Hysteresis is ~35 lines of code, **Hysteresis is the safer bet** — it handles both 1-cycle and multi-cycle flashes, and the extra code is minimal.

## Open risks

1. **Root cause uncertainty**: We haven't confirmed whether the idle flash is caused by SessionEnd or project identity drift. Both Laziest and Hysteresis fix both causes (they hold any active→idle transition), but if identity drift is the real cause, we should also investigate pinning project identity after first resolution.

2. **Transparent-ui-server**: The browser UI reads the same snapshot. If it also shows idle flicker, a Swift-only fix doesn't help. But the browser UI is optional/diagnostic, so this is NICE, not MUST.

3. **Multi-session projects**: If a project has 2 sessions and one ends, the project stays active (the remaining session holds it). The idle flash only occurs when the LAST session ends. The stabilization must not interfere with this correct behavior (i.e., only stabilize transitions FROM active TO idle, not any state change).
