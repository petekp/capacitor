# Step 6 Execution Guide — Tracer Bullet

> **Status:** Ready to execute
> **Branch:** `pkp/method-runner-spec`
> **Created:** 2026-03-22
> **Scope:** Slices 1–6 happy path, then 8-worker validation blitz

---

## Overview

Step 6 proves the method runner works end-to-end by building a **tracer bullet**: one serial phase, one dispatch step, one implicit primary worker, no retries, no gates, no parallelism. Fake adapters stand in for compose-prompt.sh and codex exec (adapter gate waived).

**Acceptance criterion:**
```bash
cargo run -p capacitor-core --bin method-runner -- run \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root /tmp/method-run-smoke
```
Produces a complete `.method/` tree and `state.json` can be rebuilt from `events.ndjson`.

---

## Dependency Graph

```
Phase A (pre-flight)
  └── Phase B (Slice 1: Definition)
        └── Phase C (Slice 2: State Machines + Events)
              ├── Phase D (Slice 3: Lock + Persistence)
              ├── Phase E (Slice 4: Output Resolver)
              └── Phase F (Slice 5: Handoff Parser)
                    └── Phase G (Slice 6: Executor + CLI)
                          └── Phase H (Self-validation)
                                └── Phase I (Commit)
                                      ├── J-1: Invariant Verification     ─┐
                                      ├── J-2: Interface Contracts         │
                                      ├── J-3: Constraints + Errors        │
                                      ├── J-4: Adversarial Fuzzing         ├─ ALL PARALLEL
                                      ├── J-5: Filesystem Robustness       │
                                      ├── J-6: State Machine Exhaustive    │
                                      ├── J-7: Integration Expansion       │
                                      └── J-8: Error/DX Audit             ─┘
                                            └── Phase K (Triage)
                                                  └── Phase L (P0/P1 Fixes)
                                                        └── Phase M (P2/P3 Fixes)
                                                              └── Phase N (Re-validation)
                                                                    └── Phase O (Closeout)
```

**Key parallelism opportunity:** Phases D, E, F can run in parallel after C completes. Phases J-1 through J-8 are **all independent** and should be dispatched as 8 parallel codex workers.

---

## Phase A: Pre-flight

**Goal:** Clean baseline before any implementation.

1. `cargo clippy -p capacitor-core -- -D warnings` → fix any warnings
2. `cargo fmt --check -p capacitor-core`
3. `cargo test -p capacitor-core` → all existing tests pass
4. `rm -rf handoffs/` (stale codex worker output)
5. Commit Step 5 scaffold:
   ```
   git add core/capacitor-core/src/method_runner/ \
           core/capacitor-core/src/bin/method_runner.rs \
           core/capacitor-core/tests/method_runner_contract.rs \
           core/capacitor-core/tests/method_runner/mod.rs \
           methods/fixtures/ methods/library/ \
           core/capacitor-core/Cargo.toml \
           core/capacitor-core/src/lib.rs \
           Cargo.lock
   ```
6. Verify clean: `cargo test -p capacitor-core`

---

## Phase B: Slice 1 — Definition Model + Normalizer

**Goal:** Parse YAML → resolve defaults → validate → write snapshot + step.json.

### Types to define (in `definition.rs`)

| Type | Purpose |
|------|---------|
| `RawMethodDefinition` | Direct serde_yaml target (all fields Optional where spec allows) |
| `NormalizedMethodDefinition` | Fully resolved, no optionals where defaults apply |
| `NormalizedPhase`, `NormalizedStep` | Inherited skills, template, max_attempts, completion_policy |
| `ActionKind` | `Dispatch`, `Interactive`, `Synthesis`, `PipelineExecute` |
| `NormalizationError` | `YamlParseError`, `InvalidSchemaVersion`, `MissingRequiredField`, `InvalidLocator`, `DuplicateId`, `UnresolvedReference` |

### Key behaviors

- Default cascade: `method.defaults` → phase-level → step-level (step wins)
- `pipeline-execute` parses but gets a `v1_blocked: true` flag (C9)
- Template comes only from explicit `step.template` or `phase.template` or `method.defaults.template` — never inferred (I11, C2)
- Locator validation: `from: phase.step.output` must reference a declared step output

### Tests (12 minimum)

See Task #2 for complete list. Key ones:
- All 3 YAML fixtures normalize without error
- Snapshot write + DefinitionLoader round-trip
- Default cascade verification
- Error cases: bad schema version, missing id, invalid locator, duplicate ids

