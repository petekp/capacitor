# Amended Spec: Method Runner System Requirements

> Amended from Draft C. Incorporates 11 accepted caveats from multi-angle review
> (implementer, systems, comparative). Two caveats rejected. Three risks deferred.
> See `caveat-resolution.md` for the full disposition record.

---

## Problem and Goal

Workflows such as research, design, implementation, testing, cleanup, and review
are currently encoded in prompts and operator habits. The method runner turns them
into durable, resumable, inspectable structure. A method is authored as YAML,
normalized into a run definition, and executed step by step by a runner that owns
state, dispatch, artifacts, retry logic, and gate evaluation.

The method model is the product. Claude Code is only the first execution adapter.
The design must survive three environments: local CLI execution today, `pipeline`
child execution in the near term, and first-class method execution inside
Capacitor later.

**Build target:** A CLI method runner using `compose-prompt.sh` and `codex exec`
as the first adapter. The implementation must not require structural rewrite when
ported to Capacitor's runtime service.

**Primary audience:** Implementers (user + coding agents) building the runner. This
document must be precise enough for a Codex worker to implement a slice without
re-reading the entire spec or guessing edge cases.

---

## Proposed Design

### Core Principles

- **Declarative definitions, imperative execution.** YAML describes what phases,
  steps, inputs, outputs, and gates exist. The runner decides how to execute them
  safely.
- **Forward-only progression.** A run may retry a step, but it does not silently
  move backward through the phase graph. History is append-only.
- **Artifact-first coordination.** Steps do not rely on conversational memory.
  They exchange named outputs backed by concrete artifacts.
- **Event-sourced state.** `events.ndjson` is authoritative. `state.json` is a
  projection for fast reads and UI.
- **Provider isolation.** `compose-prompt.sh`, `codex exec`, `SKILL.md`, and
  TaskCreate-like worker spawning are adapters, not domain concepts.
- **Resume safety over convenience.** Every dispatch attempt gets its own
  immutable filesystem boundary so interrupted runs can be reconstructed without
  guessing.
- **Human gates are explicit.** Approval, review, and manual-test checkpoints are
  represented in state, not hidden in prose.

### YAML Method Definition Schema

The authoring format is YAML. The runner normalizes it into a fully explicit
in-memory definition before execution. Defaults are inherited during normalization
so runtime logic never depends on implicit values.

Canonical top-level shape:

```yaml
schema_version: "1"
method:
  id: requirements-method
  version: "2026-03-21"
  title: Requirements Method
  description: Produces a reviewed requirements doc from an idea.
  defaults:
    skills: [deep-research]
    template: implement
    max_attempts: 2
    completion_policy: all_complete
  inputs:
    idea:
      type: markdown
      required: true
    constraints:
      type: markdown
      required: false
  outputs:
    requirements_doc:
      from: requirements.revise.doc
      required: true
  phases:
    - id: research
      title: Research
      execution: parallel
      skills: [proposal-review]
      steps: []
```

#### Field Contract

**Method level:**

- `schema_version`: required string. Schema version, not method version.
- `method.id`: required stable identifier. Machine-safe, unique within a library.
- `method.version`: required string. Frozen into `definition.snapshot.yaml` at run start.
- `method.title`: required human label.
- `method.description`: optional long description.
- `method.defaults.skills`: optional array of skill identifiers. Applied to every
  dispatch step unless overridden.
- `method.defaults.template`: optional default worker template. Valid values:
  `implement`, `review`, `ship-review`, `converge`.
- `method.defaults.max_attempts`: optional integer, default `1`.
- `method.defaults.completion_policy`: optional enum. Valid values: `all_complete`,
  `all_clean`, `any_complete`, `manual`.
- `method.inputs`: map of named input specs (`type`, `required`, optional
  `description`, optional `default`).
- `method.outputs`: map of named method outputs. Each declares `from` (a
  phase-step output locator) and optional `required`.
- `method.phases`: ordered array of phase definitions.

**Phase level:**

- `id`: required stable identifier.
- `title`: required human label.
- `description`: optional prose.
- `execution`: required enum `serial` or `parallel`.
- `skills`: optional array appended to method defaults for dispatch steps.
- `inputs`: optional array of named inputs required before the phase can start.
- `gate`: optional phase gate definition.
- `steps`: required ordered array of step definitions.

**Step level:**

- `id`: required stable identifier unique within the phase.
- `title`: required human label.
- `action`: required enum: `dispatch`, `interactive`, `synthesis`, or
  `pipeline-execute`.
- `description`: optional prose included in headers.
- `inputs`: optional array of named input references.
- `outputs`: optional map of named output bindings.
- `skills`: optional array appended to inherited skills.
- `template`: optional template override.
- `max_attempts`: optional integer override.
- `completion_policy`: optional override.
- `gate`: optional step gate.
- `success`: optional structured success criteria.

#### `synthesis` Action Type [Amendment 1]

