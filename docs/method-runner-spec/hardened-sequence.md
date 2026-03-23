# Hardened Action Sequence

## Missing Prerequisites

1. The transition plan needs an explicit boundary freeze before any worker starts coding. The current run kernel is checkpoint-centric, generates runtime phase ids, and is already projected through `AppSnapshot.runs`, so the tracer bullet must start in a new `method_runner` subsystem rather than extending `run_types.rs` or `RunState`.
2. The execution surface is not frozen yet. A worker still needs the canonical CLI verbs, the first-success acceptance command, the run-root and `.method/` layout, and the canonical handoff heading list before Step 5 is safe.
3. The YAML home is unresolved. Worker A assumes crate-local test fixtures; Worker B assumes a repo-level method library plus separate fixtures. That needs to be settled before the bootstrap YAMLs land, or `spec-hardening.yaml` will become both product artifact and test data by accident.
4. The adapter gate is underspecified. "Probe `compose-prompt.sh` and `codex exec`" is not enough; the operator needs a pass/block/waiver rule for cases where shell-level contracts are green but live `codex exec` is not.
5. The skeleton step is missing required day-zero scaffolding: CLI entrypoint, Cargo dependency additions, test fixture/support directories, and a path-builder seam. Without those, Step 5 is not actually self-contained.

## Ordering Issues

1. Creating YAML fixtures before freezing boundary, CLI, and filesystem contracts is unsafe. The fixtures will encode path and scope assumptions, so they should land after the boundary note, not before it.
2. The module skeleton cannot be "8 modules only." The tracer bullet depends on a real bin target, dependency declarations, and a test harness. Those belong in the scaffold step, not in the tracer-bullet step.
3. "Tracer bullet — Slices 1-6 happy path" is safe only if it is framed as a vertical proof that spans Slice 1-6 obligations for one path, not as completion of Slices 1-6. Otherwise Step 7 hides unfinished test matrices.
4. "Fan out" is too vague to dispatch. It needs explicit post-proof batches and ownership boundaries, especially because resume, runtime-service bridging, and Swift projection are not parallel-safe with the core domain work.

## Decision Points

| Decision | Needed By | Recommendation | Information the Operator Needs |
|---|---|---|---|
| New subsystem vs extending the current run kernel | Before YAML authoring | Create `core/capacitor-core/src/method_runner/`; do not edit `run_types.rs`, `AppSnapshot.runs`, runtime service, or Swift during the tracer bullet | `run_types.rs` is phase/checkpoint oriented and `AppSnapshot.runs` already exposes it to app consumers |
| YAML location model | Before Step 3 | Use `methods/library/` for author-owned methods and `methods/fixtures/` for proof fixtures; let Rust tests read from there or mirror them deliberately | This keeps `spec-hardening.yaml` as a real library artifact instead of burying it under crate tests |
| Adapter gate policy | Before Step 4 closes | Require shell-contract probes to pass; allow core coding to continue with a recorded waiver if live `codex exec` is red, but do not declare Step 6 complete without satisfying the gate chosen here | `compose-prompt.sh` is grounded, but live worker dispatch may still fail for environment reasons outside runner code |
| First-success contract | Before Step 5 | Freeze `method-runner normalize|run|resume` and a single acceptance command for `minimal-dispatch.yaml` | Every worker needs the same target when they say "the tracer bullet works" |

## Dispatchability Assessment

| Synthesized Step | Dispatchable As Written? | Why / What Must Change |
|---|---|---|
| 1. Commit artifacts | Partial | Needs the exact artifact set, destination branch, and the rule that code work starts only from that committed baseline |
| 2. Create YAML fixtures | Partial | Needs the YAML location decision plus a per-fixture purpose and expected consumer test |
| 3. Adapter probes | Partial | Needs a fixed probe checklist and an explicit gate outcome: green, waived, or blocked |
| 4. Rust module skeleton | No | Too underspecified; must name files, bin target, deps, fixture dirs, support dirs, and "no business logic yet" scope |
| 5. Tracer bullet | Partial | Needs exact allowed scope, out-of-scope list, and the acceptance command that proves success |
| 6. Action-agnostic proof | Partial | Dispatchable only if the done criteria forbid redesigning the event, lock, projection, or definition-freeze core |
| 7. Fan out | No | Must be replaced with explicit batches keyed to the implementation-plan slices |