---

## Phase C: Slice 2 — State Machines + Event Types

**Goal:** Typed status enums with enforced transitions, ~27 event kinds, in-memory projection.

### Status enum design

Each status type has a `transition_to(next) -> Result<Self, TransitionError>` method that enforces legal transitions per the spec's state machine diagrams.

### Event envelope

```rust
struct MethodEventEnvelope {
    seq: u64,                        // monotonic
    timestamp: String,               // ISO 8601
    run_id: String,
    kind: MethodEventKind,
    phase_id: Option<String>,
    step_id: Option<String>,
    attempt: Option<u32>,
    worker_id: Option<String>,
    payload: MethodEventPayload,     // typed per kind
}
```

### Projection

`project(events) -> MethodRunState` — applies events in order, enforcing legal transitions, building nested state tree.

### Tests (12 minimum)

See Task #3 for complete list. Key ones:
- Legal + illegal transitions for all 5 entity types
- Event serialization round-trip
- Projection determinism (same events → same state)

---

## Phase D: Slice 3 — Lock + Persistence

**Goal:** `run.lock` with stale detection, event appender with monotonic seq, atomic state.json writes, torn-tail recovery.

### Lock protocol

- JSON lock file: `{ pid, start_time, hostname, acquired_at }`
- 5-second timeout
- Stale detection: PID alive check + start_time comparison
- Guard type that auto-releases on drop

### Torn-tail recovery

Read events.ndjson, detect incomplete last line (not valid JSON), truncate, return valid events.

### Tests (14 minimum)

See Task #4 for complete list.

---

## Phase E: Slice 4 — Output Resolver

**Goal:** Locator parsing, binding policies, conservative availability.

### Locator grammar

- 3-segment: `phase.step.output`
- 4-segment: `phase.step.worker.output`
- Binding policies: `single`, `all`, `first-clean` (C4: definition order)

### Conservative availability (I7)

Output is NOT available until the producing step reaches a terminal state (completed or failed). No early reads.

### Tests (14 minimum)

See Task #5 for complete list.

---

## Phase F: Slice 5 — Handoff Parser

**Goal:** Parse canonical headings from markdown, transactional ingestion.

### Canonical headings (from BUILD_BOUNDARY.md)

```
### Files Changed
### Tests Run
### Verification
### Verdict          → CLEAN | ISSUES FOUND
### Completion Claim → COMPLETE | PARTIAL
### Issues Found
### Next Steps
```

### 8 edge cases (Amendment 10)

1. Missing heading → None + warning
2. Duplicate heading → first wins + warning
3. No headings at all → error
4. Empty section → Some("") + warning
5. Invalid verdict → Some(raw) + warning
6. Invalid completion claim → Some(raw) + warning
7. Non-UTF-8 → error
8. Extra headings → ignored + warning

### Transactional order (C6)

copy source → write parsed JSON → (caller emits events → projects state)

### Tests (13 minimum)

See Task #6 for complete list.

---

## Phase G: Slice 6 — Step Executor + CLI

**Goal:** Wire everything end-to-end. This is the tracer bullet proof.

### Fake adapters

| Adapter | Behavior |
|---------|----------|
| `FakePromptBuilder` | Writes minimal prompt-header.md + prompt.md |
| `FakeWorkerDispatcher` | Creates synthetic handoff with CLEAN/COMPLETE, exit 0 |

### RunExecutor lifecycle

1. Create `.method/` directory tree
2. Normalize → write snapshot → emit `DefinitionFrozen`
3. Emit `RunStarted`
4. For each phase: `PhaseStarted` → execute steps → `PhaseCompleted`
5. For each step: `StepStarted` → dispatch → ingest → bind → `StepCompleted`
6. Resolve method outputs
7. Emit `RunCompleted`
8. Write final state.json

### Required artifacts (complete list for minimal-dispatch)

```
.method/
├── definition.snapshot.yaml
├── events.ndjson
├── state.json
├── locks/                              (empty after clean run)
├── artifacts/
│   ├── handoffs/
│   │   └── bootstrap--dispatch--001--primary.md
│   └── outputs/
│       └── dispatch_summary.json
└── steps/
    └── bootstrap/
        └── dispatch/
            ├── step.json
            └── attempts/
                └── 001/
                    ├── attempt.json
                    ├── input-bindings.json
                    ├── output-bindings.json
                    ├── parsed-handoffs/
                    │   └── primary.json
                    └── relay/
                        └── workers/
                            └── primary/
                                ├── prompt-header.md
                                └── prompt.md
```

