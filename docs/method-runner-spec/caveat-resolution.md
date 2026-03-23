# Caveat Resolution

## Accepted Caveats

### Must-Amend (all three reviews converge)

1. **Add `synthesis` as a first-class action type.** The orchestrator's own computation (reading prior artifacts, writing new artifacts directly) must be a domain concept, not an implicit convention. Model it like Temporal workflow logic: consumes named inputs, produces named outputs, no worker dispatch. This is the single highest-priority amendment.

2. **Define explicit state machines for all runtime entities.** Runs, phases, steps, attempts, and workers each need a typed status enum and a legal-transitions graph. Without these, replay from `events.ndjson` is non-deterministic. Minimum states for attempts: `created → dispatching → running → handoff_detected → handoff_parsed → output_bound → completed | failed`. Include the run-level, phase-level, and step-level machines too.

3. **Define typed adapter interface.** The portable domain must own the interface semantics for `PromptBuilder`, `WorkerDispatcher`, `ArtifactIngestor`, and `InteractiveIO`. Define request/response DTOs, error contracts, and lifecycle callbacks. The Claude Code adapter is the first implementation, not the specification.

4. **Define output binding locator grammar.** `outputs.*.from` needs a concrete syntax: `<phase>.<step>.<output>` or `<phase>.<step>.<worker>.<output>`. Define resolution order, error on missing, and how parallel worker outputs map to step-level outputs.

5. **Specify gate semantics with explicit outcomes.** Split gate results into: `waiting`, `approved`, `rejected`, `timed_out`, `validation_failed`. Define which gate types support which outcomes. Define who can satisfy each gate type and how reevaluation is triggered.

6. **Define event payload schemas.** Each of the ~20 required event kinds needs a typed payload with required fields. Minimum: retry cause for `step_retry_scheduled`, exit status for `worker_process_exited`, bound output name for `output_bound`, gate identity for `gate_waiting`/`gate_passed`/`gate_failed`, response type for `interactive_response_recorded`.

7. **Specify lock protocol for file-backed event sourcing.** Define: acquisition scope (which operations hold the lock), timeout behavior, stale-lock recovery (PID + start-time verification), and whether read-only operations can run without the mutating lock.

8. **Specify interactive step CLI adapter behavior.** Define the terminal protocol: does `method-runner resume` accept `--approve`, `--select`, or `--response-file`? How does the CLI adapter present prompts and collect responses for each `response_type` (approval, markdown, selection, checklist)?

### Additional amendments from review convergence

9. **Error taxonomy.** Separate categories: method authoring errors (invalid YAML, missing fields), runtime adapter errors (spawn failure, timeout), worker failures (bad handoff, non-zero exit), parse failures (malformed handoff), gate failures (unmet criteria), and operator-unblock-required states.

10. **Handoff parser contract.** Define behavior for missing headings, duplicate headings, malformed markdown, empty sections, and invalid verdict/completion values.

11. **Make output availability conservative by default.** A downstream step can only consume a producing step's outputs after that step reaches its terminal join. Early consumption is an explicit opt-in, not implicit behavior.

## Rejected Caveats

1. **Template intent mapping is rejected from v1.** "Runner intent mapping" (inferring `review` vs `implement` from prose) is removed. Template selection in v1 must be explicit: `dispatch.template`, `step.template`, or `method.defaults.template`. If none is specified, the runner uses a single default (e.g., `implement`). Rationale: inference creates non-determinism under replay and migration. All three reviews flagged this independently.

2. **`merge-digests` output binding policy is rejected from v1.** Hiding LLM synthesis inside binding resolution is architecturally wrong — it conflates data routing with computation. If fan-in synthesis is needed, it must be a real `synthesis` step that consumes worker outputs and produces a merged artifact. The v1 binding policies are: `single`, `all`, and `first-clean` (with explicit ordering rule: definition order, not wall-clock order).

## Deferred Risks

1. **Capacitor migration specifics.** Runtime data model versioning (events, state.json, parsed handoffs), Swift projection consistency semantics (snapshot vs stream vs hybrid), artifact ID portability beyond filesystem paths. These are real but not blocking CLI v1. The amended spec should preserve the Capacitor migration section as guidance but not require implementation-grade precision there.

2. **Retention and pruning policy.** Unbounded disk growth from retries, fanout, and long methods is a real operational concern. Deferred because v1 methods are short-lived and can be cleaned up manually. The amended spec should note this as a known gap.

3. **Cross-run concurrency control.** Named mutexes, semaphores, concurrency groups (Argo/GitHub-style). Single-run `run.lock` is sufficient for v1. The amended spec should avoid designing the lock in a way that prevents future extension to cross-run coordination.

## Priority Amendments

Ordered by implementation dependency (from the implementer review's sequencing hazards):

1. Normalized definition model + `synthesis` action type
2. Runtime state machines + event payload schemas
3. Adapter port contracts (typed interfaces)
4. Lock protocol
5. Output binding grammar + conservative availability
6. Gate semantics with explicit outcomes
7. Interactive CLI adapter specification
8. Error taxonomy + handoff parser contract

## Scope Cuts

- Template intent mapping → removed, explicit-only
- `merge-digests` binding → removed, use `synthesis` steps
- `pipeline-execute` details → present in schema but implementation deferred to last
- Capacitor-specific migration details → guidance-only, not implementation-grade
