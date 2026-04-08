# Execution Packet: Method Runner

> Derived from the amended spec. This is the build contract — invariants that must
> hold, interfaces that must exist, constraints the implementation must respect,
> and verification obligations per slice.

---

## Invariants

These are non-negotiable correctness properties. Violation of any invariant is a
runner bug, not a feature gap.

### I1. Event Authority

`events.ndjson` is the sole source of truth for run history. `state.json` is a
rebuildable projection. Any state that cannot be reconstructed from events plus
immutable artifacts is a bug.

**Verification:** Delete `state.json`, rebuild from events, diff against the
original. The diff must be empty (modulo timestamps in resume metadata).

### I2. Append-Only History

Events are never modified, reordered, or deleted. The `seq` field is monotonically
increasing and assigned by a single writer (the lock holder).

**Verification:** After any operation, verify `seq` values are strictly increasing
with no gaps.

### I3. Attempt Immutability

Once an attempt reaches a terminal state (`completed` or `failed`), its directory
and all contents are immutable. No process may write into a terminal attempt's
directory tree.

**Verification:** After a retry allocates attempt `002`, verify that all files in
`001/` have unchanged checksums.

### I4. Attempt Isolation

No two worker attempts share mutable files. Retries always allocate a new attempt
directory with a fresh relay root per worker.

**Verification:** Verify no two attempt directories share any file path (excluding
read-only inputs).

### I5. Deterministic Dispatch Identity

A worker's identity is always `run_id + phase_id + step_id + attempt + worker_id`.
This tuple is sufficient for replay, deduplication, and artifact provenance.

**Verification:** Verify every `worker_dispatched` event contains all five fields,
and no two events share the same tuple.

### I6. Atomic Projection

`state.json` is written via write-to-temp-then-rename. Readers never observe a
partial projection.

**Verification:** Kill the runner mid-projection. On restart, verify `state.json`
is either the pre-kill version or the fully-written new version, never a truncated
file.

### I7. Conservative Output Availability

A downstream step cannot consume a producing step's outputs until that step reaches
terminal join, unless `early_availability: true` is explicitly declared on the
output.

**Verification:** In a parallel phase, attempt to resolve an output from a
non-terminal step. Verify the runner emits an error, not a stale binding.

### I8. Legal Transitions Only

The runner rejects state transitions not listed in the entity state machines (run,
phase, step, attempt, worker). Illegal transitions produce an error event.

**Verification:** Inject an illegal transition (e.g., `completed → running`) via a
test harness. Verify the runner emits an error event and does not mutate state.

### I9. Lock Exclusivity

At most one mutating process holds `run.lock` at any time. Read-only operations
(inspecting state, reading artifacts) do not require the lock.

**Verification:** Attempt to acquire `run.lock` from two processes simultaneously.
Verify only one succeeds; the other times out or waits.

### I10. Definition Freeze

`definition.snapshot.yaml` is written once at run start and never modified. All
runtime logic reads from the snapshot.

**Verification:** Modify the source YAML after run start. Verify the runner
ignores the change and continues from the snapshot.

### I11. Template Explicitness

Template selection follows the explicit precedence chain only (dispatch.template →
step.template → method.defaults.template → `implement`). No inference.

**Verification:** Create a step with no template at any level. Verify the runner
uses `implement`. Create a step with `dispatch.template: review`. Verify `review`
is used regardless of step description prose.

### I12. Binding Is Routing

Output binding policies (`single`, `all`, `first-clean`) route data. They never
perform synthesis, summarization, or transformation.

**Verification:** Inspect every binding resolution path. Verify no code path reads
artifact contents during binding — only metadata (path, verdict, completion claim).

---

## Interfaces to Implement

### IF1. PromptBuilder

**Contract:** Accepts a `StepDefinition`, resolved inputs, retry context, worker
spec, template name, and skill list. Produces a `prompt-header.md` and `prompt.md`
written to the attempt's relay root. Must be idempotent.

**Error contract:** `MissingInput`, `TemplateNotFound`, `SkillNotFound`,
`AssemblyFailed`.

**First implementation:** `compose-prompt.sh` wrapper.

**Test obligation:** Given the same inputs twice, produces byte-identical outputs.
Given a missing input, returns `MissingInput` without writing files.

### IF2. WorkerDispatcher

**Contract:** Accepts a prompt path, relay root, worker ID, and dispatch identity.
Launches a worker process. Returns exit status and elapsed time. Must report exit
status regardless of handoff presence.

**Error contract:** `SpawnFailed`, `Timeout`, `ProcessCrash`.