The `synthesis` action type models steps where the orchestrator reads prior
artifacts and writes a new artifact directly, without dispatching a worker. This is
a first-class domain concept, not an implicit convention.

A synthesis step:

- **Consumes** named inputs (resolved output bindings from prior steps).
- **Produces** named outputs (written by the orchestrator, not a worker).
- **Does not dispatch** any worker process. No relay root is allocated.
- **Does not use** `compose-prompt.sh` or `codex exec`.
- **Records** the same event lifecycle as other steps: `step_started`,
  `output_bound`, `step_completed`.

Synthesis step extension:

- `synthesis.instructions`: required prose describing what the orchestrator must
  produce.
- `synthesis.output`: required named output binding for the artifact the
  orchestrator writes.

This is analogous to Temporal workflow logic or Inngest step functions: the
orchestrator's own computation is a typed step in the execution graph, not an
invisible gap between dispatch steps.

#### `dispatch` Step Extension

- `dispatch.instructions`: optional extra instructions appended to the header.
- `dispatch.template`: optional dispatch-specific template override.
- `dispatch.skills`: optional dispatch-specific skills.
- `dispatch.workers`: optional array of worker specs for fanout. If omitted, a
  single implicit worker named `primary` is used.
- `dispatch.workers[].id`: required stable worker identifier.
- `dispatch.workers[].title`: optional human label.
- `dispatch.workers[].instructions`: required worker-specific objective.
- `dispatch.workers[].skills`: optional extra skills.
- `dispatch.workers[].inputs`: optional narrowed input list.
- `dispatch.workers[].outputs`: optional output aliases produced by that worker.

#### `interactive` Step Extension

- `interactive.prompt`: required instructions shown to the human or UI.
- `interactive.response_type`: required enum: `approval`, `markdown`, `selection`,
  or `checklist`.
- `interactive.output`: optional named output binding from the response artifact.

#### `pipeline-execute` Step Extension

- `pipeline_execute.pipeline`: required pipeline identifier or definition reference.
- `pipeline_execute.inputs`: optional map from method-run outputs to pipeline inputs.
- `pipeline_execute.outputs`: optional map from child pipeline artifacts back to
  method outputs.

#### Template Selection [Amendment: Rejected — Explicit Only]

Template intent mapping (inferring `review` vs `implement` from prose) is
**removed from v1**. Template selection must be explicit:

1. `dispatch.template` (highest precedence)
2. `step.template`
3. `method.defaults.template`

If none is specified, the runner uses the method default. If no method default
exists, the runner uses `implement`. There is no inference step.

**Rationale:** Inference creates non-determinism under replay and migration. All
three reviews flagged this independently.

#### Skill Selection

Skills are merged, deduplicated, and ordered from broadest to most specific:

1. `method.defaults.skills`
2. `phase.skills`
3. `step.skills`
4. `dispatch.skills`
5. `dispatch.workers[].skills`

Worker-local skills only affect that worker's prompt. The normalized step record
captures the final resolved skill list so resume does not depend on re-running
inheritance logic.

### `.method/` Directory Structure

Each method run owns a `.method/` directory at the execution root.

```text
.method/
  definition.snapshot.yaml
  events.ndjson
  state.json
  locks/
    run.lock
  artifacts/
    outputs/
      <output-name>.json
    handoffs/
      <phase>--<step>--<attempt>--<worker>.md
  steps/
    <phase-id>/
      <step-id>/
        step.json
        attempts/
          001/
            attempt.json
            input-bindings.json
            output-bindings.json
            parsed-handoffs/
              <worker-id>.json
            relay/
              workers/
                <worker-id>/
                  prompt-header.md
                  prompt.md
                  handoffs/
                  last-messages/
```

Filesystem rules:

- `definition.snapshot.yaml` is the fully normalized definition frozen at run start.
- `events.ndjson` is append-only and authoritative.
- `state.json` is an atomic projection cache derived from events plus known
  filesystem artifacts.
- `locks/run.lock` prevents concurrent mutators (see Lock Protocol below).
- `artifacts/outputs/<output-name>.json` is the canonical registry entry for a
  resolved named output.
- `artifacts/handoffs/...md` is the copied canonical handoff artifact path.
- `steps/<phase>/<step>/step.json` stores normalized static step metadata.
- `attempts/<n>/attempt.json` stores attempt-level runtime metadata.
- `input-bindings.json` records the exact output artifacts injected into that attempt.
- `output-bindings.json` records resolved outputs from the attempt.
- `parsed-handoffs/<worker>.json` stores machine-parsed handoff metadata.
- `relay/workers/<worker>/` is the concrete dispatch boundary for that worker.

Key isolation guarantee: every dispatch attempt gets its own immutable directory.
No two worker attempts share mutable files. Synthesis steps do not allocate relay
roots — they write directly to `artifacts/outputs/`.

### State Management

#### Event Model

Every state mutation is first expressed as an event, then projected into
`state.json`. Every event record includes:

