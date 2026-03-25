# Implementation Plan: Method Runner (Revised)

> Derived from `amended-spec.md` and `execution-packet.md`. Every slice references
> execution-packet obligations and carries test responsibilities.
>
> **Revision note:** Addresses 5 blocking gaps and 8 missing test cases identified
> in `plan-review.md` (Step 10, first pass). Changes: split old Slice 2 to fix
> lock/appender ordering, assigned artifact ownership to producing slices, removed
> orphan recovery forward reference from handoff parser, added `pipeline-execute`
> runtime blocking to step executor, expanded test matrices.

---

## Slice Order

The slices are ordered by dependency: each slice builds on the previous one's
types and contracts. No slice requires forward references to unbuilt slices.

### Slice 1: Definition Model + Normalizer

**What:** Parse YAML method definitions into a fully normalized in-memory model.
Resolve all inheritance (skills, template, max_attempts, completion_policy).
Validate output locators. Write `definition.snapshot.yaml`. Write `step.json` for
each step (static metadata snapshot). Support all four action types: `dispatch`,
`interactive`, `synthesis`, `pipeline-execute`.

**Execution-packet obligations:** IF5 (Definition Normalizer), I10 (Definition
Freeze — write side), I11 (Template Explicitness), C2 (No Template Inference),
C8 (Output Namespace Safety), C9 (`pipeline-execute` Parse-Only — normalization
side).

**Produces:** `definition.snapshot.yaml`, `steps/<phase>/<step>/step.json`.

**Layer:** Rust (`core/capacitor-core/`) — portable domain logic.

**Test obligations:**
- Inheritance resolution at each level (method → phase → step → dispatch → worker)
- Invalid YAML rejected with source location
- Schema version mismatch rejected with clear error
- Missing required fields (`method.id`, `method.version`, `method.title`,
  `step.action`) rejected with field name in error
- Unknown action type rejected (e.g., `action: deploy`)
- Invalid output locators caught during normalization
- `pipeline-execute` steps parsed and validated but flagged as v1-unimplemented
- `synthesis` steps parsed with required `synthesis.instructions` and
  `synthesis.output`
- Template precedence chain: dispatch.template > step.template >
  method.defaults.template > `implement`
- `definition.snapshot.yaml` is byte-identical across two normalizations of the
  same input
- `step.json` written for each step with correct static metadata

**Done when:** `cargo test` passes all normalizer tests. A real method YAML
(e.g., spec-hardening converted to YAML) normalizes without error. `step.json`
files are produced.

---

### Slice 2: State Machines + Event Types

**What:** Implement typed status enums and transition graphs for all five entities
(Run, Phase, Step, Attempt, Worker). Implement the event model with typed payloads
per event kind (all ~27 event kinds with required payload fields from the amended
spec — payload schemas are **locked** at this slice; Slice 12 adds telemetry
enrichment but does not change required fields). Implement the in-memory state
projection logic (state machine enforcement + projection from events). Implement
the shared `DefinitionLoader` that reads from `definition.snapshot.yaml` — all
runtime logic (execute, resume, replay) uses this loader, never the source YAML.

This slice defines types, transitions, projection logic, and the snapshot loader.
It does NOT implement lock-backed persistence — that comes in Slice 3.

**Execution-packet obligations:** IF6 (State Machine Enforcer), I8 (Legal
Transitions Only), I6 (Atomic Projection — logic only, persistence in Slice 3),
I10 (Definition Freeze — shared loader infrastructure).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 1 (needs `NormalizedDefinition` types and
`definition.snapshot.yaml`).

**Test obligations:**
- Every legal transition for each entity succeeds
- At least 3 illegal transitions per entity produce error events
- All ~27 event kinds have their required payload fields defined and validated
  at the type level (compile-time enforcement where possible, runtime validation
  for dynamic fields)
- In-memory projection: apply a sequence of events, verify resulting state matches
  expected
- Projection is deterministic: same events in same order produce identical state
- `DefinitionLoader` reads from `definition.snapshot.yaml`, not source YAML
- `DefinitionLoader` errors if snapshot is missing (forces Slice 1 to run first)

**Done when:** State machines enforce all transitions. Event types are complete
with locked payload schemas. In-memory projection works correctly.
`DefinitionLoader` reads from the frozen snapshot.

---

### Slice 3: Lock Manager + Event Persistence

**What:** Implement `run.lock` acquisition with timeout, release on scope exit,
stale-lock detection (PID + start-time verification), and recovery. Then implement
the lock-backed event appender: `seq` monotonicity, `events.ndjson` append,
`state.json` atomic write-then-rename projection, and torn-tail recovery.

These are combined because the event appender's core invariant (single writer
holding the lock) requires the lock manager to exist. They are the persistence
foundation for all subsequent slices.

**Execution-packet obligations:** IF8 (Lock Manager), IF9 (Event Appender),
I1 (Event Authority), I2 (Append-Only History), I6 (Atomic Projection —
persistence), I9 (Lock Exclusivity), C5 (Single Event Appender).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 2 (event types and projection logic).

