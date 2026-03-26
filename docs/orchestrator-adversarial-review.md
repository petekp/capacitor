# Orchestrator Improvement Proposals — Adversarial Review

> Reviewed: 2026-03-25
> Scope: `docs/orchestrator-improvement-proposals.md` checked against `docs/orchestrator-scratchpad.md` and the current implementation.

## Proposal 1: Status Heartbeats And Phase Advance

### Strengths

- The proposal correctly identifies the core lifecycle bug: Swift creates the run, but the executor never mutates runtime state during normal progress, so runs can sit in `created` forever.
- It also correctly rejects reusing `AdvancePhase` as a phase-start mutation. In the reducer today, `AdvancePhase` completes the current phase and activates the next one.
- The boundary choice is mostly right: checkpoint bridging and status reporting are different responsibilities, and the executor is the only place that truly knows phase, step, and worker progress.

### Weaknesses

- This solves only part of the actual problem. It addresses "run never leaves `created`" and "no live progress," but it does not address the scratchpad's bigger concern that run state may disappear across runtime-service restarts. If the model is not durable, heartbeats are just repainting a broken source of truth.
- Treating the first `Heartbeat` as the activation event is a semantic smell. A heartbeat should mean liveness. Activation is a state transition. Combining them makes idempotency, replay, and reducer behavior harder to reason about.
- The proposal skips a much simpler first fix: if the immediate symptom is "card stays STARTING forever," the coordinator could send one explicit start mutation as soon as the subprocess launches. That is much cheaper than designing a full heartbeat system.
- `resume_run` is not called out. If progress reporting only lands in `execute_run`, resumed runs will still be wrong.
- Failure policy is unspecified. If runtime-service mutation fails during a phase or step transition, does the run continue best-effort, retry, or fail closed?

### Risks

- Stale active runs become likely unless heartbeats have a TTL or there is a reaper. If the app crashes, the machine reboots, or the coordinator disappears, the run can stay `active` forever.
- Out-of-order or duplicate progress updates will be hard to make safe unless the new mutation is explicitly idempotent.
- Multi-phase runs with gates create non-trivial edge cases: paused-at-checkpoint, resumed-after-decision, and final-phase completion are not well modeled by a generic heartbeat.
- The `medium` estimate is optimistic. This touches Rust domain types, reducer logic, `method_runner.rs`, `execute_run`, `resume_run`, runtime snapshot JSON, Swift decoding, and a new test matrix.

### Verdict

**Revise.** Keep the separate reporter boundary, but split the design into explicit lifecycle mutations plus optional progress/liveness updates. Start with a deterministic "run started" mutation, then add richer progress only with stale-run recovery and resume coverage.

## Proposal 2: Working State On The Project Card

### Strengths

- The proposal is right that this is a presentation problem, not a `SessionStateManager` responsibility problem.
- It correctly notices the current inconsistency: `StatusChipsRow` already surfaces run state, while the card background still keys only off projected session state.
- A shared UI-layer resolver is a reasonable way to avoid duplicating precedence logic across the main card and dock card.

### Weaknesses

- It depends on Proposal 1 more than the document admits. If runs can stay stuck in `created`, disappear on restart, or go stale after a crash, a prettier resolver just makes the UI lie more confidently.
- Mapping `created` directly to `.working` is questionable. `created` currently means "a run record exists," not "the executor is actually doing work." If launch fails before the first real progress signal, the card will still look busy.
- The proposal assumes a single meaningful active run per project, but `activeRun(for:)` currently returns the first non-terminal run it finds. With multiple in-flight runs, the card can pick an arbitrary one.
- It does not spell out precedence for combined states like "run paused at checkpoint while delegation review exists" or "session compacting while run active."
- A simpler alternative exists if the goal is only to stop the obvious mismatch: compute an `effectiveState` inline in both card views first, then extract a shared resolver once the policy stabilizes.

### Risks

