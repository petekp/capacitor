> **ARCHIVED** — This document described authoring the `method` skill, which has been
> extracted into the Circuit plugin as `circuit:create`. See `~/Code/circuit/skills/circuit-create/`
> for the current implementation. Retained for historical reference only.

# Prompt: Create the "method" Skill

## What This Skill Does

Create a Claude Code skill called **method** that acts as a **method compiler** —
it takes a rough, natural-language description of a multi-phase workflow and compiles
it into a fully-specified dispatch plan with parallelization, worker counts, templates,
dependency chains, and self-contained task descriptions.

The user sketches the *what* (phases and their intent). The skill decides the *how*
(parallel vs sequential, worker count, manage-codex template, file scope, blocking
order).

## Core Mental Model

The skill is a compiler with three stages:

### 1. Parse

Accept a problem statement and a rough phase sketch. Phases can be as terse as:

```
research the problem domain and existing architecture (parallel)
explore and evaluate implementation approaches, pick one
write implementation guide, pressure test it, revise
implement via pipeline
find and clean up dead code
```

Or as detailed as the user wants. The skill extracts from each line:
- **Phase intent** — what this phase accomplishes
- **Dispatch hint** — if the user said "parallel" or listed independent tasks
- **Implicit dependencies** — later phases depend on earlier ones unless stated otherwise

### 2. Compile

Apply heuristics to turn each parsed phase into concrete tasks:

**Worker count heuristics:**
- A phase with a single clear intent gets 1 worker
- A phase with "and" joining independent concerns gets 1 worker per concern (parallel)
- Explicit lists in a phase description map to 1 worker per list item
- A phase involving "explore alternatives" defaults to 1 worker (it explores internally),
  unless the user specified a count
- "Pressure test" / "red team" / "review" phases always get their own worker, never
  merged with the thing they're reviewing

**Template selection:**
- Phases that read/analyze/explore/research without producing code changes: `ship-review`
- Phases that produce an artifact (ADR, guide, constraint contract): `ship-review`
- Phases that write or modify code: `implement`
- Final cleanup analysis: `ship-review`; cleanup remediation: `implement`

**Parallelization rules:**
- Workers within a phase are parallel unless one depends on another's output
- Phases are sequential (each blocks on the prior phase completing) unless the user
  explicitly marks them as parallel
- Research phases are good parallelization candidates — flag this to the user if
  they didn't already indicate parallelism

**Dependency chain:**
- Each phase blocks on the prior phase's tasks
- Within a parallel phase, tasks have no mutual dependencies
- The compile stage builds the full `addBlockedBy` graph before presenting

### 3. Present & Dispatch

**Approval flow:**
1. Present the compiled plan as a table:

```
Phase | Task | Workers | Dispatch | Template | Blocked By
------|------|---------|----------|----------|----------
1     | Domain research | 1 | parallel | ship-review | —
1     | Architecture trace | 1 | parallel | ship-review | —
2     | Explore approaches | 1 | sequential | ship-review | 1a, 1b
2     | Evaluate with matrix | 1 | sequential | ship-review | 2a
...
```

2. Below the table, show a brief summary:
   - Total workers to dispatch
   - Estimated parallelism (which phases run concurrently)
   - Inferred domain (Rust, Swift, both) and file scope
   - Which manage-codex templates will be used

3. Ask: "Approve this plan, or adjust? You can: modify worker counts, skip phases,
   reorder, add phases, or change templates."

4. Only create tasks after explicit approval.

**Task creation:**
- Use TaskCreate for each task
- Use TaskUpdate with `addBlockedBy` to wire the dependency chain
- Each task description must be **self-contained** — a fresh session with no prior
  context should be able to execute it. Include:
  - Problem statement (copied from user input)
  - Phase context (what prior phases produced, what this task feeds into)
  - File scope (explicit paths or globs)
  - Domain skills for compose-prompt.sh `--skills` flag
  - manage-codex template to use
  - Success criteria (what "done" looks like for this task)
  - Circuit breaker limits: max 3 impl attempts, max 5 total

## Operating Modes

### Standalone Mode (default)
- Creates TaskCreate tasks for session-visible tracking
- Task descriptions contain fully-formed manage-codex prompt headers
- User dispatches workers manually from the task descriptions
- No .pipeline/ directory needed

### Pipeline Mode (when pipeline is active or requested)
- Checks for existing `.pipeline/state.json`
- If active pipeline: adds phases to the existing pipeline
- If no pipeline: offers to initialize one
- Execute-phase tasks set relay root to `.pipeline/phases/<phase-id>/runtime/relay/`
- Respects pipeline's forward-only phase progression rule

Detect mode automatically: if `.pipeline/` exists, ask whether to integrate.
If the user says "/pipeline" in conjunction with this skill, use pipeline mode.