**Test obligations:**
- **Lock Manager:**
  - Acquire and release succeeds
  - Concurrent acquisition: second process times out or blocks
  - Stale lock (dead PID): create lock with dead PID, verify recovery and
    re-acquisition
  - Stale lock (PID reuse): create lock with a live PID but mismatched
    `start_time`, verify the lock manager detects the mismatch and recovers
    (guards against PID reuse ghost-lock bugs)
  - Read-only operations work without the lock
  - Lock file contains correct JSON format (`pid`, `start_time`, `hostname`,
    `acquired_at`)
- **Event Appender:**
  - `seq` is strictly increasing with no gaps after any operation sequence
  - Torn-tail recovery: truncate last line of `events.ndjson`, rebuild, verify
    recovery and resume from last valid seq
  - Delete `state.json`, rebuild from events, diff is empty
  - Atomic projection: verify no partial `state.json` after simulated crash
  - Projection fires after each append (verify `state.json` is updated after
    every event write)

**Done when:** Lock protocol works in single-process and concurrent scenarios.
Event log + projection round-trips cleanly. Torn-tail recovery works. All
persistence is lock-backed.

---

### Slice 4: Output Resolver + Binding Policies

**What:** Implement output binding locator grammar (`phase.step.output` and
`phase.step.worker.output`). Implement resolution algorithm. Implement binding
policies (`single`, `all`, `first-clean` with definition-order). Implement
conservative output availability with `early_availability` opt-in. Write
`artifacts/outputs/<name>.json` registry entries on successful binding.

**Execution-packet obligations:** IF7 (Output Resolver), I7 (Conservative Output
Availability), I12 (Binding Is Routing), C1 (No Implicit Computation), C4
(`first-clean` Definition Order), C8 (Output Namespace Safety).

**Produces:** `artifacts/outputs/<name>.json`.

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 1 (output definitions), Slice 2 (step terminal status).

**Test obligations:**
- Parse valid locators (3-segment and 4-segment)
- Reject invalid locators (nonexistent phase/step/output)
- Reject unresolvable worker-qualified locators (valid step but nonexistent worker)
- `single` policy resolves to named worker's artifact
- `all` policy returns list of all worker artifacts
- `first-clean` iterates definition order, not insertion order
- `first-clean` after retries: highest completed attempt wins, not first attempt
- Availability blocking: non-terminal step → error
- `early_availability: true` bypasses availability check
- No binding code path reads artifact content — test that binding functions accept
  only metadata (path, verdict, completion claim), never file contents
- `artifacts/outputs/<name>.json` written with correct schema on successful bind

**Done when:** All three binding policies resolve correctly. Availability blocking
works. No computation in bindings (verified by tests + code review). Output
registry entries are written.

---

### Slice 5: Handoff Parser (ArtifactIngestor Core)

**What:** Implement markdown handoff parsing with all edge cases from Amendment 10.
Implement canonical handoff copy to `artifacts/handoffs/`. Implement
`parsed-handoffs/<worker>.json` output. Implement the transactional ingestion
order (copy → parsed JSON → events → projection).

This slice does NOT implement orphan recovery — that requires the resume
infrastructure from Slice 10.

**Execution-packet obligations:** IF3 (ArtifactIngestor), C6 (Transactional
Handoff Ingestion — ingestion order only, orphan detection in Slice 10).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 3 (events for `handoff_detected`, `handoff_parsed`,
`artifact_registered`).

**Test obligations:**
- Happy path: valid handoff with all required sections
- `HandoffNotFound`: no handoff file at expected path → correct error type
- Missing required heading → `ParseError` with section name
- Duplicate heading → last occurrence used, `parse_warnings` emitted
- No headings found → `MalformedMarkdown`
- Empty section → accepted as valid
- Invalid `Verdict` value → `ParseError`
- Invalid `Completion Claim` → `ParseError`
- Non-UTF-8 encoding → `ParseError`
- Transactional ingestion order verified: canonical copy exists before events are
  appended; `parsed-handoffs/<worker>.json` exists before `handoff_parsed` event;
  full C6 sequence (copy → parsed JSON → events → projection) enforced

- Parser failures (`ParseError`, `MalformedMarkdown`, `HandoffNotFound`) drive
  the attempt to `failed` state via the state machine enforcer (IF3 → IF6 wiring)

**Done when:** Parser handles all 8 edge cases (7 parse cases + HandoffNotFound).
Transactional ingestion order is enforced and tested. Parser failures correctly
transition attempts to `failed`.

---

### Slice 6: Step Executor + Required Artifacts

**What:** Implement the dispatch algorithm (10-step sequence from the amended
spec). Wire PromptBuilder and WorkerDispatcher adapter interfaces. Implement
header generation with resolved inputs, success criteria, and retry context.
Implement completion detection (process exit + handoff presence). Implement
completion policy evaluation (`all_complete`, `all_clean`, `any_complete`,
`manual`). Implement the circuit breaker (max_attempts exhaustion →
`step_blocked`). Implement `pipeline-execute` runtime blocking (C9). Enforce
Definition Freeze at runtime (I10 — read side). Produce `attempt.json`,
`input-bindings.json`, and `output-bindings.json` for each attempt.