- The card can flicker or regress if run state is cleared during snapshot failures. The app currently clears `runStatesByID` after repeated runtime snapshot failures.
- Accessibility and test coverage are undercounted. This is not just a visual change; it changes labels, state announcements, and precedence behavior.
- The `small` estimate is only true if the upstream run-state model is already trustworthy. Right now it is not.

### Verdict

**Revise.** The layering is sensible, but the precedence rules need to be defined against stale `created` runs, multiple concurrent runs, and mixed run/delegation/session states.

## Proposal 3: Codex Sandbox Output Routing

### Strengths

- This is the cleanest proposal in the set. It directly addresses the actual failure mode with the smallest change.
- The local CLI surface supports it: `codex exec --help` currently exposes `--add-dir <DIR>`.
- It aligns with the existing relay contract instead of inventing a fallback import system.
- It keeps failure behavior honest: missing `last-message.txt` should still fail loudly.

### Weaknesses

- The proposal should explicitly treat repo-local fallback detection as diagnostics only. If those stale artifacts remain lying around, debugging later runs gets confusing fast.
- It assumes all write needs live under one relay root. That is true today, but the contract should say so clearly so future artifact paths do not silently escape the allowlist.
- Test scope is understated. At minimum, this change needs argv-level tests and one integration-style check that a relay-root path outside the repo is actually passed through.

### Risks

- This adds a dependency on a CLI flag owned outside the repo. That is still much safer than heuristic fallback scanning, but it should be captured in tests and metadata.
- If a future Codex version changes `--add-dir` semantics, the dispatcher will regress in a non-obvious way unless the metadata stays visible.
- Complexity is realistically `small` if the scope stays narrow.

### Verdict

**Approve.** This is the rare proposal here that directly targets the root cause with low complexity and low architectural debt.

## Proposal 4: Per-Method Timeout

### Strengths

- The proposal correctly identifies the current bottleneck: the timeout is hardcoded in `method_runner.rs`, and method definitions cannot override it.
- Authoring timeout policy in the method definition is cleaner than hiding it in a CLI flag forever.
- The existing defaults-normalization pattern makes timeout configuration a natural fit.

### Weaknesses

- It solves only dispatcher timeout, not method timeout. If prompt assembly, checkpoint waiting, or some other non-dispatch stage hangs, this proposal does nothing.
- Step-level override looks somewhat over-engineered for the current built-ins. Today the urgent bug is one built-in timing out; a method-level timeout or temporary CLI override would solve that faster.
- Resume is underspecified. If timeout is not persisted in the frozen definition and threaded through resume, resumed runs can silently fall back to the old default.
- It does not define how to represent "no timeout" or validate `0` and absurdly large values.
- The complexity is understated because this change touches the schema, normalizer, normalized model, dispatcher request, run/resume CLI, and tests.

### Risks

- If the field is modeled as `Duration` too early, serialization and snapshot plumbing get annoying. Numeric seconds are safer.
- A timeout authored per step can create inconsistent operator expectations unless the UI or logs show the effective timeout clearly.
- If this lands before the more basic output-routing fix, it improves the wrong bottleneck first.

### Verdict

**Revise.** The direction is fine, but the first cut should probably be method-level timeout with a clean resume story. Only add step-level override once there is evidence it is needed.

## Proposal 5: Idea Context In Prompts

### Strengths

- The proposal correctly identifies a real root cause: `runMethodOnIdea` discards the selected `Idea`, so the executor receives almost no task-specific context.
- It is right to keep task context out of `compose-prompt.sh` and inject it in the prompt header instead.
- Explicit task-context fields are a cleaner boundary than concatenating freeform text into authored method instructions or reloading ideas from disk later.

### Weaknesses

