# Critical Review: Modular Development Pipeline Design

Grounding for this review:

- Read `AGENTS.md`
- Read the current relay machinery:
  - `scripts/relay/update-batch.sh`
  - `scripts/relay/compose-prompt.sh`
  - `~/.claude/skills/manage-codex/SKILL.md`
  - `~/.claude/skills/manage-codex/references/relay-protocol.md`
- Reproduced one concrete path-coupling failure with a disposable temp fixture:
  pointing `update-batch.sh --batch` at a phase-local `batch.json` still wrote the
  ledger to `/private/tmp/.relay/events.ndjson`, not beside the batch file.

## Weaknesses

### 1. Phase-local execute is not actually phase-local
- Severity: Critical
- Concrete failure scenario:
  The design says `manage-codex` moves inside `.pipeline/phases/{execute_phase_id}/`.
  But the current implementation is coupled to `.relay/` in multiple places:
  `scripts/relay/update-batch.sh:43-45` hard-codes `.relay/batch.json` and
  `.relay/archive`, then derives `events.ndjson` from that archive root at
  `scripts/relay/update-batch.sh:132-134`. `scripts/relay/compose-prompt.sh`
  examples still assume `.relay/*`, and the manage-codex skill plus templates
  instruct workers to read and write `.relay/handoff-*` and
  `.relay/review-findings-*`. The result is split state: `batch.json` moves, but
  events, prompts, handoffs, and review artifacts do not.
- Proposed fix:
  Introduce a first-class `pipeline_root` or `execution_root` and thread it
  through every script, template, and prompt contract. Do not add a narrow
  `--state` flag. Add one root flag, derive all artifact paths from it, and
  record that root in state so resume logic never guesses.

### 2. The design does not define an authoritative owner for live state
- Severity: Critical
- Concrete failure scenario:
  `state.json` is rebuildable, `events.ndjson` is append-only, and execute has
  its own batch/event loop. But the design never says which source is
  authoritative while work is actively running. If the execute phase is in
  flight and the orchestrator resumes from cold state files after a crash, it
  can resurrect stale assumptions, duplicate dispatch, or mark the wrong phase
  current. This is exactly the kind of split-brain problem your own repo has
  already identified in orchestration work: files are great artifacts, but poor
  live authorities.
- Proposed fix:
  Write down an authority matrix. Example:
  filesystem = durable artifacts and audit trail;
  live subprocess/runtime = current execution truth;
  `state.json` = derived index only.
  Resume should reconcile against live execution when present, not blindly trust
  the last snapshot.

### 3. The phase-slot abstraction is too soft to be dependable
- Severity: High
- Concrete failure scenario:
  `skill`, `mode`, `input_contract`, `output_contract`, and `gate` sound
  modular, but `skill` is not a stable execution interface. Skills are prompt
  guidance, not versioned adapters. If `solution-explorer` or `manage-codex`
  changes its artifact naming, wording, or required context, the pipeline has no
  compatibility layer. The phase “contract” exists only as intent.
- Proposed fix:
  Split phase identity from phase implementation:
  `kind = align`, `adapter = scripts/pipeline/run-align.sh`, `skill = solution-explorer`.
  The adapter owns artifact creation, schema validation, and exit semantics.
  Skills can still shape reasoning, but they should not be the machine contract.

### 4. The align -> execute gate is strong on syntax and weak on semantic closure
- Severity: High
- Concrete failure scenario:
  A packet can satisfy `constraints.json` schema, explicit `allowed_paths`,
  non-empty `verification_commands`, and zero open questions, yet still leave
  major hidden freedom: algorithm choice, migration ordering, failure handling,
  rollback expectations, or ownership boundaries. Two strong workers can still
  produce materially different systems while the machine gate passes, because the
  current checks mostly validate presence and wording hygiene.
- Proposed fix:
  Add semantic closure fields, not just structural ones:
  `decisions[]`, `prohibited_alternatives[]`, `invariants[]`,
  `acceptance_examples[]`, and `change_budget`.
  Better yet, require executable examples or contract tests when the work
  touches behavior, not just prose constraints.

### 5. Pointer-only handoffs are not durable evidence
- Severity: High
- Concrete failure scenario:
  `resume.md` or `decision-log.md` points at a repo file or exploratory artifact
  by path. Later, another phase or a human edits that file. On cold resume, the
  pipeline reads the new content while believing it is reading historical phase
  context. Auditability becomes fictional because the pointer no longer resolves
  to the original evidence.