- `seq`: monotonic integer sequence within the run.
- `timestamp`: ISO-8601 time.
- `run_id`: stable run identifier.
- `type`: event kind.
- Optional `phase_id`, `step_id`, `attempt`, `worker_id`.
- `payload`: event-specific typed JSON object.

#### Event Payload Schemas [Amendment 6]

Each event kind has a required typed payload:

| Event Kind | Required Payload Fields |
|---|---|
| `method_initialized` | `method_id`, `method_version`, `definition_hash`, `input_bindings` |
| `phase_started` | `phase_id`, `execution_mode` (`serial`/`parallel`) |
| `phase_completed` | `phase_id`, `terminal_status` (`completed`/`failed`) |
| `step_started` | `phase_id`, `step_id`, `action_type`, `attempt_number` |
| `step_retry_scheduled` | `phase_id`, `step_id`, `retry_cause` (enum: `handoff_missing`, `verdict_rejected`, `process_crash`, `timeout`, `gate_failed`), `prior_attempt`, `next_attempt` |
| `step_blocked` | `phase_id`, `step_id`, `block_reason`, `attempts_exhausted` (bool) |
| `step_completed` | `phase_id`, `step_id`, `terminal_status`, `final_attempt` |
| `header_written` | `phase_id`, `step_id`, `attempt`, `worker_id`, `header_path` |
| `prompt_built` | `phase_id`, `step_id`, `attempt`, `worker_id`, `prompt_path`, `template`, `skills` |
| `worker_dispatched` | `phase_id`, `step_id`, `attempt`, `worker_id`, `dispatch_command`, `pid` (optional) |
| `worker_process_exited` | `phase_id`, `step_id`, `attempt`, `worker_id`, `exit_code`, `signal` (optional), `elapsed_ms` |
| `handoff_detected` | `phase_id`, `step_id`, `attempt`, `worker_id`, `handoff_path` |
| `handoff_parsed` | `phase_id`, `step_id`, `attempt`, `worker_id`, `verdict`, `completion_claim`, `issues_count`, `parse_warnings` |
| `artifact_registered` | `artifact_kind`, `canonical_path`, `producer` (`phase.step.attempt.worker`) |
| `output_bound` | `output_name`, `bound_artifact_path`, `producer`, `binding_policy` |
| `gate_waiting` | `gate_id`, `gate_type`, `phase_id` (optional), `step_id` (optional), `required_evidence` |
| `gate_passed` | `gate_id`, `gate_type`, `evidence_ref` |
| `gate_failed` | `gate_id`, `gate_type`, `failure_reason` |
| `interactive_response_recorded` | `phase_id`, `step_id`, `response_type` (`approval`/`markdown`/`selection`/`checklist`), `response_path`, `bound_output_name` (optional) |
| `synthesis_started` | `phase_id`, `step_id`, `consumed_inputs` (list of output names) |
| `synthesis_completed` | `phase_id`, `step_id`, `produced_output_name`, `artifact_path` |
| `pipeline_child_started` | `phase_id`, `step_id`, `child_pipeline_id`, `child_run_id` | **v2-only** |
| `pipeline_child_completed` | `phase_id`, `step_id`, `child_run_id`, `terminal_status` | **v2-only** |
| `resume_scan_started` | `scan_reason` (`startup`/`crash_recovery`/`explicit_resume`) |
| `resume_scan_finished` | `recovered_workers`, `failed_workers`, `state_rebuilt` (bool) |
| `state_rebuilt` | `events_replayed`, `projection_seq` |
| `method_completed` | `terminal_status` (`completed`/`failed`/`blocked`), `total_events` |

Note: `synthesis_started` and `synthesis_completed` are new events for the
`synthesis` action type.

#### Runtime Entity State Machines [Amendment 2]

Every runtime entity has a typed status enum and a legal-transitions graph. These
are the canonical state machines that the runner must enforce.

**Run:**
```
pending → running → completed
                  → failed
                  → blocked
running → waiting_for_input → running
running → waiting_for_gate  → running
```

**Phase:**
```
pending → running → completed
                  → failed
                  → blocked
running → waiting_for_gate → running
```

**Step:**
```
pending → running → completed
                  → failed
                  → blocked
running → waiting_for_input → running   (interactive steps)
running → waiting_for_gate  → running   (step gates)
running → retrying → running            (new attempt allocated)
```

**Attempt:**
```
created → dispatching → running → handoff_detected → handoff_parsed
                                                    → output_bound → completed
                                                                   → failed
running → failed   (process crash, timeout, no handoff)
handoff_parsed → failed   (verdict rejected, outputs missing)
```

For synthesis steps, the attempt machine is simpler:
```
created → running → output_bound → completed
                  → failed
```

**Worker:**
```
pending → dispatched → running → exited_clean → handoff_detected
                                              → failed (no handoff)
                     → running → exited_error → failed
exited_clean → handoff_detected → handoff_parsed → completed
                                                  → failed
```