- As written, it only definitely solves the prompt problem. It does not fully solve the scratchpad's UI problem because persisting task context on `RunState` is described as optional. If it is optional, the card context line is still not fixed.
- The proposal does not define task-context capture semantics. Is the run supposed to snapshot title/description at launch, or reflect later edits to the idea? Those are very different models.
- Raw `idea_description` can be huge, placeholder-filled, or poorly structured. The proposal needs normalization and truncation rules or prompt size will drift unpredictably.
- There is a simpler short-term fix if the only goal is prompt correctness: inject a compact task summary into instructions now. It is not as clean, but it is much cheaper.
- The `medium` estimate is optimistic because this touches Swift launch contracts, runtime mutation/request types, Rust CLI args, prompt builder request shape, snapshot payloads, and tests.

### Risks

- Two sources of truth are likely if task context is threaded to the prompt builder but not persisted on the run snapshot.
- Retry and resume behavior becomes ambiguous unless the task context is stored with the run or frozen definition.
- Unescaped titles/descriptions can break prompt structure or introduce accidental markdown headings and code fences.

### Verdict

**Revise.** Keep the explicit task-context approach, but make persisted run-level task context part of the first version so prompts and UI share the same source of truth.

## Missing Considerations

- **Run persistence and restart recovery are missing from the proposal set.** The scratchpad explicitly calls out runs disappearing across service restarts. Until that is investigated and fixed, every UI-oriented proposal is building on a shaky model.
- **There is no stale-run cleanup story.** If run progress becomes runtime-visible, the system also needs a TTL, lease, or orphan reaper so `active` does not mean "crashed yesterday."
- **Multiple concurrent runs are not modeled.** The proposals assume one obvious active run per project or per idea, but the current system does not enforce that.
- **`IdeaQueueStatusResolver` dead code is still unaddressed.** The scratchpad calls out `methodRunning` and `methodCheckpointReady` cases that are never produced.
- **`MethodSelectorView` redesign is still unaddressed.** That item is in the scratchpad but not covered here at all.
- **Snapshot-failure behavior in Swift is not discussed.** The app clears run state after repeated runtime snapshot failures, which can make a healthy background run vanish from the UI even if the runtime model is correct.
- **Test strategy is consistently under-specified.** These proposals touch Rust reducers, hud-hook runtime service, JSON snapshot decoding, Swift view composition, and resume behavior. Most of the complexity is in cross-layer verification, not just code edits.
- **Observability is missing.** If progress, task context, and timeout behavior change, the system needs structured logs or metadata that explain what mutation was sent, what effective timeout was chosen, and why a run is shown as active.

## Recommended Priority Order

1. **Investigate and fix run persistence / restart loss first.**
   Reason: every other proposal assumes the runtime snapshot is trustworthy. Right now the scratchpad says it may not be.

2. **Proposal 3: Codex Sandbox Output Routing**
   Reason: highest impact-to-effort ratio and largely independent of the rest. It unblocks reliable E2E execution immediately.

3. **Proposal 1, but revised into explicit lifecycle mutations before generic heartbeats**
   Reason: truthful run status is the critical path for the rest of the orchestrator UX. Do not start with periodic heartbeat semantics alone.

4. **Proposal 5, with persisted normalized task context on the run**
   Reason: prompt correctness matters more than visual polish, and the same data should later power the card context line.

5. **Proposal 4, narrowed to method-level timeout first**
   Reason: important, but it is not the first blocker. Keep the first version small and resume-safe.

6. **Proposal 2: Working State On The Project Card**
   Reason: do this after run status and task context are trustworthy, or the UI will simply become more polished while still being wrong.

### Ordering And Dependencies

- **Critical path:** persistence/restart investigation -> Proposal 1 -> Proposal 2.
- **Shared-contract path:** Proposal 1 and Proposal 5 both touch runtime run shape and method-runner launch plumbing. They should be coordinated rather than landed as unrelated edits.
- **Best parallelization candidate:** Proposal 3 can run in parallel with the persistence investigation because it is mostly isolated to the worker dispatcher.
- **Late parallelization candidate:** Proposal 2 can proceed once the snapshot shape from Proposals 1 and 5 is stable.
- **Poor parallelization candidate:** Proposal 4 overlaps enough with the method-runner contract surface that it should not be developed blindly in parallel with Proposal 5.