### Tests (16 minimum)

See Task #7 for complete list. The critical integration test mirrors the acceptance command.

---

## Phase H: Self-validation

Run acceptance command, verify .method/ tree, verify events, verify state, verify rebuild, verify normalize, verify pipeline-blocked.

---

## Phase I: Commit

Clean commit of all tracer bullet implementation.

---

## Phase J: Codex Worker Validation Blitz

**8 workers, ALL dispatched in parallel** after the tracer bullet commit.

| Worker | Focus | Test File | Target Tests |
|--------|-------|-----------|--------------|
| J-1 | Invariant verification (I1-I12) | `tests/method_runner/invariants.rs` | 12+ |
| J-2 | Interface contracts (IF1-IF9) | `tests/method_runner/interfaces.rs` | 20+ |
| J-3 | Constraints (C1-C10) + error taxonomy | `tests/method_runner/constraints.rs` | 15+ |
| J-4 | Adversarial YAML fuzzing | `tests/method_runner/adversarial.rs` | 20+ |
| J-5 | Filesystem robustness + concurrency | `tests/method_runner/robustness.rs` | 15+ |
| J-6 | State machine exhaustive transitions | `tests/method_runner/state_machines.rs` | 50+ |
| J-7 | End-to-end integration expansion | `tests/method_runner/integration.rs` | 10+ |
| J-8 | Error message quality + DX audit | `tests/method_runner/error_audit.rs` | 15+ |

**Total expected test additions from workers: ~157+**

### Worker dispatch notes

- Each worker gets a complete copy of the codebase (use git worktrees or separate checkouts)
- Each worker writes to a SEPARATE test file (no conflicts)
- Workers should run `cargo test` and `cargo clippy` to verify their tests compile
- Worker output should include: test results, any issues found (with severity/location/fix), and a summary
- All workers reference: `docs/method-runner-spec/execution-packet.md` (contract), `docs/method-runner-spec/amended-spec.md` (spec), and the implementation at `core/capacitor-core/src/method_runner/`

---

## Phase K-M: Triage & Fix

1. **K:** Collect all 8 worker outputs, categorize findings (P0-P4)
2. **L:** Dispatch fix workers for P0 (correctness) and P1 (security) issues — one worker per issue
3. **M:** Batch fix workers for P2 (robustness) and P3 (test gap) issues — 2-3 workers

---

## Phase N: Re-validation

Full test suite + acceptance command after all fixes applied. Target: 80+ total tests, zero failures, zero clippy warnings.

---

## Phase O: Closeout

Commit, write closeout summary, update hardened-sequence.md Step 6 status.

---

## Risk Mitigations

| Risk | Mitigation |
|------|------------|
| Scaffold types don't match spec YAML schema | Phase B explicitly maps every YAML field to a Rust type |
| State machine transitions underspecified | J-6 worker exhaustively tests every (from,to) pair |
| Event payload schemas drift from spec | J-2 worker verifies payloads match execution-packet |
| Path traversal in user-controlled ids | J-4 worker tests `../../` and null bytes in phase/step ids |
| Lock stale detection false positives | J-5 worker tests PID reuse + start_time verification |
| Handoff parser misses edge case | J-2 worker tests all 8 Amendment 10 edge cases |
| Torn-tail recovery corrupts data | J-5 worker tests with simulated crash scenarios |
| Error messages unhelpful for debugging | J-8 worker audits every error variant for actionability |

---

## Estimated Test Totals

| Source | Test Count |
|--------|-----------|
| Phase B (normalizer) | ~12 |
| Phase C (state machines + events) | ~12 |
| Phase D (lock + persistence) | ~14 |
| Phase E (output resolver) | ~14 |
| Phase F (handoff parser) | ~13 |
| Phase G (executor + CLI) | ~16 |
| J-1 (invariants) | ~12 |
| J-2 (interfaces) | ~20 |
| J-3 (constraints) | ~15 |
| J-4 (adversarial) | ~20 |
| J-5 (robustness) | ~15 |
| J-6 (state machines) | ~50 |
| J-7 (integration) | ~10 |
| J-8 (error audit) | ~15 |
| **Total** | **~238** |