**Execution-packet obligations:** IF1 (PromptBuilder), IF2 (WorkerDispatcher),
I3 (Attempt Immutability), I4 (Attempt Isolation), I5 (Deterministic Dispatch
Identity), I10 (Definition Freeze — uses shared `DefinitionLoader` from Slice 2),
C9 (`pipeline-execute` runtime blocking), C10 (Adapter Errors Retryable).

**Produces:** `attempt.json`, `input-bindings.json`, `output-bindings.json`,
`prompt-header.md`, `prompt.md` (per worker attempt).

**Layer:** Rust (portable dispatch logic) + shell adapter (Claude Code
implementation of IF1/IF2).

**Dependencies:** Slices 1-5 (all prior slices).

**Test obligations:**
- Single-worker happy path: header → prompt → dispatch → handoff → parse → bind →
  complete
- Retry: first attempt fails, retry includes prior issues in header
- Multi-worker fanout: both workers dispatched, completion policy evaluated
- Circuit breaker: exhaust `max_attempts`, verify `step_blocked`
- Attempt immutability (I3): verify terminal attempt dirs unchanged after retry
- Attempt isolation (I4): verify no two attempt directories share any mutable file
  path — enumerate all paths in attempt 001 and 002, confirm zero overlap
- Dispatch identity (I5): verify all five fields present in `worker_dispatched`
  events AND verify no two events share the same five-field tuple
- Header includes resolved input digests, not raw markdown
- **IF1 idempotence:** call PromptBuilder twice with same inputs, verify
  byte-identical outputs
- **IF1 error:** given a missing input, verify `MissingInput` is returned and no
  files are written
- **IF2 exit capture:** verify exit code captured for both clean (exit 0) and
  crash (non-zero/signal) exits
- **IF2 timeout:** verify timeout fires after configured duration
- **`pipeline-execute` at runtime:** reaching a `pipeline-execute` step emits
  `step_blocked` with reason `"pipeline-execute not implemented in v1"` and run
  enters `blocked`
- **Definition Freeze enforcement:** modify source YAML after run start, verify
  the step executor reads from `definition.snapshot.yaml` and ignores the change
- **`attempt.json`** written with status, timestamps, retry cause
- **`input-bindings.json`** written with resolved artifact references before
  dispatch
- **`output-bindings.json`** written with bound outputs after handoff parsing

**Done when:** A single dispatch step can run end-to-end using the Claude Code
adapter. Retries and circuit breaker work. `pipeline-execute` blocks at runtime.
Definition Freeze is enforced. All per-attempt artifacts are produced.

---

### Slice 7: Interactive Steps + CLI Adapter

**What:** Implement interactive step handling: prompt presentation, response
collection, type validation, artifact recording. Implement the CLI adapter with
`--approve`, `--reject`, `--response-file`, `--select`, `--checklist` flags.
Produce `attempt.json` for interactive attempts. Persist the interactive prompt
in the attempt directory before collecting input (so resume can re-display it).
Produce `input-bindings.json` (resolved inputs consumed by this step) and
`output-bindings.json` (output bound from the response) per attempt — same
provenance surface as dispatch attempts.

**Execution-packet obligations:** IF4 (InteractiveIO), I8 (Legal Transitions),
I3 (Attempt Immutability — interactive attempts).

**Produces:** `attempt.json`, `input-bindings.json`, `output-bindings.json`,
prompt artifact, response artifact (all in attempt directory).

**Layer:** Rust (portable interactive contract) + CLI adapter.

**Dependencies:** Slice 2 (state machines, events), Slice 4 (output binding from
interactive responses).

**Test obligations:**
- Each `response_type` validates correctly (approval, markdown, selection,
  checklist)
- `UserAborted` on interrupt
- Response artifact written before function returns
- Response binds to declared output name
- Step transitions: `running → waiting_for_input → running → completed`
- Invalid response type rejected (`InvalidResponse` error)
- **Prompt persisted:** interactive prompt is written to the attempt directory
  before input collection begins (verified by checking file exists before
  response is recorded)
- **`attempt.json` produced:** interactive attempts write `attempt.json` with
  status, timestamps, and `response_type`
- **`input-bindings.json` produced:** records resolved inputs consumed by this
  interactive step before prompting
- **`output-bindings.json` produced:** records the output bound from the response
  artifact after validation
- **Attempt immutability (I3):** if an interactive step is retried (e.g., user
  aborts then re-runs), verify prior attempt directory is unchanged (checksum)

**Done when:** Interactive steps work via CLI flags and interactive prompts.
`attempt.json`, `input-bindings.json`, `output-bindings.json`, and prompt artifact
are produced. An interactive step in a real method runs correctly.

---

### Slice 8: Synthesis Steps

