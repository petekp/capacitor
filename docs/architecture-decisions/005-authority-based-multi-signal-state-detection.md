# Decision Guide: Authority-Based Multi-Signal State Detection

> **ADR-005** | Decided 2026-03-29 | Horizon: 18+ months
> Method: `decision-pressure-loop` | Run: `.relay/method-runs/state-detection-decision/`

## ADR Summary

**Decision:** Capacitor's state detection system adopts an authority-based multi-signal architecture where each signal source answers a different question with explicit authority. Hooks remain authoritative for nuanced session state. Transcripts become the canonical backfill/cold-start/existence path. Shell CWD stays routing-only. The runtime snapshot grows provenance fields.

**Status:** Decided. Three binding conditions must be met before the architecture is considered complete.

**Supersedes:** The implicit "hooks are the only live-state producer" architecture that currently exists.

## Current-State Snapshot (as of 2026-03-29)

| Component | Current Role | Key Files |
|-----------|-------------|-----------|
| Hook lifecycle callbacks | Only live-state producer for `/runtime/snapshot` | `claude_hooks.rs` (18 events, 14 managed), `handle.rs`, `reduce/mod.rs` |
| Transcript scanning | Fragmented metadata/discovery sidecar | `runtime_projects.rs`, `runtime_stats.rs`, `ProjectCreationCoordinator.swift`, `DelegationLoopManager.swift` |
| Shell CWD | Routing and terminal attribution | `cwd.rs`, `reduce/mod.rs:177-221` |
| Setup/gating | Hard-blocks app on hook install | `runtime/setup/`, `App.swift:269-323`, `SetupReadinessCoordinator.swift` |
| Runtime service | Authenticated local HTTP boundary | `serve.rs`, port 7474, bearer token auth |
| Hook health | Freshness-based monitor | `lib.rs:888-956`, `HookHealthStatus` enum |

**Critical finding:** The "transcript polling as independent fallback" mental model was incorrect. Transcript scanning powers metadata only. The reducer snapshot — and thus all project card state — comes exclusively from hook events and shell signals.

**Contract drift:** Capacitor hardcodes 18 hook events; Anthropic docs describe 25. Missing: `TaskCreated`, `StopFailure`, `CwdChanged`, `FileChanged`, `PostCompact`, `Elicitation`, `ElicitationResult`.

## Chosen Direction

### Authority Matrix (the core of the architecture)

| Question | Primary Authority | Degraded Fallback | Never Blocks? |
|----------|-------------------|-------------------|---------------|
| Nuanced session state (waiting, working, compacting, idle) | Hooks via reducer | Coarse "active/inactive" from transcript activity | Yes — degrades to coarse, never blocks |
| Session existence and recency | Transcripts + hooks (either sufficient) | Filesystem mtime scanning | Yes |
| Project/terminal routing | Shell CWD | None (routing-only, non-blocking) | Yes |
| State recovery after restart | Persisted snapshot + evidence replay | Transcript cold-start reconstruction | Yes |

### Binding Conditions

These are prerequisites, not nice-to-haves:

1. **Evidence provenance crosses the FFI boundary.** `AppSnapshot`, `ProjectSummary`, and `SessionSummary` grow fields for: which signal produced the current state, when, and whether the state is primary-authority or degraded-fallback. Swift can render accordingly.

2. **Evidence replay on restart.** The runtime service persists raw evidence (hook events, transcript observations), not just fused snapshot conclusions. On restart, evidence is replayed to reconstruct state rather than loading a stale frozen snapshot.

3. **Authority matrix is a testable contract.** The authority table above is encoded in the codebase as a contract test. The reducer enforces: for nuanced-state questions, hooks win when available. For existence questions, transcripts are co-equal. For routing, only shell CWD contributes. Generic "confidence scoring" is explicitly prohibited.

### What does NOT change

- `/runtime/snapshot` remains the canonical Swift read boundary
- `hud-hook serve` remains the runtime service
- Swift 2-second polling cadence and projection/stabilization logic
- Shell CWD as the routing signal
- Hook auto-repair (for the events that remain managed)
- `~/.claude/` read-only, `~/.capacitor/` write namespace

## Interface or Ownership Changes

### New Rust-side abstractions

| Abstraction | Purpose | Replaces |
|-------------|---------|----------|
| Transcript observation service | Single owner of all transcript scanning, watching, and parsing | Fragmented consumers across `runtime_projects.rs`, `runtime_stats.rs`, `ProjectCreationCoordinator.swift`, `DelegationLoopManager.swift` |
| Evidence provenance fields on snapshot types | Tells Swift which signal produced each state claim | Implicit "trust the snapshot" convention |
| Authority enforcement in reducer | Encodes the authority matrix as logic, not convention | Current reducer that treats all ingest commands as equal |
| Evidence persistence layer | Raw evidence log alongside snapshot persistence | Current snapshot-only persistence in `storage/mod.rs` |

### Changes to existing contracts

| Contract | Change | Impact |
|----------|--------|--------|
| `AppSnapshot` / `SessionSummary` (UniFFI) | Add provenance, degraded-reason, signal-source fields | Swift must read and render these |
| `SetupReadinessCoordinator` | Startup gates on runtime service health, NOT hook install | WelcomeView no longer blocks on hooks |
| `HookDiagnosticReport` | Becomes one signal-health report among several, not the system diagnostic | Setup card becomes informational, not blocking |
| Hook contract (`claude_hooks.rs`) | Maintained but not sole point of failure | Can tolerate drift without app breakage |