**First implementation:** `codex exec --full-auto` piped from the prompt file.

**Test obligation:** Verify exit code is captured for both clean and crash exits.
Verify timeout fires after configured duration.

### IF3. ArtifactIngestor

**Contract:** Accepts a relay root, worker ID, and expected sections. Detects
handoff file, copies to canonical path, parses required sections, writes parsed
JSON. Must handle partial writes (crash recovery).

**Error contract:** `HandoffNotFound`, `ParseError`, `MalformedMarkdown`.

**Handoff parser edge cases (Amendment 10):**

| Condition | Required behavior |
|---|---|
| Missing required heading | `ParseError` with section name. Attempt → `failed`. |
| Duplicate heading | Use last occurrence. Emit `parse_warnings`. |
| No headings found | `MalformedMarkdown`. Attempt → `failed`. |
| Empty section | Accept as valid with empty string value. |
| Invalid `Verdict` value | `ParseError`. Attempt → `failed`. |
| Invalid `Completion Claim` | `ParseError`. Attempt → `failed`. |
| Non-UTF-8 encoding | `ParseError`. Attempt → `failed`. |

**Test obligation:** One test per edge case row above. Verify correct error type
and that attempt status transitions correctly.

### IF4. InteractiveIO

**Contract:** Accepts a prompt string, response type, and optional options list.
Presents to user, collects response, validates against declared type, writes
response artifact. Returns typed response and path.

**Error contract:** `UserAborted`, `InvalidResponse`, `IOError`.

**CLI flags:** `--approve` / `--reject` for blanket gate decisions, plus
`--response-dir <path>` for staged JSON responses during scripted multi-gate
runs.

**Test obligation:** Verify each response type validates correctly. Verify
`UserAborted` is emitted on interrupt. Verify response artifact is written before
the function returns.

### IF5. Definition Normalizer

**Contract:** Accepts raw YAML. Resolves all defaults (skills, template,
max_attempts, completion_policy) through the inheritance chain. Validates all
output locators reference existing phases/steps/outputs. Produces a fully explicit
`definition.snapshot.yaml` and an in-memory `NormalizedDefinition`.

**Error contract:** Method authoring errors (invalid YAML, missing required fields,
unknown action types, invalid locators, schema version mismatch).

**Test obligation:** Verify inheritance works at each level. Verify invalid
locators are caught during normalization, not at runtime.

### IF6. State Machine Enforcer

**Contract:** Accepts a current entity state and a proposed transition. Returns
the new state or rejects with an error event.

**Entities:** Run, Phase, Step, Attempt, Worker — each with its own transition
graph as defined in the amended spec.

**Test obligation:** For each entity, verify every legal transition succeeds and
at least three representative illegal transitions are rejected with error events.

### IF7. Output Resolver

**Contract:** Accepts a locator string (`phase.step.output` or
`phase.step.worker.output`), the current output registry, and the step table.
Returns the resolved `ArtifactRecord` or errors.

**Resolution algorithm:**
1. Parse locator into segments.
2. Find the producing step's terminal attempt (highest completed attempt).
3. Resolve output name from that attempt's `output-bindings.json`.
4. If worker-qualified, resolve from that worker's outputs.
5. If unqualified in a multi-worker step, apply binding policy.
6. Error if unresolvable.

**Availability check:** Verify the producing step is terminal before returning.
If non-terminal and `early_availability` is not declared, return an error.

**Test obligation:** Test each binding policy (`single`, `all`, `first-clean`).
Test availability blocking. Test invalid locator rejection.

### IF8. Lock Manager

**Contract:** Acquire `run.lock` with timeout. Release on scope exit. Detect and
recover stale locks (dead PID + start-time verification).

**Lock file format:** JSON with `pid`, `start_time`, `hostname`, `acquired_at`.

**Test obligation:** Verify stale lock detection (process dead). Verify timeout
fires. Verify concurrent acquisition is blocked. Verify read-only operations work
without the lock.

### IF9. Event Appender

**Contract:** Single writer that holds `run.lock`. Assigns monotonic `seq`.
Appends to `events.ndjson`. Triggers `state.json` projection after append.

**Corruption recovery:** If the last line of `events.ndjson` is torn (incomplete
JSON), truncate to the last valid record and log a warning. Resume from that
sequence number.

**Test obligation:** Verify `seq` monotonicity. Verify torn-tail recovery.
Verify projection fires after each append.

---

## Constraints

### C1. No Implicit Computation in Bindings