Any transition not listed above is illegal. The runner must reject illegal
transitions with an error event rather than silently accepting them.

#### `state.json` Projection

`state.json` is the latest projection and must include:

- **Run identity:** `run_id`, `method_id`, `method_version`.
- **Global status:** one of the run state machine values.
- **Current location:** `current_phase_ids`, `current_step_ids`.
- **Step table** keyed by `phase.step`: `status`, `attempt_count`,
  `active_attempt`, `last_handoff`, `last_verdict`, `last_completion_claim`,
  `issues_summary`.
- **Worker table** keyed by `phase.step.attempt.worker`: `status`, `relay_root`,
  `dispatch_command`, `pid`, handoff path.
- **Output registry** keyed by output name.
- **Pending gate** object if blocked on approval or validation.
- **Resume metadata:** last projection time, rebuild flag.

The runner must update `state.json` using atomic write-then-rename semantics. If
`state.json` is lost or stale, it can be rebuilt solely from `events.ndjson` plus
immutable artifacts.

### Named Output Resolution

#### Output Binding Locator Grammar [Amendment 4]

The `from` field in output declarations uses a dot-separated locator:

```
<phase_id>.<step_id>.<output_name>
```

For multi-worker steps, a worker-qualified locator is available:

```
<phase_id>.<step_id>.<worker_id>.<output_name>
```

Resolution order:

1. Parse the locator into segments.
2. Resolve to the producing step's terminal attempt (the highest-numbered attempt
   with status `completed`).
3. Within that attempt, resolve the output name from `output-bindings.json`.
4. If worker-qualified, resolve from that specific worker's outputs.
5. If unqualified in a multi-worker step, apply the step's binding policy.
6. Error if the locator cannot resolve. Missing required outputs are a runner
   error, not a prompt problem.

Invalid locators (referencing nonexistent phases, steps, or outputs) must be caught
during definition normalization, not at runtime.

#### Binding Policies

For multi-worker steps, output bindings specify one of three policies:

- `single`: take the named worker's artifact.
- `all`: bind a list of artifact refs.
- `first-clean`: take the first artifact (in definition order, not wall-clock
  order) with acceptable verdict and completion claim.

**`merge-digests` is removed from v1.** If fan-in synthesis is needed, it must be a
real `synthesis` step that consumes worker outputs and produces a merged artifact.
The binding layer routes data; it does not perform computation. [Amendment: Rejected]

#### Output Availability [Amendment 11]

**Conservative by default:** A downstream step can only consume a producing step's
outputs after that step reaches its terminal join. Early consumption is an explicit
opt-in, not implicit behavior.

This means:
- In a parallel phase, step B cannot consume step A's outputs until step A is
  `completed`.
- In a multi-worker step, individual worker outputs are not available to other
  steps until the step's `completion_policy` is satisfied and the step reaches
  terminal status.
- A step may declare `early_availability: true` on a specific output to allow
  consumption before terminal join. This is the opt-in escape hatch.

### Worker Dispatch

Dispatch algorithm for a `dispatch` step:

1. Resolve inherited configuration (template, skills, max_attempts).
2. Materialize all named inputs into `input-bindings.json`.
3. Allocate the next attempt directory.
4. For each worker, allocate `relay/workers/<worker-id>/`.
5. Write a task-specific `prompt-header.md`.
6. Select template (explicit precedence only — see Template Selection).
7. Run `compose-prompt.sh` to produce `prompt.md`.
8. Emit `worker_dispatched` and launch `codex exec`.
9. Watch for process exit and valid handoff creation.
10. Parse the handoff, register artifacts, bind outputs, evaluate completion policy.

#### Header Generation

The header is the per-step control plane. For every worker attempt, the runner
writes a header containing:

- Method id, run id, phase id, step id, attempt number, worker id.
- Step objective and worker-specific instructions.
- Explicit success criteria derived from step metadata.
- Resolved named inputs, each with producer, artifact path, and short digest.
- Expected handoff path and required sections.
- Required named outputs that this worker must produce.
- Retry context (if attempt > 001): prior issues and why the runner is retrying.

The runner generates compact input blocks — canonical artifact path, short digest,
previous verdict and completion claim, and relevant issues/next steps. It does not
dump raw previous markdown wholesale.

#### Relay Root Placement

- One method run owns `.method/`.
- One dispatch step attempt owns an immutable attempt directory.
- One worker inside that attempt owns one relay root at
  `.../relay/workers/<worker-id>/`.

This is the smallest boundary that preserves `compose-prompt.sh` compatibility and
avoids collisions.

#### Parallel Workers and Completion Detection

If a step declares multiple workers, the runner dispatches all workers in that
attempt independently. A worker is terminal only when both conditions are true:

1. The worker process has exited or reached a terminal runtime state.
2. A parseable handoff exists with the required relay sections.

Exit without handoff is a failure. Handoff without terminal process state is
treated as still running. A step is terminal when its `completion_policy` is
satisfied.