- Proposed fix:
  Make artifacts immutable once referenced by a completed phase. Pointers should
  include a content hash, git commit, or copied immutable artifact path. “Path
  only” is fine for navigation, but not sufficient for historical truth.

### 6. Forward-only epochs supersede too coarsely
- Severity: High
- Concrete failure scenario:
  Execution reveals only one align decision was wrong. The design increments the
  epoch, supersedes prior phases, and inserts a new align phase. Now readers must
  infer which old constraints still hold and which are dead. Over time this turns
  into archaeology: active truth is smeared across old outputs, supersession
  pointers, and new deltas.
- Proposed fix:
  Make decisions or constraints first-class addressable records with explicit
  supersession. Epochs can still exist, but the active constraint set should be a
  deterministic materialized view, not something humans reconstruct from prose.

### 7. `state.json < 4KB` conflicts with the proposed schema shape
- Severity: Medium
- Concrete failure scenario:
  The proposed `state.json` already includes mission metadata, repo metadata,
  resume info, and an array of phase records with lineage, constraint deltas,
  gate results, and artifact pointers. Add a few epochs and N phases and the
  4KB target is gone immediately. Either the limit will be ignored, or the file
  will quietly stop carrying the information the design claims it carries.
- Proposed fix:
  Keep `state.json` tiny by making it an index:
  current phase, active epoch, effective mission version, active constraint set
  pointer, and latest resume pointer.
  Put per-phase summaries into `phases/*/phase.json` and reconstruct history from
  the ledger when needed.

### 8. The fast-path bypass heuristic will misclassify risky work
- Severity: Medium
- Concrete failure scenario:
  A one-file change inside a reducer, state machine, or public command handler
  may still require architecture judgment. Under the proposed bypass, “<=2 files”
  and “<=1 subsystem” can skip align even when the change crosses a persistence,
  concurrency, or API boundary. That is a false economy and the exact kind of
  thing that produces subtle regressions.
- Proposed fix:
  Replace file-count heuristics with a risk classifier:
  persistence touched, public API touched, concurrency touched, runtime boundary
  touched, migration touched, ambiguity unresolved.
  File count can be one weak signal, not the decider.

### 9. Execute is modeled as one phase, but it is really a nested workflow
- Severity: Medium
- Concrete failure scenario:
  `execute` contains its own loop: implement, review, rework, converge. Flattening
  that into one phase means top-level state cannot reason about meaningful
  progress except by peeking into `batch.json`. Resume, reporting, and UI now have
  two incompatible state machines: pipeline phases at the top, relay slices
  hidden inside one phase directory.
- Proposed fix:
  Admit the nesting. Either:
  `execute` is a child pipeline with a formal adapter boundary, or
  the top-level schema supports subphases/subruns explicitly.
  Hiding a workflow inside a “phase slot” is not modularity; it is concealment.

### 10. Partial-write and crash recovery semantics are underdesigned
- Severity: Medium
- Concrete failure scenario:
  An align phase writes `constraints.json`, then crashes before `decision-log.md`
  and `resume.md`. What exactly is the phase status? Can the next phase start?
  Does the gate evaluate incomplete artifacts? Today the design describes outputs,
  but not transaction boundaries for producing them.
- Proposed fix:
  Add a phase finalization protocol:
  write artifacts to a temp dir, emit `artifacts.json` with hashes, validate, then
  append `phase_completed` and atomically promote the phase directory.
  Incomplete phases should be explicitly resumable or explicitly failed, never
  half-complete by directory contents alone.

## Modularity / Flexibility Opportunities

### 1. Raw file paths are too low-level for the primary contract
- What's currently rigid:
  `allowed_paths` and pointer-based artifacts assume the filesystem is the best
  abstraction boundary.
- What it should be:
  Named capabilities or scopes that can compile to paths.
- Concrete suggestion:
  Support contracts like `module:runtime`, `boundary:swift-rust-ffi`,
  `artifact:review-packet`, then resolve them to concrete paths at execution time.
  This keeps the contract stable even when files move.

### 2. Skill selection should be versioned and swappable
- What's currently rigid:
  `skill` is a bare name with no version, compatibility, or fallback semantics.
- What it should be:
  A versioned adapter + optional skill overlay.