The binding layer (`single`, `all`, `first-clean`) routes artifact references. It
never reads artifact content, merges text, or performs any transformation. If
fan-in is needed, author a `synthesis` step.

### C2. No Template Inference

Template selection is a lookup, not a classifier. The precedence chain
(dispatch.template → step.template → method.defaults.template → `implement`)
is exhaustive. No step description parsing, no keyword matching.

### C3. Synthesis Steps Have No Relay Root

Synthesis steps write directly to `artifacts/outputs/`. They do not allocate
attempt relay directories, do not invoke `compose-prompt.sh`, and do not call
`codex exec`. Their event lifecycle is: `step_started` → `synthesis_started` →
`synthesis_completed` → `output_bound` → `step_completed`.

### C4. `first-clean` Uses Definition Order

When resolving a `first-clean` binding, iterate workers in YAML definition order,
not wall-clock completion order. This eliminates scheduler-induced nondeterminism.

### C5. Single Event Appender

Only the process holding `run.lock` may append events. There is no concurrent
writer path. `seq` assignment is trivially monotonic because there is one writer.

### C6. Transactional Handoff Ingestion

Handoff ingestion must follow this order to prevent replay gaps:

1. Copy handoff to canonical `artifacts/handoffs/` path.
2. Write `parsed-handoffs/<worker>.json`.
3. Append events (`handoff_detected`, `handoff_parsed`, `artifact_registered`,
   `output_bound`).
4. Update `state.json` projection.

If the runner crashes between steps 1 and 3, resume must detect the orphaned
artifact and re-emit events. The invariant is: if a canonical handoff file exists,
the event log must eventually contain its corresponding events.

### C7. Resume Is Replay Plus Reconciliation

Resume has two distinct phases (not mixed):

1. **Replay:** Rebuild state from `events.ndjson` (pure, no side effects).
2. **Reconciliation:** Scan filesystem for artifacts that exist but lack
   corresponding events (orphaned by a crash). Emit the missing events.

These phases must be named and logged separately.

### C8. Output Namespace Safety

Step output names are local to the step. Method output names are global. A step
output becomes a method output only via an explicit `method.outputs[].from`
locator. Two steps may independently declare an output named `doc` without
collision — they are disambiguated by their locator (`research.scan.doc` vs
`design.select.doc`).

### C9. `pipeline-execute` and `pipeline_clean` Are Parse-Only in v1

The runner must normalize and validate `pipeline-execute` steps and
`pipeline_clean` gates during definition normalization. At runtime:

- If a `pipeline-execute` step is reached, the runner emits `step_blocked` with
  reason `"pipeline-execute not implemented in v1"` and the run enters `blocked`.
- If a `pipeline_clean` gate is encountered, the step blocks with reason
  `"pipeline_clean requires pipeline-execute, not implemented in v1"`.
- `pipeline_child_started` and `pipeline_child_completed` events are v2-only.
  They must be defined in the event type system but no v1 code path emits them.

This is an explicit, documented limitation.

### C10. Adapter Errors Are Retryable by Default

Runtime adapter errors (spawn failure, timeout, permission denied) schedule a
retry if attempts remain. The retry header includes the adapter error class and
message. Worker failures and parse failures also schedule retries. Gate rejections
and operator-unblock-required states do NOT auto-retry — they block.

---

## Verification Strategy

### Unit Tests

| Interface | Test Count | Coverage Target |
|---|---|---|
| IF5. Definition Normalizer | 8+ | Every inheritance level, every error class |
| IF6. State Machine Enforcer | 15+ | Every legal transition + 3 illegal per entity |
| IF7. Output Resolver | 10+ | Every binding policy, availability blocking, invalid locators |
| IF8. Lock Manager | 5+ | Acquire, release, timeout, stale detection, concurrent block |
| IF9. Event Appender | 5+ | Monotonicity, torn-tail recovery, projection trigger |
| IF3. ArtifactIngestor (parser) | 7+ | One per handoff parser edge case |

### Integration Tests

| Scenario | What It Proves |
|---|---|
| Single-step dispatch (happy path) | Header → prompt → dispatch → handoff → parse → output bind → complete |
| Single-step dispatch with retry | First attempt fails (no handoff), retry succeeds, prior issues in header |
| Multi-worker fanout with `all_complete` | Both workers must complete before step is terminal |
| Multi-worker fanout with `first-clean` | Definition-order resolution, not wall-clock order |
| Interactive step (approval) | Prompt displayed, response recorded, output bound, step completes |
| Synthesis step | No relay root allocated, orchestrator writes output, events emitted |
| Phase gate (approval) | Step completes, gate enters `waiting`, approval satisfies gate |
| Phase gate (validation_failed) | Gate fails, step retries, second attempt passes gate |
| Resume after crash | Kill mid-ingestion, restart, verify reconciliation emits missing events |
| Conservative output availability | Step B blocked until step A terminal, even if A's output exists |
| Parallel phase execution | Two steps run concurrently, phase joins when both complete |
| `state.json` rebuild | Delete projection, rebuild from events, verify identical state |
| Circuit breaker | Exhaust `max_attempts`, verify `step_blocked` and run enters `blocked` |