Default `all_complete` means every worker must reach a terminal handoff with
`Completion Claim: COMPLETE` or an explicitly acceptable alternative declared in
step success criteria.

### Interactive Step Handling

`interactive` steps exist for approvals, selections, manual notes, and manual test
checkpoints. They do not dispatch workers.

Interactive contract:

- The attempt directory stores the prompt shown to the human or UI.
- The response is stored as a typed artifact.
- The runner emits `interactive_response_recorded` when the artifact is saved.
- The response may bind a named output.
- The step is terminal only after validating the response type and required fields.

#### CLI Adapter Behavior [Amendment 8]

The `method-runner resume` command supports interactive steps with the following
CLI protocol:

| `response_type` | CLI Behavior |
|---|---|
| `approval` | Print the prompt. Accept `--approve` or `--reject` flag, or prompt interactively for `y/n`. |
| `markdown` | Print the prompt. Accept `--response-file <path>` to provide a markdown response, or open `$EDITOR` for inline authoring. |
| `selection` | Print the prompt with numbered options. Accept `--select <index>` or prompt interactively. |
| `checklist` | Print the prompt with checkable items. Accept `--checklist <indices>` (comma-separated) or prompt interactively. |

All interactive responses are recorded as typed artifacts in the attempt directory
before the step advances. The CLI adapter must validate that the response satisfies
the declared `response_type` constraints before emitting
`interactive_response_recorded`.

### Phase Gates

Gates are structured validations that control forward progress. They are
declarative and side-effect free.

Supported gate types:

- `approval`: requires a human decision artifact.
- `outputs_present`: verifies named outputs exist.
- `handoff_verdict`: verifies allowed `Verdict` values.
- `completion_claim`: verifies allowed `Completion Claim` values.
- `manual_test_complete`: requires an interactive response confirming the test.
- `pipeline_clean`: requires the child pipeline to finish acceptably. **V1-deferred
  alongside `pipeline-execute` (C9).** At runtime in v1, encountering a
  `pipeline_clean` gate blocks the step with a clear message. Full evaluation
  semantics are deferred to the `pipeline-execute` implementation.

#### Gate Semantics with Explicit Outcomes [Amendment 5]

Gate evaluation produces one of these outcomes:

| Outcome | Meaning | Run Effect |
|---|---|---|
| `waiting` | Gate cannot be evaluated yet (preconditions not met). | Run enters `waiting_for_gate`. |
| `approved` | Gate satisfied. Forward progress continues. | Emit `gate_passed`. |
| `rejected` | Gate explicitly failed with unrecoverable evidence. | Emit `gate_failed`. Step/phase enters `blocked` (human intervention required). |
| `timed_out` | Gate waited beyond configured timeout without resolution. | Emit `gate_failed` with `failure_reason: timeout`. Step/phase enters `blocked`. |
| `validation_failed` | Gate evidence exists but does not meet criteria. | Emit `gate_failed`. Runner may retry the step if attempts remain. |

Not all gate types support all outcomes:

- `approval` gates support: `waiting`, `approved`, `rejected`.
- `outputs_present` gates support: `waiting`, `approved`, `validation_failed`.
- `handoff_verdict` and `completion_claim` gates support: `approved`,
  `validation_failed`.
- `manual_test_complete` gates support: `waiting`, `approved`, `rejected`.
- `pipeline_clean` gates: v1-deferred (blocked at runtime). Full outcome support
  (`waiting`, `approved`, `rejected`, `timed_out`) deferred to `pipeline-execute`
  implementation.

Gate evaluation rules:

- A phase gate runs after all steps in the phase are terminal.
- A step gate runs after that specific step is terminal.
- A `rejected` gate moves the run to `blocked` (human intervention required).
- A `validation_failed` gate allows retry if attempts remain.
- Gate decisions are recorded as events and surfaced in `state.json`.

### Resume Safety

On startup or resume:

1. Acquire `run.lock` (see Lock Protocol).
2. Read `state.json` if present, but treat it as a cache.
3. Rebuild from `events.ndjson` if the snapshot is missing, corrupt, or behind the
   latest sequence.
4. Scan every nonterminal worker attempt.
5. If the worker is still active, keep it running.
6. If the worker is inactive and a valid handoff exists, ingest it and continue.
7. If the worker is inactive and no valid handoff exists, mark the attempt failed
   and apply retry policy.

Safety rules:

- Terminal attempts are immutable.
- Retries always allocate a new attempt directory.
- Output registry entries are updated only by emitting new events.
- Prompt headers and prompts are immutable once dispatch begins.
- Dispatch identity is deterministic: `run_id + phase_id + step_id + attempt +
  worker_id`.

---

## Interfaces and Boundaries

### Adapter Interface [Amendment 3]

The portable domain owns four adapter interfaces. The Claude Code adapter is the
first implementation, not the specification.

#### `PromptBuilder`