- Concrete suggestion:
  Store `adapter_id`, `adapter_version`, `skill_name`, and `skill_version_hint`.
  That gives you reproducibility and makes future skill swaps explicit instead of
  magical.

### 3. Durable evidence and scratch space should be separated
- What's currently rigid:
  Prompts, handoffs, ledgers, resume docs, and review findings all live under the
  same conceptual directory tree.
- What it should be:
  Clear separation between canonical artifacts and disposable execution scratch.
- Concrete suggestion:
  Use something like:
  `.pipeline/index/`
  `.pipeline/phases/.../artifacts/`
  `.pipeline/phases/.../runtime/`
  `.pipeline/phases/.../scratch/`
  That makes cleanup, resume, and archival policies far simpler.

### 4. Constraints should be composable, not phase-local prose blobs
- What's currently rigid:
  Constraint deltas are embedded in phase records and `constraints.json`.
- What it should be:
  A reusable constraint set that later phases and tools can query directly.
- Concrete suggestion:
  Model constraints as typed records with IDs, provenance, status, and superseded
  links. Then generate `constraints.json` for execute as a compiled view instead
  of the only structured source.

### 5. The pipeline shape is “three phases plus exceptions”
- What's currently rigid:
  The design says “architected for N,” but most semantics are still hard-coded
  around triage -> align -> execute and the special case of new align phases.
- What it should be:
  A generic phase engine with a catalog of phase kinds and transition policies.
- Concrete suggestion:
  Define a phase registry:
  `kind`, `allowed_predecessors`, `adapter`, `required_inputs`,
  `required_outputs`, `gate_validator`, `may_spawn_child_pipeline`.
  Then triage/align/execute are entries in that registry, not special law.

## What's Strong

- The interactive vs autonomous boundary is the right idea. Freezing design
  judgment before execution is a real quality lever.
- The align -> execute gate is a good instinct. Most orchestration systems fail
  because they hand workers a blurry mission and hope for consistency.
- Append-only events plus rebuildable snapshots is the correct bookkeeping shape.
  It is far better than hand-editing mutable state.
- Keeping phase artifacts local to the phase is directionally right. It reduces
  accidental global coupling and makes audit trails easier to inspect.
- Forward-only auditability is stronger than rewrite-in-place history, especially
  when recovery work needs to be explained later.
- Token-budget discipline is good. Pointer-heavy navigation documents are the
  right default for agent systems, as long as the pointers become immutable.

## Structural Recommendations

1. Introduce a first-class root object for every pipeline:
   `pipeline.json` or `index.json` with `pipeline_root`, schema version, active
   epoch, current phase, authoritative sources, and path registry.

2. Shrink `state.json` into a derived active index, and move per-phase metadata
   into `phases/{id}/phase.json`. Do not try to make one snapshot file both small
   and historically rich.

3. Add `artifacts.json` per phase listing every required output with path, hash,
   media type, producer, and status. Gates should validate this manifest, not
   infer completeness from loose directory contents.

4. Treat `execute` as a child workflow with an explicit adapter boundary. Either
   absorb relay semantics into the generic phase engine or formally acknowledge
   that `execute` runs a nested orchestrator.

5. Define a strict single-writer model. One controller writes top-level pipeline
   state. Child workflows may write only inside their owned roots and emit
   summarized status upward through declared events.

6. Add mission versioning. Preserve the original request, but allow
   user-approved mission amendments as first-class records instead of burying
   changed intent in later resumes and deltas.

7. Replace “banned vague terms” with typed measurable fields. Lexical policing is
   easy to game. Structured commitments are harder to fake and easier to diff.

## Open Questions

- Who is authoritative for live execution truth during resume: the filesystem
  snapshot, the running subprocess/tool, or some runtime service?
- Can multiple pipelines exist concurrently in one repo? If yes, what prevents
  them from overlapping paths, branches, or verification commands?
- How are lock contention and concurrent writes handled if a human, orchestrator,
  and child execute workflow all touch `.pipeline/` at roughly the same time?
- What is the migration story when a phase adapter, skill template, or schema
  version changes mid-pipeline?
- How are generated files, renames, and codegen outputs represented when
  `allowed_paths` must be explicit and wildcards are banned?
- What makes a mission amendment legitimate versus out-of-scope drift?
- How is garbage collection handled for raw transcripts and obsolete epoch
  artifacts without destroying auditability?
- If execute discovers the plan is wrong, what guarantees the next align phase
  reuses the right evidence instead of re-litigating the whole mission?