## Hardened Sequence (with exit criteria)

### 1. Commit the hardened baseline on a dedicated branch

**Scope**

- Commit the hardened artifact chain that code is allowed to build from: `amended-spec.md`, `execution-packet.md`, `implementation-plan.md`, this hardened sequence, and any short operator note captured in Step 2.

**Exit criteria**

- A dedicated branch exists for method-runner work.
- The hardened artifact chain is committed together so workers share one frozen baseline.
- The branch or handoff names the accepted first-success milestone: one serial dispatch step leaves a correct `.method/` tree.

### 2. Freeze the build boundary and first-success contract

**Scope**

- Record that the tracer bullet lives in a new Rust subsystem at `core/capacitor-core/src/method_runner/`.
- Record that `core/capacitor-core/src/domain/run_types.rs`, `core/capacitor-core/src/domain/types.rs` `AppSnapshot.runs`, runtime-service surfaces, and Swift projection are out of scope until after the architecture-proof step.
- Freeze the day-zero CLI shape: `method-runner normalize`, `method-runner run`, `method-runner resume`.
- Freeze the run-root / `.method/` ownership model and the canonical first-success acceptance command.
- Freeze the canonical handoff headings shared by prompt templates and the parser.

**Exit criteria**

- There is one short note in the branch or phase folder that states the subsystem boundary, out-of-scope surfaces, CLI verbs, YAML locations, and first-success command.
- No unresolved ambiguity remains about where YAMLs live or what command proves the tracer bullet.

### 3. Land the bootstrap YAML corpus in final locations

**Scope**

- Create `methods/fixtures/minimal-dispatch.yaml`.
- Create `methods/library/spec-hardening.yaml` as a v0 real method, not a toy.
- Create `methods/fixtures/pipeline-blocked.yaml`.
- Tie each file to the exact obligation it exists to protect.

**Exit criteria**

- `minimal-dispatch.yaml` exercises one serial phase, one dispatch step, one worker, and one required output.
- `spec-hardening.yaml` v0 uses real phase and step ids from the hardened method and includes at least one dispatch step, one synthesis step, one interactive step, and method outputs.
- `pipeline-blocked.yaml` is schema-valid and intentionally proves the v1 parse-only / runtime-block boundary.
- Each YAML has a named planned consumer: normalization golden test, tracer-bullet acceptance run, or later runtime-block regression.

### 4. Run adapter preflight and freeze the gate decision

**Scope**

- Validate the shell contract around `scripts/relay/compose-prompt.sh`, including parent-directory expectations, relay-root substitution, idempotence, and failure modes.
- Validate the `codex exec` boundary enough to classify environment readiness, timeout ownership, exit-status capture, `-o` behavior, and live handoff creation.
- Record whether the branch is green, waived-for-core-only work, or blocked on live adapter health.

**Exit criteria**

- A probe report exists with explicit results for: prompt composition, parent-dir creation ownership, prompt idempotence, handoff path expectation, exit-status capture, timeout ownership, and live preflight status.
- At least one known-good or known-bad command line is recorded for both `compose-prompt.sh` and `codex exec`.
- The operator decision is explicit: Step 5 may proceed, and Step 6 may or may not be closed, under the chosen gate.

### 5. Land the Rust scaffold, CLI shell, and test harness

**Scope**