Responsible for assembling the final prompt from structured inputs.

```
Request:
  step_definition: StepDefinition
  resolved_inputs: Map<OutputName, ArtifactRecord>
  retry_context: Option<RetryContext>
  worker_spec: WorkerSpec
  template: TemplateName
  skills: Vec<SkillId>

Response:
  header_path: FilePath
  prompt_path: FilePath

Errors:
  MissingInput { name: OutputName }
  TemplateNotFound { name: TemplateName }
  SkillNotFound { name: SkillId }
  AssemblyFailed { reason: String }

Lifecycle:
  - Called once per worker dispatch.
  - Must write header and prompt to the attempt's relay root.
  - Must be idempotent: same inputs produce the same outputs.
```

Claude Code implementation: `compose-prompt.sh` with `--header`, `--skills`,
`--template`, `--root`, `--out` flags.

#### `WorkerDispatcher`

Responsible for launching a worker process and tracking it to completion.

```
Request:
  prompt_path: FilePath
  relay_root: FilePath
  worker_id: WorkerId
  dispatch_identity: DispatchIdentity  (run + phase + step + attempt + worker)

Response:
  pid: Option<ProcessId>
  exit_status: ExitStatus  (code + signal)
  elapsed: Duration

Errors:
  SpawnFailed { reason: String }
  Timeout { elapsed: Duration, limit: Duration }
  ProcessCrash { signal: Signal }

Lifecycle:
  - Called once per worker dispatch.
  - Must stream or poll for process completion.
  - Must report exit status regardless of handoff presence.
  - May support cancellation for timeout enforcement.
```

Claude Code implementation: `codex exec --full-auto` piped from the prompt file.

#### `ArtifactIngestor`

Responsible for detecting, parsing, and registering handoff artifacts.

```
Request:
  relay_root: FilePath
  worker_id: WorkerId
  expected_sections: Vec<SectionName>

Response:
  handoff_path: Option<FilePath>
  parsed_handoff: ParsedHandoff
  artifacts: Vec<ArtifactRecord>

Errors:
  HandoffNotFound
  ParseError { section: SectionName, reason: String }
  MalformedMarkdown { line: usize, reason: String }

Lifecycle:
  - Called after worker process exits.
  - Must copy handoff to canonical artifacts/handoffs/ path.
  - Must write parsed-handoffs/<worker>.json.
  - Must be tolerant of partial writes (crash recovery).
```

##### Handoff Parser Contract [Amendment 10]

The parser must handle these edge cases with defined behavior:

| Condition | Behavior |
|---|---|
| Missing required heading (e.g., `### Files Changed`) | `ParseError` with the missing section name. Attempt is marked `failed`. |
| Duplicate heading | Use the last occurrence. Emit a `parse_warnings` entry. |
| Malformed markdown (no headings found) | `MalformedMarkdown` error. Attempt is marked `failed`. |
| Empty section (heading present, no content) | Accept as valid with empty value. |
| Invalid `Verdict` value (not `CLEAN`/`ISSUES FOUND`) | `ParseError`. Attempt is marked `failed`. |
| Invalid `Completion Claim` value | `ParseError`. Attempt is marked `failed`. |
| Encoding issues (non-UTF-8) | `ParseError`. Attempt is marked `failed`. |

Required parsed fields: `files_changed`, `tests_run`, `verification`, `verdict`,
`completion_claim`, `issues_found`, `next_steps`.

#### `InteractiveIO` [Amendment 3]

Responsible for presenting prompts and collecting human responses.

```
Request:
  prompt: String
  response_type: ResponseType  (approval | markdown | selection | checklist)
  options: Option<Vec<String>>  (for selection/checklist)

Response:
  response: TypedResponse
  response_path: FilePath

Errors:
  UserAborted
  InvalidResponse { expected: ResponseType, received: String }
  IOError { reason: String }

Lifecycle:
  - Called once per interactive step.
  - Must validate response against declared response_type.
  - Must write response artifact before returning.
  - Must support both CLI and future UI adapters.
```

Claude Code CLI implementation: terminal prompts with `--approve`, `--reject`,
`--response-file`, `--select`, `--checklist` flags (see Interactive Step CLI
Adapter above).

### Portable vs Claude-Code-Specific

**Portable domain (must survive adapter replacement):**

- YAML method schema and normalized definition model
- Phase and step graph
- Named input and output contracts
- Event model and state machines
- Gate definitions and evaluation
- Attempt, worker, and artifact state machines
- Output binding grammar and resolution
- Error taxonomy

**Claude-Code-specific (adapter layer):**

- `compose-prompt.sh` (→ `PromptBuilder`)
- `codex exec` (→ `WorkerDispatcher`)
- `SKILL.md` file loading
- TaskCreate / subagent-spawn semantics
- Relay prompt conventions tied to file placement
- Terminal interactive prompts (→ `InteractiveIO`)

### Lock Protocol [Amendment 7]

