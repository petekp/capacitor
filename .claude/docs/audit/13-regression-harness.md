# Regression Harness Design (Model-Based + Concurrency + Chaos)

This document defines how we prevent “fix X breaks Y” regressions by turning the system’s invariants into **executable checks**.

It is designed to support:
- **Today’s system** (locks + `sessions.json` + `file-activity.json` + tombstones)
- **vNext (OptionB)** (per-session directories + `events.jsonl` + single-writer derived snapshot)

---

## Core idea

1. Define a small **reference model** (pure, deterministic) of session state.\n
2. Generate many scenarios (random + curated).\n
3. Verify that the implementation matches the model and that **invariants** always hold.\n
4. Stress the filesystem boundaries with concurrency and “crash in the middle” chaos.

---

## Invariants to enforce (must never regress)

### State resolution invariants

- **I1_ExactMatchOnlyForSessions**: session state queries are exact-match-only (no parent/child inheritance between project cards).\n
- **I2_LockOrPidVerificationGatesLiveness**: a “running” session must be gated by verified liveness (`kill(pid,0)` + `proc_started`).\n
- **I3_SessionEndIsTerminal**: once SessionEnd is observed, later events for that session_id must not resurrect state.\n
- **I4_ActiveStateStalenessRecovery**: Working/Waiting become Ready when stale and no liveness proof exists.\n
- **I5_ReadyStaleToIdleWithoutLiveness**: Ready becomes Idle after the configured threshold without liveness.\n

### Monorepo/activity invariants

- **I6_ActivityIsSecondary**: activity signals must never override a live session at an exact path.\n
- **I7_ActivityCanLightUpChildProjects**: a session at `/repo` editing `/repo/packages/a/...` can mark `/repo/packages/a` Working.\n

### Robustness invariants (side effects)

- **I8_NoCorruptionFromPartialWrites**: corrupted/partial files must not crash; system must self-heal (ignore + rebuild).\n
- **I9_ConcurrentWritersDoNotBreakParsing**:\n
  - today: concurrent state writers must not produce unreadable JSON\n
  - vNext: concurrent event appends must not interleave into invalid JSON objects\n
- **I10_ResetSafety**: deleting `~/.capacitor/` artifacts must be safe; app must recover to a usable baseline.

---

## Harness layers

### Layer A: Curated regression tests (“goldens”)

Purpose: encode known historical regressions as permanent tests.\n
Sources:
- Existing resolver tests in `core/hud-core/src/state/resolver.rs` (many already exist)\n
- Audit findings and fixed regressions in `.claude/docs/audit/*`

Examples (to encode as tests):
- Parent path must not show child session (exact-match-only)\n
- Stale Working without liveness becomes Ready\n
- Ready without liveness becomes Idle after 15 minutes\n
- “Late event after SessionEnd” must not resurrect state (vNext)

### Layer B: Model-based tests (property tests)

Purpose: cover edge cases that humans won’t think to write.\n
Technique:
- Generate random sequences of events across multiple sessions/projects.\n
- Apply the reference model.\n
- Compare model output to implementation output (or assert invariants directly).

Recommended structure:

```text
Scenario
  - projects: [P1, P2, ...]
  - sessions: [S1..Sn]
  - events: Vec<Event>  (shuffled / out-of-order to simulate async)
  - liveness: fn(pid, proc_started)->bool  (controllable)
```

Reference model (pure function):
- Inputs: ordered events + liveness oracle\n
- Output:\n
  - per-session derived state\n
  - per-project derived state\n
  - derived “why” trace for debugging

### Layer C: Concurrency tests (filesystem race stress)

Purpose: ensure our filesystem interaction patterns don’t lose updates or corrupt state under concurrent writers.

#### Today (baseline)

Targets:
- Cleanup vs hook writes to `sessions.json` (known clobber risk)\n
- Concurrent writes to `file-activity.json` (known non-atomic)

Expected outcome:\n
- Even if last-writer-wins causes lost updates, parsing must remain valid and the system must converge on the next event.\n
- No corrupted JSON should persist after the next successful write.\n

#### vNext (OptionB)

Targets:
- Concurrent appends to `sessions/{session_id}/events.jsonl`.\n

Expected outcome:\n
- No interleaved JSON objects (each line is either valid JSON object or ignorable).\n
- Reader ignores bad trailing partial line and continues.

### Layer D: Chaos tests (“crash mid-write”)

Purpose: prove recovery from mid-write failures.\n
Techniques:
- Write only half a JSON blob to a file, then “crash” (stop).\n
- Truncate last line of a JSONL file.\n
- Delete files while the app is reading (TOCTOU).\n

Expected outcome:\n
- Load returns empty/default or ignores bad tail.\n
- Derived state is rebuilt from remaining data.\n
- No panic/no crash, only degraded signal until next event.

---

## Where tests should live (implementation plan)

When we start implementing (later), the harness should be split by scope:

- **Rust unit + property tests**:\n
  - `core/hud-core/src/state/` (pure model + resolver invariants)\n
  - `core/hud-core/tests/` (integration tests with temp dirs)\n

- **hud-hook integration tests**:\n
  - Extend existing `tests/*.bats` patterns for hook event end-to-end\n
  - Add “late event after end” and “out-of-order async events” scenarios

- **Swift unit tests (optional)**:\n
  - ActiveProjectResolver priority/override behaviors (pure, fast)\n

---

## Reproducibility requirements

Any failing generated scenario must be reproducible:
- Print the RNG seed.\n
- Save the minimal event list and liveness oracle decisions.\n
- Emit a compact “why trace” showing which rule produced the final state.

---

## Practical stopping condition (what “good enough” means)

Before shipping vNext storage:
- All Layer A tests pass.\n
- Model-based tests run for a minimum budget (e.g., 10k scenarios) with no failures.\n
- Concurrency tests run in CI with repeat loops (e.g., 100 iterations) to catch flakes.\n
- Chaos tests cover partial tail corruption for JSONL and snapshot files.\n

---

## Next doc linkage

This harness enforces the invariants declared in:\n
[`audit/12-vNext-minimal-side-effects.md`](12-vNext-minimal-side-effects.md) and the canonical current map:\n
[`audit/00-current-system-map.md`](00-current-system-map.md).