**What:** Implement the `synthesis` action type. No relay root allocation. The
runner reads consumed inputs, the orchestrator writes the output artifact directly
to `artifacts/outputs/`, and events are emitted (`synthesis_started`,
`synthesis_completed`). Produce `attempt.json` for synthesis attempts (simpler
than dispatch attempts — no worker, no relay root). Track attempt state transitions
through the synthesis-specific state machine (`created → running → output_bound →
completed` or `created → running → failed`).

**Execution-packet obligations:** C3 (Synthesis No Relay Root), I1 (events for
synthesis), I3 (Attempt Immutability — synthesis attempts).

**Produces:** `attempt.json`, `input-bindings.json`, `output-bindings.json`
(all in attempt directory — same provenance surface as dispatch/interactive).

**Layer:** Rust (portable synthesis contract) + orchestrator integration.

**Dependencies:** Slice 2 (events, state machines), Slice 4 (input resolution,
output binding).

**Test obligations:**
- No relay directories created for synthesis steps
- `synthesis_started` and `synthesis_completed` events emitted with correct
  payload fields (`consumed_inputs`, `produced_output_name`, `artifact_path`)
- Exact event lifecycle verified: `step_started` → `synthesis_started` →
  `synthesis_completed` → `output_bound` → `step_completed` (no other events)
- Output written to `artifacts/outputs/<name>.json`
- Synthesis failure → `step_blocked`, no auto-retry
- Input resolution works (consumes named outputs from prior steps)
- **No dispatch paths touched:** verify that PromptBuilder, WorkerDispatcher,
  `compose-prompt.sh`, and `codex exec` are never invoked for synthesis steps
  (test via mock adapter that fails if called)
- **`attempt.json` produced:** synthesis attempts write `attempt.json` with
  status, timestamps, and consumed input names
- **`input-bindings.json` produced:** records consumed inputs before synthesis
  begins
- **`output-bindings.json` produced:** records the output bound after synthesis
  completes
- **Attempt state transitions verified:** `created → running → output_bound →
  completed` for success; `created → running → failed` for failure
- **Attempt immutability (I3):** if a synthesis step fails and is not retried
  (no auto-retry), verify the failed attempt directory is unchanged if a
  manual re-run allocates a new attempt

**Done when:** A synthesis step reads inputs, writes an output, emits the exact
event lifecycle, and produces `attempt.json`, `input-bindings.json`, and
`output-bindings.json`. No relay root, prompt assembly, or dispatch path is
touched. Attempt state transitions follow the synthesis machine. Failed attempts
are immutable.

---

### Slice 9: Phase Gates

**What:** Implement gate evaluation with the five outcome types (`waiting`,
`approved`, `rejected`, `timed_out`, `validation_failed`). Implement all six gate
types (`approval`, `outputs_present`, `handoff_verdict`, `completion_claim`,
`manual_test_complete`, `pipeline_clean`). Wire gate outcomes to state transitions
and retry logic.

**Execution-packet obligations:** Gates from amended spec (Amendment 5).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 2 (state machines), Slice 5 (parsed handoff data for
`handoff_verdict` and `completion_claim` gates), Slice 7 (interactive responses
for `approval` and `manual_test_complete` gates).

**Test obligations:**
- `approval` gate: `waiting` → `approved` (on approval) or `rejected` (on
  rejection)
- `outputs_present` gate: `waiting` (outputs missing) → `approved` (outputs exist)
  or `validation_failed` (wrong outputs)
- `handoff_verdict` gate: `approved` (verdict matches) or `validation_failed`
- `completion_claim` gate: `approved` or `validation_failed`
- `manual_test_complete` gate: `waiting` → `approved` or `rejected`
- `pipeline_clean` gate: parsed and validated at normalization, but at runtime
  evaluates to `step_blocked` with reason `"pipeline_clean requires
  pipeline-execute, not implemented in v1"` — consistent with C9. Test verifies
  the block behavior, not the evaluation logic.
- `validation_failed` triggers retry if attempts remain
- `rejected` and `timed_out` move step/phase to `blocked`
- Phase gate runs only after all steps are terminal
- Step gate runs after that step is terminal

**Done when:** Five gate types evaluate correctly at runtime. `pipeline_clean`
is parsed but blocked at runtime (v1-deferred, consistent with C9). Gate outcomes
drive correct state transitions and retry/block behavior.

---

### Slice 10: Resume + Reconciliation

**What:** Implement the two-phase resume protocol: (1) replay from
`events.ndjson` to rebuild state using the shared `DefinitionLoader` (reads
`definition.snapshot.yaml`, never source YAML — I10), (2) **action-agnostic
reconciliation** — scan the filesystem for ANY persisted artifact that exists
without corresponding events, not just handoffs. This covers three orphan
windows:
  - Dispatch: canonical handoff exists but `handoff_detected` not appended (C6)
  - Interactive: response artifact exists but `interactive_response_recorded`
    not appended
  - Synthesis: output artifact exists but `synthesis_completed` not appended

For each orphan found, reconciliation emits the missing events. This matches
C7's requirement that reconciliation covers all persisted artifacts that can
precede event append.

Implement resume for ALL action types:

- **Dispatch steps:** nonterminal worker scanning (active → keep running,
  inactive + handoff → ingest, inactive + no handoff → fail + retry).