The `locks/run.lock` file prevents concurrent mutators.

**Acquisition scope:**

- Any operation that appends to `events.ndjson` or writes to `state.json` must
  hold the lock.
- Read-only operations (inspecting `state.json`, reading artifacts, listing
  directory structure) do NOT require the lock.

**Lock file format:**

```json
{
  "pid": 12345,
  "start_time": "2026-03-22T10:00:00Z",
  "hostname": "machine-name",
  "acquired_at": "2026-03-22T10:00:01Z"
}
```

**Timeout behavior:**

- Lock acquisition times out after 5 seconds (configurable).
- On timeout, the runner checks for stale locks before failing.

**Stale-lock recovery:**

1. Read the lock file.
2. Check if `pid` is still running on `hostname`.
3. If the process is dead (no process with that PID, or PID exists but
   `start_time` does not match), the lock is stale.
4. Remove the stale lock and re-acquire.
5. Emit a `resume_scan_started` event with `scan_reason: crash_recovery`.

**Design constraint:** The lock protocol must not prevent future extension to
cross-run coordination. The current single-run `run.lock` is scoped to the
`.method/locks/` directory. A future cross-run mutex could live at a parent
directory without conflicting.

---

## Invariants

These invariants must hold at all times. Violation of any invariant is a runner bug.

1. **Event authority.** `events.ndjson` is the sole source of truth. `state.json`
   can always be rebuilt from events plus immutable artifacts.

2. **Append-only history.** Events are never modified or deleted. Forward-only
   progression.

3. **Attempt immutability.** Once an attempt reaches a terminal state (`completed`
   or `failed`), its directory and all contents are immutable.

4. **Isolation by attempt.** No two worker attempts share mutable files. Retries
   always allocate a new attempt directory.

5. **Deterministic dispatch identity.** A worker's identity is always
   `run_id + phase_id + step_id + attempt + worker_id`. This is sufficient for
   replay and deduplication.

6. **Atomic projection.** `state.json` is written via write-then-rename. Readers
   never see a partial projection.

7. **Conservative output availability.** Downstream steps cannot consume a
   producing step's outputs until that step reaches terminal join, unless
   `early_availability: true` is explicitly declared on the output.

8. **Legal transitions only.** The runner must reject state transitions not listed
   in the entity state machines. Illegal transitions produce an error event.

9. **Lock exclusivity.** At most one mutating process holds `run.lock` at any time.
   Read-only operations are lock-free.

10. **Definition freeze.** `definition.snapshot.yaml` is written once at run start
    and never modified. Runtime logic reads from the snapshot, not from the
    original YAML file.

11. **Template explicitness.** Template selection follows the explicit precedence
    chain only. No inference or intent mapping.

12. **Binding is routing, not computation.** Output binding policies (`single`,
    `all`, `first-clean`) route data between steps. They never perform synthesis,
    summarization, or transformation. Computation belongs in `synthesis` steps.

---

## Failure Handling

### Error Taxonomy [Amendment 9]

Errors are classified into six categories. Each category has distinct handling
semantics.

| Category | Examples | Runner Behavior |
|---|---|---|
| **Method authoring error** | Invalid YAML, missing required fields, unknown action type, invalid output locator, schema version mismatch | Fail at normalization before any execution begins. Report the error with source location. |
| **Runtime adapter error** | `compose-prompt.sh` fails, `codex exec` spawn failure, timeout, filesystem permission denied | Mark the worker `failed`. If attempts remain, schedule retry with the adapter error as `retry_cause`. |
| **Worker failure** | Non-zero exit, no handoff produced, handoff with `Verdict: ISSUES FOUND` beyond allowed tolerance | Mark the attempt `failed`. Apply retry policy. Include prior issues in retry header. |
| **Parse failure** | Missing required handoff sections, malformed markdown, invalid verdict/completion values, encoding errors | Mark the attempt `failed`. Apply retry policy. Retry header includes parse diagnostics. |
| **Gate failure** | Unmet criteria (`validation_failed`), explicit rejection (`rejected`), timeout (`timed_out`) | `validation_failed`: retry if attempts remain. `rejected`/`timed_out`: mark step/phase `blocked`. |
| **Operator-unblock-required** | Attempts exhausted, gate rejected, run blocked, lock contention unresolvable | Emit `step_blocked` or equivalent. The run stops at that step. Human must intervene via `method-runner resume`. |

### Circuit Breaker

Every step has `max_attempts`. When a worker exits without a valid handoff, or when
a step ends in an unacceptable terminal state, the runner may schedule a new
attempt only if budget remains. The retry header must include prior verdicts and
issue summaries.

When budget is exhausted:

1. Emit `step_blocked` with `attempts_exhausted: true`.
2. The method stops at that step.
3. The run enters `blocked` status.
4. Human must diagnose and either resume (which allocates a fresh attempt budget)
   or abort.

### Synthesis Step Failure

If a synthesis step fails (orchestrator cannot produce the required output), the
runner:

