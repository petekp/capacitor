# Implementer Review

## Buildability Risks
- Buildable already: the spec is strong enough to implement the normalized YAML definition types, freeze `definition.snapshot.yaml`, create the `.method/` directory tree, and build an append-only `events.ndjson` plus rebuildable `state.json` projection. Those seams are concrete and can be shipped before `codex exec` integration.
- The main blocker is execution state, not storage shape. The spec names many events, but it does not define the legal state graphs for `MethodRun`, `PhaseRun`, `StepRun`, `AttemptRun`, and `WorkerRun`. Without that, replay, retry, and resume will drift.
- `events.ndjson` is described as authoritative, but the event payload schemas are missing. A Rust `enum MethodEvent` cannot be implemented safely until each event kind has required fields and replay meaning.
- Named outputs are not fully buildable as written. The spec defines output names and policies, but not the concrete locator grammar that maps a step output alias to a specific artifact path or handoff-backed record.
- `synthesis` is a structural gap. Existing method skills use it heavily, but Draft C omits it from the action enum. Either `synthesis` must be a first-class action or v1 must explicitly exclude methods that rely on it.
- Template selection is not deterministic enough to freeze into `definition.snapshot.yaml`. "Research steps default to `review`" is prose classification, not a machine-checkable rule.
- The CLI-first target is blocked by the missing interactive contract. `interactive.response_type` is defined, but there is no terminal-facing protocol for how the operator supplies approval, markdown, selections, or checklists.
- Locking is underspecified for a file-backed authoritative ledger. The lock must cover sequence assignment, event append, artifact registration, and `state.json` rewrite as one mutation boundary or the runner will be vulnerable to lost updates.

## Missing Interfaces or Contracts
- Event contract: each required event kind needs a typed payload schema. Minimum missing fields include retry cause, exit status or signal, gate identity, recoverability, bound output name, and interactive response metadata.
- Runtime state contract: the spec needs explicit status enums and legal transitions for runs, phases, steps, attempts, and workers. This is more important than more prose examples.
- Adapter port contract: the portable domain is clearly intended to depend on ports, but those ports are still only described informally. The spec should define request and response DTOs for prompt building, worker dispatch, worker monitoring, handoff ingestion, and interactive I/O.
- Output binding contract: `step.outputs` and `method.outputs.*.from` need a real locator grammar. Today it is impossible to tell whether `from` refers to the handoff markdown itself, a file named in the handoff, a parsed section, or a separate artifact manifest.
- Handoff parser contract: required headings are named, but parser behavior is not. The spec should define how to handle missing headings, duplicate headings, malformed markdown, empty sections, and invalid verdict or completion values.
- Gate contract: gate types are listed, but their operands are not. For example, `handoff_verdict` must say whether it evaluates a named worker, the step aggregate, or every worker in the attempt.
- Interactive artifact contract: approval, selection, checklist, and markdown responses need concrete on-disk formats so `interactive_response_recorded` can be validated and replayed.
- Lock manager contract: `run.lock` needs acquisition scope, timeout behavior, stale-lock recovery, and a rule for whether read-only status commands can run without the mutating lock.
- Error taxonomy: the runner needs separate categories for method authoring errors, runtime adapter errors, worker failures, parse failures, gate failures, and operator-unblock-required states. Without that, retry and blocking behavior cannot be consistent.

## Testability Concerns
- The system is testable incrementally if the ports are made explicit. The existing separation between definition types and runtime types is the right seam for unit tests and adapter fakes.
- Replay tests cannot be written until event payload schemas are complete. "Event-sourced" only helps if replay from `events.ndjson` deterministically rebuilds the same run state every time.
- Resume tests are blocked by missing definitions for "worker still active", "handoff exists but is incomplete", and "exit without handoff". The current spec leaves too much of that policy implicit.
- Template intent mapping is currently hard to test because it depends on prose interpretation. Two runner versions could normalize the same YAML to different templates without any schema change.
- Interactive steps are not unit-testable until CLI input is abstracted behind an adapter. If the first implementation reads stdin directly, the CLI runner will be harder to automate and harder to port into Capacitor later.
- Parallel output binding needs table-driven tests before implementation. The missing cases are exactly the dangerous ones: duplicate aliases, one clean worker plus one partial worker, and differing timing between output registration and downstream consumption.
- Handoff parsing should be tested against fixtures, not inferred from live agent behavior. The relay protocol is close enough to support strict parser fixtures now, but named outputs still need a stronger machine-readable contract.
- The current adapter boundary supports incremental subprocess integration. `codex exec --help` already exposes a stable shell surface for spawn, exit observation, JSON mode, and `--output-last-message`, so the spec can support fake and real dispatchers without a big-bang implementation.

## Sequencing Hazards
1. Freeze the normalized definition model and validation rules first. If YAML normalization is still moving while runtime state is built, every later snapshot or replay test will churn.
2. Define runtime state machines and event payload schemas before implementing dispatch. Resume and retry semantics depend on these types, not the other way around.
3. Define adapter ports before the CLI runner. Otherwise the first Rust implementation will leak `compose-prompt.sh` and `codex exec` details into the core domain.
4. Build event append, projection, and replay under a real lock boundary before adding parallelism. File-backed event sourcing is fragile if locking is treated as an afterthought.
5. Ship a serial, single-worker `dispatch` slice with explicit template selection before adding inference, fanout, or parallel phases. That gives a testable vertical slice without forcing big-bang integration.
6. Add named output binding before adding complex multi-step methods. If output resolution comes later, step transitions will accidentally bake in handoff-specific assumptions that are hard to unwind.
7. Add retry and resume only after output registration is stable. Retries change causal history, so they should sit on top of a settled artifact model.
8. Add interactive steps before implementing gate recovery paths that depend on human evidence. Otherwise gate semantics will silently absorb UI behavior.
9. Add multi-worker fanout and phase-level parallelism after single-worker dispatch, handoff parsing, and output binding are proven. The spec is much clearer on isolation than on joins.
10. Add `pipeline-execute` last. It introduces another authoritative runtime with its own status model and should not be the first adapter seam the runner has to carry.

## Required Clarifications
- Is `synthesis` a first-class action in v1, or are v1 methods restricted to `dispatch`, `interactive`, and `pipeline-execute` with a documented lowering strategy for synthesis?
- What are the exact status enums and legal transitions for `MethodRun`, `PhaseRun`, `StepRun`, `AttemptRun`, and `WorkerRun`?
- What is the payload schema for every required event kind, and which events must be idempotent on resume?
- What exact port boundary does the CLI adapter implement for prompt building, worker dispatch, process monitoring, handoff parsing, and interactive input?
- What is the locator grammar for `outputs` and `from`? The current prose does not determine how a named output becomes a concrete artifact record.
- Are named outputs available immediately after registration, after step join, or only after phase join? Different sections currently imply different answers.
- When a gate fails, what is the recovery path for each gate type: automatic retry, interactive unblock, manual reopen, or terminal failure?
- How does CLI interactive mode work operationally? For example, does `method-runner resume` accept `--approve`, `--select`, or `--response-file`, or is a long-running interactive process required?
- What lock implementation is required, what operations hold the lock, and how is stale-lock recovery handled?
- Is template selection required to be explicit in v1? If not, what machine-readable field drives intent mapping so normalization stays deterministic?