## Migration Guidance

### Phase 1: Unblock (immediate, low risk)
1. **Remove hook-gating from startup.** `validateHookSetup()` in `App.swift` should gate on runtime service health, not hook install status. This is the single highest-value fix.
2. **Fix `isFirstRun` misclassification.** Use a persisted setup marker instead of `HookHealthStatus::Unknown`.
3. **Split `HookStatus::NotInstalled` into granular states.** At minimum: `NotInstalled`, `PartiallyConfigured`, `SettingsUnreadable`.
4. **Remove dead code.** `HookHealthStatus::Unreadable` (no producer), `tmuxPath` (unused), unused `SetupStatus` fields.

### Phase 2: Consolidate transcripts (moderate risk)
5. **Build transcript observation service in Rust.** Single abstraction that owns transcript scanning, mtime watching, and incremental parsing. Replace the 4+ fragmented consumers.
6. **Wire transcript observations into the reducer.** Initially as session-existence evidence only (not nuanced state). The authority matrix says transcripts answer "does this session exist?" and "is it recently active?"
7. **Add cold-start reconstruction.** On runtime service startup with no snapshot, reconstruct session existence from transcript files.

### Phase 3: Provenance and authority (higher risk, completes the architecture)
8. **Add provenance fields to snapshot types.** `SessionSummary` gains: `state_source: SignalSource`, `state_confidence: Confidence`, `degraded_reason: Option<String>`.
9. **Implement authority enforcement in reducer.** For nuanced state questions, hooks always win when fresh. Transcript activity only produces coarse state. Shell CWD only produces routing.
10. **Add evidence persistence.** Raw evidence log alongside snapshot persistence. Enable replay on restart.
11. **Write authority matrix contract tests.** Encode the authority table as deterministic tests. Verify: hook-produced state is never overridden by transcript-derived state for nuanced questions.

### Phase 4: Extend and harden
12. **Update hook contract to track new Anthropic events** (as needed, incrementally).
13. **Consider Claude-native `CwdChanged` / `FileChanged`** once the authority matrix is stable.
14. **Add signal-health telemetry** — each source reports its own health status.
15. **Do NOT add terminal signals or generic confidence scoring in this pass.**

## Risk Watchpoints

| Risk | Mitigation | Monitor |
|------|------------|---------|
| Hook API drift (18 vs 25 events, growing) | Authority matrix means drift degrades to coarse, not breaks | Track Anthropic hook docs each release; `--evolve` checks |
| Transcript schema undocumented | Transcript service uses defensive parsing with version detection | Test against transcript samples from multiple Claude versions |
| Transcript persistence disabled | System must function with hooks-only; transcript path is additive | Track user configs for `cleanupPeriodDays=0` prevalence |
| Fusion becomes heuristic pile | Authority matrix enforced as contract test, not convention | Require authority-matrix tests to pass before claiming Phase 3 complete |
| Double-buffered degradation (Rust freshness + Swift hysteresis) | Provenance fields let Swift know the basis; no independent Swift guessing | Review Swift stabilization logic during Phase 3 |
| Evidence replay complexity | Start with simple ordered replay; defer sophisticated conflict resolution | Measure replay correctness with snapshot-comparison tests |

## Verification Questions for Implementers

Before claiming each phase is complete, answer:

**Phase 1:**
- [ ] Can the app launch and show project cards when hooks are completely absent from `settings.json`?
- [ ] Does a returning user with no hook history see the correct UI (not onboarding copy)?
- [ ] Does `HookStatus` now distinguish "not installed" from "partially configured" from "settings corrupt"?

**Phase 2:**
- [ ] Is there exactly ONE Rust-owned abstraction that handles all transcript scanning?
- [ ] Can the system discover a session's existence from transcripts alone (no hooks)?
- [ ] Does cold-start reconstruction produce valid session entries in the snapshot?

**Phase 3:**
- [ ] Does `SessionSummary` carry provenance fields across the FFI boundary?
- [ ] Can Swift distinguish "hooks say working" from "transcript says active"?
- [ ] Does the authority matrix contract test exist and pass?
- [ ] Does evidence replay on restart produce the same snapshot as continuous operation?

## Reopen Conditions

Reopen this ADR if:

1. **Claude Code ships a native state API** — re-evaluate whether it obsoletes hooks, transcripts, or both
2. **Hook API contract breaks twice in 6 months** — signals Anthropic doesn't prioritize hook stability
3. **Transcript format breaks** — rethink the backfill/recovery path
4. **Transcript latency is empirically fast (<500ms)** — consider elevating transcripts to co-equal state source
5. **Authority matrix proves too expensive** — fall back to Option 1 (hardened hooks + transcript reconstruction)
6. **MCP server adds session-state queries** — re-evaluate the authority matrix
7. **Competitor demonstrates strictly better approach** — learn and adapt

---

*Artifact chain: `decision-brief.md` → `current-system-map.md` → `decision-options.md` → `decision-scorecard.md` → `decision-steer.md` → `pressure-report.md` → `decision-choice.md` → `decision-guide.md`*