## Trigger Conditions

This skill should trigger when the user says things like:
- "method: [problem description]"
- "plan the research-to-implementation workflow for X"
- "set up the full method for X"
- "I need to research, design, and implement X"
- "create a multi-phase task plan for X"
- "spin up workers for this integration problem"
- "use the method pattern for X"

Should NOT trigger for:
- Simple bug fixes or single-file changes
- Direct manage-codex dispatch (use manage-codex skill instead)
- Direct pipeline operations (use pipeline skill instead)
- Questions about code without an implementation intent

## Resume Awareness

Before generating tasks, check for existing state:
1. TaskList — if tasks matching the problem description exist, show their status
   and offer to continue rather than create from scratch
2. `.pipeline/state.json` — if a pipeline exists, read current phase and offer
   integration
3. If handoff artifacts from prior research/design already exist (e.g., in a relay
   root), skip those phases and start from the first incomplete phase

## Adaptation Examples

These show how the same skill handles different inputs:

### Example 1: Simple Wiring Problem

**User input:**
```
method: wire WebCaptureService into the CaptureComplete mutation

research the problem domain and architecture (parallel)
design the approach
implement
cleanup
```

**Compiled plan:**
- Phase 1: 2 parallel workers (domain + architecture), ship-review
- Phase 2: 1 worker (explore + evaluate + select), ship-review
- Phase 3: 1 worker, implement template
- Phase 4: 2 workers (analysis ship-review, then remediation implement)
- Total: 6 tasks, domain: Swift

### Example 2: Complex Cross-Domain Problem

**User input:**
```
method: add recording playback to the runtime service

research recording formats and existing playback patterns (parallel)
research the runtime service API surface (parallel)
explore at least 4 implementation approaches
evaluate approaches with decision matrix
select approach and produce ADR
write implementation guide
pressure test the guide for race conditions and edge cases
revise guide based on pressure test
implement via pipeline
analyze for dead code and naming issues
clean up findings
```

**Compiled plan:**
- Phase 1: 2 parallel workers, ship-review
- Phase 2: 3 sequential workers (explore → evaluate → select), ship-review
- Phase 3: 3 sequential workers (write → pressure test → revise), ship-review
- Phase 4: 1 worker, implement template (pipeline mode)
- Phase 5: 2 workers (analysis ship-review → remediation implement)
- Total: 11 tasks, domain: Rust + Swift

### Example 3: Minimal Research-Only

**User input:**
```
method: understand how the snapshot pipeline currently works

trace the data flow from capture to storage
identify all consumers of snapshot data
document the implicit contracts between components
```

**Compiled plan:**
- Phase 1: 3 parallel workers (all independent research), ship-review
- Total: 3 tasks, domain: Rust + Swift
- No execute or cleanup phases

## Integration Points

### manage-codex
- Task descriptions contain prompt headers compatible with `compose-prompt.sh`
- Each task specifies: `--template`, `--skills`, `--root`, `--verification` flags
- Circuit breaker limits are embedded in task descriptions
- Ship-review vs implement template selection follows manage-codex conventions

### pipeline
- In pipeline mode, execute phases map to pipeline execute phases
- Research/design phases map to pipeline triage/align phases
- Relay root paths follow `.pipeline/phases/<id>/runtime/relay/` convention
- Respects pipeline's forward-only rule and execution readiness gate

### TaskCreate/TaskUpdate
- All tasks created via TaskCreate with rich descriptions
- Dependency chain wired via TaskUpdate `addBlockedBy`
- Parallel tasks within a phase have no mutual blockers
- Sequential phases block on all tasks in the prior phase

## What to Produce

1. **SKILL.md** — Core compilation logic, phase parsing, heuristic rules, approval UX
   (~1,800 words). Use imperative form. Third-person in frontmatter description.

2. **references/phase-heuristics.md** — Detailed worker count, template selection,
   and parallelization decision tables

3. **references/task-template.md** — The self-contained task description template
   with all required fields (problem statement, phase context, file scope, domain
   skills, template, success criteria, circuit breaker limits)

4. **references/integration.md** — How the skill interacts with manage-codex,
   pipeline, and TaskCreate/TaskUpdate, including compose-prompt.sh flag mappings

5. **examples/simple-wiring.md** — The Example 1 case fully expanded

6. **examples/cross-domain.md** — The Example 2 case fully expanded

## Design Constraints

- The skill MUST present the plan and get approval before creating any tasks
- Task descriptions MUST be self-contained (handoff-ready for a fresh session)
- The skill should work with zero configuration — infer domain from file scope,
  infer template from phase intent, infer parallelism from phase structure
- No hardcoded task counts — the number of tasks is derived from the user's
  phase description, not a fixed template
- The skill should be opinionated about defaults but overridable on everything
