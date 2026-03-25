# Spec Brief

## Source Document
`.relay/handoffs/handoff-draft-c.md` — "Method Runner System Requirements (Draft C)", 586 lines. Covers YAML method definition schema, `.method/` directory structure, event-sourced state management, runner lifecycle, dispatch/adapter contracts, gate evaluation, resume/retry logic, and error handling. Written as a requirements spec for a declarative workflow engine.

## Intended Outcome
Harden Draft C enough to start building the **CLI method runner** — local execution using `compose-prompt.sh` and `codex exec` as the first adapter. The hardened spec must also provide enough clarity on the Capacitor runtime migration path (event-sourced state → runtime service integration) that the CLI implementation won't require a structural rewrite when ported.

## Primary Audience
The implementer (user + coding agents) who will build the method runner. The doc must be precise enough for a Codex worker to implement a slice without re-reading the entire spec or guessing at edge cases.

## Non-Goals
- **Swift UI design** — how the Capacitor app presents method runs, checkpoints, or phase progression is a separate design exercise
- **Pipeline integration details** — how the method runner nests inside the `pipeline` orchestrator (child execution, input/output forwarding) is deferred
- **Claude Code-specific semantics** — the method model is the product; Claude Code skill execution is only the first adapter

## Open Questions
1. What is the exact state machine for step attempts? (Created → Dispatched → ... → Terminal) The draft describes events but doesn't draw the complete state graph.
2. How does `interactive` step handling work in CLI mode vs future Capacitor mode? The draft mentions `interactive.prompt` and `interactive.response_type` but doesn't specify the CLI adapter behavior.
3. What happens when a phase gate fails? The draft mentions gates but the retry/reopen semantics for phase-level failures are underspecified.
4. How do named output bindings actually resolve across steps? The draft says bindings "should resolve to structured artifact references" but the resolution algorithm is implicit.
5. Is `synthesis` a valid step action type? The existing method skills (research-to-implementation, flow-audit-and-repair, etc.) rely on `synthesis` steps where the orchestrator writes artifacts directly, but Draft C only lists `dispatch`, `interactive`, and `pipeline-execute`.

## Decisions Required Before Build
1. **State machine boundaries** — exactly which state transitions are legal for runs, phases, steps, and attempts, and how retry/resume interacts with each level
2. **Adapter contract shape** — how `compose-prompt.sh`, `codex exec`, and future adapters plug into the runner without leaking into the domain model (interface definition, not just prose description)
3. **Artifact/output resolution** — how named output bindings resolve across steps, including: binding syntax, resolution order, error on missing binding, and how parallel worker outputs merge into a single step output