- **Interactive steps:** if run is `waiting_for_input`, resume re-displays the
  persisted prompt from the attempt directory and accepts CLI flags (`--approve`,
  `--response-file`, etc.) to satisfy the step.
- **Synthesis steps:** if a synthesis attempt was interrupted (`running` state),
  mark it `failed` and re-run (synthesis is orchestrator logic, so restart is
  safe).
- **Gate-wait states:** if the run is parked in `waiting_for_gate`, resume
  restores the gate state and resumes per gate type:
  - **Interactive gates** (`approval`, `manual_test_complete`): re-enter
    `waiting_for_gate`, use `InteractiveIO` to collect the response (e.g.,
    `--approve`).
  - **Non-interactive waitable gates** (`outputs_present`): re-evaluate the
    gate condition against current state. If outputs now exist (e.g., produced
    by a parallel step that completed after the gate was first checked), the
    gate resolves immediately. Otherwise, re-enter `waiting_for_gate`.
  - **External gates** (`pipeline_clean`): v1-deferred alongside
    `pipeline-execute` (C9). If a `pipeline_clean` gate is encountered at
    runtime, the step blocks with `"pipeline_clean requires pipeline-execute,
    not implemented in v1"`. Resume for this gate type simply restores the
    blocked state. Full reattach/poll semantics are deferred to the
    `pipeline-execute` implementation.

**Execution-packet obligations:** C7 (Resume Is Replay Plus Reconciliation), C6
(Transactional Ingestion — orphan detection and recovery), I10 (Definition Freeze
— resume uses shared `DefinitionLoader`).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** All prior slices (resume exercises the full system).

**Test obligations:**
- Clean resume: stop and restart with no crash → state is identical
- Crash mid-ingestion: kill between artifact copy and event append → resume detects
  orphan and emits missing events (C6 orphan recovery)
- `state.json` missing: rebuild from events only
- `state.json` stale (behind latest seq): rebuild from events
- Nonterminal worker with handoff: ingested on resume
- Nonterminal worker without handoff: marked failed, retry applied
- Replay phase and reconciliation phase are logged as distinct operations
- Orphan detection: canonical `artifacts/handoffs/` file exists but no
  `handoff_detected` event → reconciliation emits the missing events
- **Interactive resume:** run parked on `waiting_for_input` → `method-runner
  resume --approve` satisfies the step and run continues
- **Synthesis resume:** interrupted synthesis attempt → marked `failed`, fresh
  attempt runs orchestrator logic again
- **Definition Freeze on resume:** modify source YAML, resume, verify runner
  reads from `definition.snapshot.yaml` via `DefinitionLoader`
- **Gate-wait resume (interactive gate):** kill run while parked on
  `waiting_for_gate` (approval gate) → resume → `--approve` → run continues
- **Gate-wait resume (non-interactive gate):** kill run while parked on
  `waiting_for_gate` (`outputs_present` gate) → resume → gate re-evaluates →
  if outputs now exist, gate passes immediately
- **Gate-wait resume (external gate, v1-deferred):** `pipeline_clean` gate
  encountered at runtime → step blocks → resume restores the blocked state
  (no reattach/poll in v1)
- **Interactive orphan recovery:** response artifact exists but
  `interactive_response_recorded` not in events → reconciliation emits missing
  event
- **Synthesis orphan recovery:** output artifact exists but
  `synthesis_completed` not in events → reconciliation emits missing event
- **Binding-only orphan recovery:** action-specific event exists (e.g.,
  `handoff_parsed`) but `output_bound` was not appended → reconciliation
  detects the gap and emits the missing binding event

**Done when:** Resume works across session boundaries for all three action types
(dispatch, interactive, synthesis), for ALL gate-wait types (interactive,
non-interactive, external), and for all orphan artifact types (handoffs,
responses, synthesis outputs). The two resume phases (replay + reconciliation)
are clearly separated in logs. Definition Freeze is enforced on resume.

---

### Slice 11: Parallel Execution

**What:** Implement phase-level parallelism (`execution: parallel`) and step-level
worker fanout. Implement join semantics per completion policy. Ensure output
availability respects terminal join.

**Execution-packet obligations:** I7 (Conservative Output Availability), C4
(`first-clean` Definition Order).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** Slice 6 (step executor), Slice 4 (output resolver), Slice 9
(gates — parallel phases may have gates at join).

**Test obligations:**
- Two steps in a parallel phase start concurrently
- Phase joins only when all steps are terminal (or fail-fast, if implemented)
- `all_complete` waits for every worker
- `first-clean` uses definition order
- Output from step A unavailable to step B until A is terminal (conservative
  availability)
- Phase gate evaluates only after all steps are terminal
- **Mixed-action parallel phase:** a parallel phase containing a dispatch step,
  an interactive step, and a synthesis step all execute correctly and join is
  action-agnostic

**Done when:** Parallel phase execution works for all action types. Join
semantics are correct and action-agnostic. Output availability is enforced.

---

### Slice 12: Error Taxonomy + Observability