- Add `core/capacitor-core/src/method_runner/` with the agreed module layout.
- Add `core/capacitor-core/src/bin/method_runner.rs`.
- Add the minimum Cargo dependencies needed for the first slice, plus test fixture and support directories.
- Add the internal path-builder seam that owns `.method/` paths.
- Keep this step structural: no attempt to finish runner behavior yet.

**Exit criteria**

- The new module tree, bin target, test fixture roots, and support roots exist in the repo.
- `Cargo.toml` includes the minimum day-zero dependencies for YAML and adapter-facing error handling.
- The crate compiles with the new bin target and module exports in place.
- A worker can now take Step 6 without inventing filesystem layout, CLI shape, or test harness structure.

### 6. Build the tracer bullet across the Slice 1-6 seam

**Scope**

- Implement one vertical proof that spans normalization, definition freeze, minimal event append/projection, lock ownership, one dispatch attempt, handoff ingestion, and output binding.
- Restrict the happy path to one serial phase, one dispatch step, one implicit `primary` worker, no retries, no gates, no parallelism, and no runtime-service or Swift integration.
- Treat non-dispatch actions according to the frozen contract: parse where required and block where v1 says to block.

**Exit criteria**

- The acceptance command frozen in Step 2 produces a complete `.method/` tree for `minimal-dispatch.yaml`.
- The run writes, at minimum, `definition.snapshot.yaml`, per-step `step.json`, lock state, `events.ndjson`, `state.json`, prompt artifacts, attempt artifacts, canonical handoff copy, and output bindings.
- Replay from `events.ndjson` reproduces `state.json`.
- The tracer bullet closes under the adapter gate chosen in Step 4. If Step 4 recorded a waiver, this step is only conditionally complete until the live gate is later satisfied.
- No code in this step requires mutating the existing run kernel or Swift/runtime-service consumers.

### 7. Prove the core is action-agnostic

**Scope**

- Add one `synthesis` path and one `interactive` path on top of the same definition-freeze, event, lock, projection, and artifact core.
- Use this step to prove that action diversity does not force a second authority model.

**Exit criteria**

- One synthesis fixture and one interactive fixture execute on the same core runner.
- The core authority seams from Step 6 remain intact: no alternate persistence path, no alternate state store, no redefinition of dispatch identity.
- `pipeline-execute` still normalizes and blocks with the agreed v1 reason instead of sprouting partial semantics.

### 8. Fan out in controlled post-proof batches

**Scope**

- Turn the remaining work into explicit batches instead of a generic "fan out."
- Batch A: close the unfinished Slice 1-6 test matrices and edge cases that the tracer bullet intentionally skipped.
- Batch B: finish full Slice 7 and Slice 8 behavior in parallel only after Batch A stops moving the shared core.
- Batch C: keep Slice 9 resume/recovery and Slice 10 runtime-service bridge on the main thread.
- Batch D: do Slice 11 and Slice 12 last, after the bridge exists and the core semantics are stable.

**Exit criteria**

- Each remaining batch has an owner, exact file scope, and the tests that define done.
- No batch mixes core-domain work with Swift/runtime-service projection work before Slice 10.
- A Codex worker can be assigned any one batch without re-opening earlier decisions.

## Risk Watch List

1. **Run-kernel contamination:** the fastest-looking path is to extend `RunState`; that is also the most likely rewrite trap.
2. **Adapter false positives:** "binary spawned" is weaker than "worker completed and handoff was ingested." Keep those separate in status and tests.
3. **Fixture drift toward toys:** if `spec-hardening.yaml` is weak, the normalizer will optimize for the happy path and surprise you later.
4. **Filesystem layout becoming the domain model:** keep typed ids and artifact records inside Rust; `.method/` is a serialization boundary, not the core model.
5. **Parser/template drift:** the handoff parser and prompt templates must share one canonical heading list or Step 6 will produce fake successes.
6. **Tracer-bullet overclaim:** a vertical proof is not completion of Slices 1-6. Preserve that distinction in branch notes and handoffs.