1. Emits `synthesis_completed` with a failure indicator (or emits a
   `step_blocked` event).
2. Does not retry automatically — synthesis failures indicate an orchestrator
   problem, not a transient worker issue.
3. The run enters `blocked` status for human intervention.

---

## Open Risks

### Deferred Risk 1: Capacitor Migration Specifics

Runtime data model versioning (events, state.json, parsed handoffs), Swift
projection consistency semantics (snapshot vs stream vs hybrid), and artifact ID
portability beyond filesystem paths are real concerns but not blocking CLI v1. The
CLI implementation should:

- Use the event model and state machines defined above faithfully.
- Avoid filesystem-specific assumptions in the domain layer (use the adapter
  interfaces).
- Document any CLI-specific storage decisions that will need migration.

The Capacitor migration path remains as described in Draft C Section 11: Rust owns
canonical run state, Swift projects for UI. The adapted interfaces defined here
(PromptBuilder, WorkerDispatcher, ArtifactIngestor, InteractiveIO) are the seam
where the Capacitor adapter will replace the CLI adapter.

### Deferred Risk 2: Retention and Pruning Policy

Unbounded disk growth from retries, fanout, and long methods is a real operational
concern. v1 methods are short-lived and can be cleaned up manually. The runner
should:

- Not implement automatic pruning in v1.
- Not design data structures that make future pruning impossible (e.g., avoid
  cross-referencing by absolute path when a relative path would work).
- Document the expected growth characteristics per method run.

### Deferred Risk 3: Cross-Run Concurrency Control

Named mutexes, semaphores, and concurrency groups (similar to Argo Workflows or
GitHub Actions) are not needed for v1 where only one run executes at a time. The
single-run `run.lock` is sufficient.

The lock protocol above is designed to not prevent future extension: locks are
scoped to `.method/locks/` within a run directory. A future cross-run coordinator
could manage locks at a parent directory or in a shared store without conflicting
with per-run locks.

### Residual Ambiguity: `pipeline-execute` Depth

The `pipeline-execute` action type is defined in the schema but its implementation
details (child pipeline input/output forwarding, nested state management, failure
propagation) are deferred to the pipeline integration design. v1 should parse and
normalize `pipeline-execute` steps but may emit `step_blocked` with a "not yet
implemented" reason if encountered at runtime.

---

## Non-Goals

These are explicitly out of scope for this specification:

1. **Swift UI design.** How the Capacitor app presents method runs, checkpoints,
   or phase progression is a separate design exercise.

2. **Pipeline integration details.** How the method runner nests inside the
   `pipeline` orchestrator (child execution, input/output forwarding) is a
   separate specification.

3. **Claude-Code-specific semantics baked into the domain.** The method model is
   the product. Template names, skill file paths, and prompt assembly conventions
   are adapter concerns, not domain concepts.

4. **Template intent mapping.** Automatic inference of template from step prose is
   rejected from v1. Template selection is explicit only.

5. **`merge-digests` binding policy.** Computational fan-in via the binding layer
   is rejected. Use `synthesis` steps instead.

6. **Automatic retention and pruning.** Disk cleanup is manual in v1.

7. **Cross-run concurrency control.** v1 supports single-run execution only.

---

## Appendix: Amendment Traceability

| # | Amendment | Source Reviews | Section Updated |
|---|---|---|---|
| 1 | `synthesis` as first-class action type | Implementer, Systems, Comparative | Proposed Design > `synthesis` Action Type |
| 2 | Explicit state machines for all entities | Implementer, Systems | Proposed Design > State Machines |
| 3 | Typed adapter interface | Implementer, Systems, Comparative | Interfaces and Boundaries > Adapter Interface |
| 4 | Output binding locator grammar | Implementer | Proposed Design > Output Binding Locator Grammar |
| 5 | Gate semantics with explicit outcomes | Implementer, Systems | Proposed Design > Gate Semantics |
| 6 | Event payload schemas | Systems | Proposed Design > Event Payload Schemas |
| 7 | Lock protocol | Systems | Interfaces and Boundaries > Lock Protocol |
| 8 | Interactive CLI adapter behavior | Implementer | Proposed Design > CLI Adapter Behavior |
| 9 | Error taxonomy | Implementer, Systems | Failure Handling > Error Taxonomy |
| 10 | Handoff parser contract | Implementer | Interfaces and Boundaries > Handoff Parser Contract |
| 11 | Conservative output availability | Systems, Comparative | Proposed Design > Output Availability |
| R1 | Template intent mapping (rejected) | All three | Proposed Design > Template Selection |
| R2 | `merge-digests` binding (rejected) | Implementer, Comparative | Proposed Design > Binding Policies |
| D1 | Capacitor migration specifics (deferred) | Systems | Open Risks |
| D2 | Retention/pruning policy (deferred) | Systems | Open Risks |
| D3 | Cross-run concurrency (deferred) | Comparative | Open Risks |