**What:** Implement the six error categories from Amendment 9. Ensure every error
is classified and handled per its category. Add **optional telemetry enrichment**
fields to event payloads: dispatch latency, retry reason, parse-failure class,
gate wait duration, lock contention count. The required payload schemas were locked
in Slice 2 — this slice adds observability fields on top, not changes to required
schemas.

**Execution-packet obligations:** Error Taxonomy (Amendment 9), event payload
enrichment (Amendment 6 — telemetry extension, not schema change).

**Layer:** Rust (`core/capacitor-core/`).

**Dependencies:** All prior slices (error taxonomy spans the full system).

**Test obligations:**
- Each error category triggers the correct runner behavior
- Method authoring errors fail at normalization
- Adapter errors schedule retry
- Worker failures schedule retry with prior issues
- Parse failures schedule retry with diagnostics
- Gate failures: `validation_failed` retries, `rejected`/`timed_out` blocks
- Operator-unblock-required emits `step_blocked`
- All ~27 event kinds have their required payload fields populated — verified
  via: (a) integration test running a multi-step method covering dispatch,
  interactive, synthesis, gates, and retry paths, PLUS (b) targeted emission
  tests for event kinds not covered by the integration scenario (e.g.,
  `resume_scan_started`, `resume_scan_finished`, `state_rebuilt`).
  Note: `pipeline_child_started` and `pipeline_child_completed` are v2-only
  per C9 — they are defined in the type system but no v1 test emits them

**Done when:** Error handling matches the taxonomy. Every event payload is typed
and validated. Observability fields are present.

---

## Dependencies

```text
Slice 1: Definition Model + Normalizer
  └─→ Slice 2: State Machines + Event Types
       └─→ Slice 3: Lock Manager + Event Persistence
            ├─→ Slice 4: Output Resolver + Binding Policies
            │    └─→ Slice 5: Handoff Parser
            │         └─→ Slice 6: Step Executor + Required Artifacts ←── Slices 1-5
            │              └─→ Slice 11: Parallel Execution ←── Slices 4, 9
            ├─→ Slice 7: Interactive Steps ←── Slice 4
            ├─→ Slice 8: Synthesis Steps ←── Slice 4
            └─→ Slice 9: Phase Gates ←── Slices 5, 7
                 └─→ Slice 10: Resume + Reconciliation ←── All prior
                      └─→ Slice 12: Error Taxonomy + Observability ←── All prior
```

---

## Layer or Owner per Slice

| Slice | Primary Layer | Owner |
|---|---|---|
| 1. Definition Model | Rust `core/capacitor-core/src/domain/` | Domain |
| 2. State Machines + Event Types | Rust `core/capacitor-core/src/domain/` | Domain |
| 3. Lock Manager + Event Persistence | Rust `core/capacitor-core/src/storage/` | Storage |
| 4. Output Resolver | Rust `core/capacitor-core/src/domain/` | Domain |
| 5. Handoff Parser | Rust `core/capacitor-core/src/ingest/` | Ingest |
| 6. Step Executor + Artifacts | Rust `core/capacitor-core/src/runtime_service/` + shell adapter | Runtime + Adapter |
| 7. Interactive Steps | Rust `core/capacitor-core/src/domain/` + CLI adapter | Domain + Adapter |
| 8. Synthesis Steps | Rust `core/capacitor-core/src/domain/` | Domain |
| 9. Phase Gates | Rust `core/capacitor-core/src/domain/` | Domain |
| 10. Resume | Rust `core/capacitor-core/src/runtime_service/` | Runtime |
| 11. Parallel Execution | Rust `core/capacitor-core/src/runtime_service/` | Runtime |
| 12. Error Taxonomy | Rust `core/capacitor-core/` (cross-cutting) | All |

---

## Artifact Ownership

Every required artifact from the execution packet is assigned to a producing slice.

| Artifact | Producing Slice | Notes |
|---|---|---|
| `definition.snapshot.yaml` | Slice 1 | Written once at run start |
| `steps/<phase>/<step>/step.json` | Slice 1 | Static metadata per step |
| `events.ndjson` | Slice 3 | Lock-backed append |
| `state.json` | Slice 3 | Atomic write-then-rename |
| `locks/run.lock` | Slice 3 | Lock manager |
| `artifacts/outputs/<name>.json` | Slice 4 | Written on successful binding |
| `artifacts/handoffs/<phase>--<step>--<attempt>--<worker>.md` | Slice 5 | Canonical handoff copy |
| `parsed-handoffs/<worker>.json` | Slice 5 | Machine-parsed handoff |
| `prompt-header.md` | Slice 6 | Per worker attempt |
| `prompt.md` | Slice 6 | Per worker attempt |
| `attempt.json` (dispatch) | Slice 6 | Dispatch attempt metadata |
| `attempt.json` (interactive) | Slice 7 | Interactive attempt metadata |
| `attempt.json` (synthesis) | Slice 8 | Synthesis attempt metadata |
| `input-bindings.json` (dispatch) | Slice 6 | Resolved inputs per dispatch attempt |
| `input-bindings.json` (interactive) | Slice 7 | Resolved inputs per interactive attempt |
| `input-bindings.json` (synthesis) | Slice 8 | Resolved inputs per synthesis attempt |
| `output-bindings.json` (dispatch) | Slice 6 | Resolved outputs per dispatch attempt |
| `output-bindings.json` (interactive) | Slice 7 | Bound output from response |
| `output-bindings.json` (synthesis) | Slice 8 | Bound output from synthesis |
| Interactive prompt artifact | Slice 7 | Persisted before input collection |
| Interactive response artifact | Slice 7 | Typed response in attempt dir |