### Property Tests (If Feasible)

| Property | Generator |
|---|---|
| State machine legality | Random event sequences → verify no illegal transition accepted |
| `seq` monotonicity | Random operations → verify strictly increasing |
| Attempt immutability | Random crash points → verify terminal attempt dirs unchanged |

### Manual Verification Gates

| Gate | When | Who |
|---|---|---|
| Run a real method skill (e.g., spec-hardening) | After integration tests pass | Human operator |
| Verify resume across session boundaries | After crash-recovery tests pass | Human operator |
| Verify `state.json` is human-readable | After projection is implemented | Human operator |

---

## Required Artifacts

These artifacts must be produced as part of the implementation, not just the code.

| Artifact | Purpose | Produced By |
|---|---|---|
| `definition.snapshot.yaml` | Frozen normalized definition at run start | IF5. Normalizer |
| `events.ndjson` | Authoritative event log | IF9. Event Appender |
| `state.json` | Projection cache | State projector (derived from IF9) |
| `locks/run.lock` | Concurrency guard | IF8. Lock Manager |
| `artifacts/outputs/<name>.json` | Canonical output registry entries | IF7. Output Resolver |
| `artifacts/handoffs/<phase>--<step>--<attempt>--<worker>.md` | Canonical handoff copies | IF3. ArtifactIngestor |
| `parsed-handoffs/<worker>.json` | Machine-parsed handoff metadata | IF3. ArtifactIngestor |
| `prompt-header.md` per worker attempt | Per-dispatch control plane | IF1. PromptBuilder |
| `prompt.md` per worker attempt | Assembled prompt | IF1. PromptBuilder |
| `input-bindings.json` per attempt | Resolved input snapshot | Runner core |
| `output-bindings.json` per attempt | Resolved output snapshot | Runner core |
| `step.json` per step | Static step metadata | IF5. Normalizer |
| `attempt.json` per attempt | Attempt runtime metadata | Runner core |

---

## Rollback or Reopen Triggers

If any of these conditions arise during implementation, stop and reopen the
relevant artifact rather than working around the problem.

### Reopen `amended-spec.md` if:

1. **State machine transitions prove insufficient.** If a real method run hits a
   state that requires a transition not in the spec (e.g., `blocked → retrying`
   without human intervention), the state machines need amendment, not a code
   workaround.

2. **A new binding policy is needed.** If `single`, `all`, and `first-clean`
   cannot express a real method's data flow without the author using awkward
   workarounds, the binding model needs revision.

3. **Gate outcomes need expansion.** If a gate result cannot be classified as
   `waiting`, `approved`, `rejected`, `timed_out`, or `validation_failed`, the
   gate model is incomplete.

4. **Synthesis steps need retry semantics.** If orchestrator-written synthesis
   fails in ways that are transient (not authoring bugs), the "no auto-retry for
   synthesis" rule may need revision.

### Reopen `caveat-resolution.md` if:

5. **Template inference becomes necessary.** If every method YAML ends up manually
   specifying templates on every step because the lack of inference is too painful,
   revisit the rejection of template intent mapping.

6. **`merge-digests` pressure returns.** If multiple real methods need fan-in
   synthesis and the `synthesis` step workaround produces excessive boilerplate,
   revisit the rejection of computational binding.

### Reopen `execution-packet.md` (this document) if:

7. **An interface boundary proves wrong.** If the adapter split
   (PromptBuilder / WorkerDispatcher / ArtifactIngestor / InteractiveIO) does not
   cleanly separate portable from Claude-specific, the interface definitions need
   revision before more code is written on top of the wrong boundary.

8. **Event payload schemas prove insufficient.** If a real integration test
   requires payload fields not in the schema, add them to the schema before
   shipping, not as ad hoc extensions.

9. **Lock protocol proves inadequate.** If real concurrent usage (e.g., two
   terminal tabs running `method-runner resume`) exposes races not covered by the
   protocol, fix the protocol before adding code-level workarounds.
