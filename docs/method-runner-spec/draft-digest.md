# Draft Digest

## Core Claims

1. **The method model is the product.** Claude Code is just the first execution adapter. The domain model (phases, steps, gates, named outputs) must survive replacement of every adapter-specific piece.

2. **Event-sourced state is authoritative.** `events.ndjson` is the canonical truth. `state.json` is a rebuildable projection. This gives replay, auditability, and a clean migration path to Capacitor's runtime service.

3. **Attempt isolation is the safety guarantee.** Every dispatch attempt gets its own immutable filesystem boundary (`steps/<phase>/<step>/attempts/<n>/relay/workers/<worker>/`). Retries never mutate previous attempt directories. This makes resume, retry, and fanout safe.

4. **Named outputs replace conversational memory.** Steps exchange named artifacts with explicit producer/consumer relationships, not raw markdown or conversational context. Output bindings resolve to structured artifact records.

5. **Three execution environments.** The system must work in CLI mode today, as a `pipeline` child in the near term, and as a first-class Capacitor runtime object later.

## Proposed Mechanism

A **YAML method definition** describes phases, steps, inputs, outputs, and gates declaratively. The **runner** normalizes this into an in-memory definition, then executes step-by-step:

- **Dispatch steps** → runner writes prompt headers, runs `compose-prompt.sh`, launches `codex exec`, watches for handoffs, parses structured fields, binds outputs
- **Interactive steps** → runner writes an interaction request, pauses for human input, records the response as a typed artifact
- **Pipeline-execute steps** → runner spawns a child pipeline run

State flows: YAML → normalized definition → events.ndjson (append-only) → state.json (atomic projection). The `.method/` directory structure isolates everything by attempt and worker.

## Dependencies

- `compose-prompt.sh` — prompt assembly (header + skills + template)
- `codex exec` — worker dispatch (full-auto mode)
- Existing relay conventions — handoff format with required sections (Files Changed, Tests Run, Completion Claim, etc.)
- `SKILL.md` files — skill content loaded by `compose-prompt.sh`
- Template files — implement, review, ship-review, converge templates
- `pipeline` skill — for `pipeline-execute` step hosting

## Assumptions

1. The YAML schema (Section 2) is stable enough to freeze at run start via `definition.snapshot.yaml`
2. The existing handoff section format (Files Changed, Tests Run, etc.) is the interop contract between runner and workers
3. `codex exec` is the only dispatch adapter needed initially; Capacitor adapter comes later
4. `compose-prompt.sh` can handle the `.method/` relay root paths without modification (the `--root` flag does `{relay_root}` substitution)
5. Phase execution order is strictly sequential unless `execution: parallel` is declared
6. Workers within a step are the unit of parallelism, not steps across phases
7. The event model is sufficient for both CLI file-based storage and future Capacitor runtime service storage

## Ambiguities

1. **`synthesis` action type is missing.** Draft C lists `dispatch`, `interactive`, and `pipeline-execute` as step action types. But all existing method skills (research-to-implementation, flow-audit-and-repair, decision-pressure-loop, spec-hardening) rely heavily on `synthesis` steps where the orchestrator writes artifacts directly without dispatching a worker. This is the single largest gap between the spec and current practice.

2. **Step attempt state machine is incomplete.** The draft describes events but never draws the complete state graph for attempts. What are the valid transitions? Can an attempt go from `dispatched` back to `pending`? What states exist between dispatch and terminal?

3. **Phase gate failure semantics are underspecified.** Gates can fail, but what happens next? Does the runner retry the phase? Block and wait for human intervention? The draft says `waiting_for_gate` or `blocked` but doesn't define when each applies or how to unblock.

4. **Interactive step CLI adapter behavior is unspecified.** How does `interactive.response_type: approval` work in CLI mode? Does the runner print a prompt and wait for stdin? Write a file and poll? The Capacitor path is clearer (UI surfaces the request) but the CLI path — which is what we're building first — is hand-waved.

5. **Output binding resolution order for parallel workers is implicit.** With `completion_policy: all_complete` and 3 workers, what happens if worker 2 finishes first and produces output `foo`? Is `foo` immediately available to other steps, or only after all workers complete? The draft says "downstream phases may not consume them until the producing step or phase reaches terminal join" but this conflicts with potential within-phase dependencies.

6. **Template selection "runner intent mapping" is vague.** The draft provides prose guidance ("research steps default to `review`") but no machine-checkable rule. How does the runner classify a step as "research" vs "implementation" when the YAML doesn't say?

7. **Lock semantics are mentioned but not specified.** `run.lock` is described as preventing concurrent mutators, but the acquisition/release protocol, timeout behavior, and stale-lock recovery are absent.

8. **Method-level `inputs` and `outputs` vs step-level `inputs`/`outputs` naming collision.** Both exist in the schema but their relationship (how method inputs flow to step inputs, how step outputs flow to method outputs) is described only in prose.

## Missing Artifacts

1. **State machine diagram** — a visual graph of legal transitions for runs, phases, steps, and attempts
2. **Output binding resolution algorithm** — pseudocode or decision tree for how `from: phase.step.output` resolves through attempts, workers, and completion policies
3. **Adapter interface definition** — a trait/protocol definition for `PromptBuilder + WorkerDispatcher + ArtifactIngestor` rather than just prose descriptions
4. **Error taxonomy** — which errors are runner errors (missing inputs, lock contention) vs worker errors (bad handoff, timeout) vs user errors (invalid YAML, missing approval)
5. **CLI adapter specification** — concrete behavior for interactive steps, lock management, and resume in a terminal environment