---

## Test Obligations per Slice

| Slice | Unit Tests | Integration Tests |
|---|---|---|
| 1. Definition Model | 11+ | 1 (real YAML normalization) |
| 2. State Machines + Event Types | 19+ | 1 (projection determinism) |
| 3. Lock Manager + Event Persistence | 11+ | 2 (concurrent lock, round-trip rebuild) |
| 4. Output Resolver | 12+ | — |
| 5. Handoff Parser | 11+ | 1 (C6 ingestion order) |
| 6. Step Executor + Artifacts | 16+ | 2 (happy path, retry) |
| 7. Interactive Steps | 11+ | 1 (real interactive step) |
| 8. Synthesis Steps | 12+ | 1 (end-to-end synthesis) |
| 9. Phase Gates | 10+ | 2 (approval flow, retry flow) |
| 10. Resume | — | 17 (crash + handoff orphan + interactive orphan + synthesis orphan + binding orphan + interactive resume + synthesis resume + I10 + interactive gate-wait + non-interactive gate-wait + external gate-wait blocked) |
| 11. Parallel Execution | — | 5 (parallel, fanout, join, availability, mixed-action) |
| 12. Error Taxonomy | 7+ | 2 (integration scenario + targeted emission) |
| **Total** | **123+** | **36+** |

---

## Review Points

| After Slice | Review Focus |
|---|---|
| Slice 1 | Does the normalized model faithfully represent the YAML schema? Can a real method YAML normalize? Are `step.json` files correct? |
| Slice 3 | Lock + appender + projection work together. State can be rebuilt from events. Torn-tail recovery works. |
| Slice 6 | End-to-end dispatch works with Claude Code adapter. Header quality is sufficient. All per-attempt artifacts produced. `pipeline-execute` blocks correctly. Definition Freeze enforced. `state.json` is human-readable. |
| Slice 10 | Resume works across session boundaries. Crash recovery with orphan reconciliation is reliable. Two phases are distinct in logs. |
| Slice 12 | All event payloads are populated. Error handling matches taxonomy. Full method run succeeds end-to-end. |

---

## Done Criteria

The method runner implementation is complete when:

1. All 12 slices pass their unit and integration tests.
2. A real method skill (spec-hardening or research-to-implementation) runs
   end-to-end using the CLI adapter.
3. Resume works across session boundaries (kill and restart mid-run).
4. `state.json` can be deleted and rebuilt from `events.ndjson` at any point.
5. Every event kind has its required payload fields populated and validated.
6. The error taxonomy correctly classifies and handles every observed error type.
7. No code in the portable domain layer imports or references Claude-Code-specific
   modules (adapter boundary is clean).
8. `pipeline-execute` steps are normalized but blocked at runtime with a clear
   message.
9. Every required artifact from the execution packet is produced by its assigned
   slice and verified by tests.

---

## Revision Changelog

| Gap | Fix |
|---|---|
| **Gap 1: Lock/appender ordering** | Split old Slice 2. New Slice 2 = types + transitions only. New Slice 3 = Lock Manager + Event Persistence (appender is now lock-backed from birth). |
| **Gap 2: I10 half-owned** | Slice 6 now owns Definition Freeze read-side enforcement with explicit test (modify source YAML after start, verify ignored). |
| **Gap 3: C9 no runtime owner** | Slice 6 now owns `pipeline-execute` runtime blocking with explicit test. |
| **Gap 4: Artifact ownership** | New "Artifact Ownership" table assigns every required artifact to a producing slice. `step.json` → Slice 1, `attempt.json`/`input-bindings.json`/`output-bindings.json` → Slice 6, `artifacts/outputs/<name>.json` → Slice 4. |
| **Gap 5: Forward reference** | Slice 5 no longer claims orphan recovery. Orphan detection and recovery moved entirely to Slice 10 (Resume). |
| **Missing tests (8)** | Added: IF5 error classes (Slice 1), projection-fires-after-append (Slice 3), highest-attempt-wins + unresolvable worker locators (Slice 4), HandoffNotFound + full C6 order (Slice 5), IF1 idempotence + IF1 MissingInput + IF2 exit/timeout + I5 uniqueness + pipeline-execute blocking + I10 enforcement (Slice 6), exact synthesis lifecycle + no-dispatch proof (Slice 8). |
| **Manual gate unassigned** | `state.json` human-readability check assigned to Slice 6 review point. |

### Round 3 Fixes (from plan-review round 2)

| Gap | Fix |
|---|---|
| **R2 Gap 1: I10 still partial** | Introduced shared `DefinitionLoader` in Slice 2. Both Slice 6 (execute) and Slice 10 (resume) use it. Slice 10 has explicit resume-after-source-edit test. |
| **R2 Gap 2: Attempt artifacts dispatch-only** | Slices 7 and 8 now produce `attempt.json` for their action types. Slice 7 also persists the interactive prompt before input collection. Artifact Ownership table updated. |
| **R2 Gap 3: Resume dispatch-only** | Slice 10 now covers resume for interactive (`waiting_for_input` → re-display prompt, accept CLI flags) and synthesis (interrupted → mark failed, re-run) steps. Three new tests. |
| **R2 Missing: Slice 5 parser→failed** | Added test that parser failures drive attempt to `failed` state. |
| **R2 Missing: Slice 6 I4** | Added explicit I4 verification (no shared mutable paths across attempts). |
| **R2 Missing: Slice 7 prompt persistence** | Added test that prompt is persisted before input collection. |
| **R2 Missing: Slice 8 attempt state** | Added attempt-state transition tests and `attempt.json` production. |
| **R2 Missing: Slice 10 interactive resume** | Added interactive resume test via CLI flags. |
| **R2 Sequence: payload schema timing** | Payload schemas locked at Slice 2. Slice 12 does enrichment only. |
| **R2 Sequence: mixed-action parallel** | Slice 11 adds mixed-action parallel phase test. |

### Round 4 Fixes (from plan-review round 3)

| Gap | Fix |
|---|---|
| **R3 Gap 1: Binding artifacts dispatch-only** | `input-bindings.json` and `output-bindings.json` now produced by Slices 7 (interactive) and 8 (synthesis) per attempt, same as Slice 6 (dispatch). Artifact Ownership table updated with action-qualified entries. Tests added to both slices. |
| **R3 Gap 2: Resume omits gate-wait** | Slice 10 now covers gate-wait resume: restores `waiting_for_gate` state, uses InteractiveIO path to collect gate response. New test: kill during approval gate → resume → `--approve` → run continues. |
| **R3 Missing: `pipeline_clean` gate** | Slice 9 now tests all six gate types including `pipeline_clean` (waiting/approved/rejected/timed_out). |
| **R3 Missing: event payload coverage** | Slice 12 now uses integration scenario PLUS targeted emission tests for event kinds not covered by the scenario. |
| **R3 Missing: binding tests for 7/8** | Added `input-bindings.json` and `output-bindings.json` tests to Slices 7 and 8. |

### Round 5 Fixes (from plan-review round 4)

| Gap | Fix |
|---|---|
| **R4 Gap 1: Gate-wait resume type-incomplete** | Slice 10 now specifies distinct resume semantics per gate type: interactive gates use InteractiveIO, `outputs_present` re-evaluates, `pipeline_clean` reattaches/polls. Two new tests (interactive + non-interactive gate-wait). |
| **R4 Gap 2: Reconciliation narrower than C7** | Slice 10 reconciliation is now action-agnostic: scans for handoff, interactive response, AND synthesis output orphans. Two new orphan recovery tests (interactive + synthesis). Transactional write ordering defined per action type. |
| **R4 Missing: I3 for non-dispatch** | Slices 7 and 8 now have explicit attempt immutability tests (checksum verification of prior attempt dirs). |
| **R4 Missing: non-handoff crash-window tests** | Added interactive-response and synthesis-output orphan recovery tests to Slice 10. |

### Round 6 Fixes (from plan-review round 5)

| Gap | Fix |
|---|---|
| **R5 Gap 1: `pipeline_clean` gate-wait resume untested** | Added explicit `pipeline_clean` gate-wait resume test: reattach to running child, and detect already-completed child. Two new integration tests. |
| **R5 Missing: binding-only orphan recovery** | Added test for crash between action event and `output_bound` event — reconciliation detects and emits missing binding. |
| **R5 Sequence: test count mismatch** | Corrected Slice 10 test count to match actual test list (19 integration tests). |

### Round 7 Fixes (from plan-review round 6)

| Gap | Fix |
|---|---|
| **R6 Gap 1: `pipeline_clean` has no owned runtime boundary** | Made `pipeline_clean` v1-deferred alongside `pipeline-execute` (C9). At runtime, `pipeline_clean` gates block with a clear message — consistent with how `pipeline-execute` steps block. No external pipeline observer, child-run identity, or reattach/poll needed in v1. Resume restores the blocked state. Full external gate semantics deferred to the `pipeline-execute` implementation. |
| **R6 Sequence: integration total drift** | Corrected total to match per-slice enumeration (122+ unit, 36+ integration). |
| **R6 Missing: replay proof for external watch target** | Not needed in v1 — `pipeline_clean` blocks, so there is no external watch target to replay. |
| **Circuit breaker note** | Rounds 5 and 6 both returned REVISE on the same feature (`pipeline_clean` external boundary). The root cause was treating a v1-deferred feature as if it needed v1 implementation. Aligning `pipeline_clean` with C9 resolves the loop. |
