# Pipeline Design v2

This revision resolves the four blocking findings from the design review:

- all execute-phase relay artifacts are rooted under one explicit `--root`
- `state.json` becomes a thin active index
- completed-phase artifact pointers become immutable by hash
- `execute` is modeled as a child workflow behind an adapter boundary

The design stays intentionally conservative: it extends the proven relay pattern instead of inventing a second orchestrator.

## 1. Revised Directory Structure

The pipeline owns one root. Every control-plane path is derived from that root. An `execute` phase also owns one child relay root under its phase directory.

```text
.pipeline/
  state.json
  events.ndjson
  mission/
    mission-v001.md
    mission-v002.md
  constraints/
    sets/
      constraint-set-001.json
      constraint-set-002.json
  phases/
    phase-001-triage/
      phase.json
      artifacts/
        input.md
        output.md
        gate-report.json
        resume.md
      runtime/
      scratch/
    phase-002-align/
      phase.json
      artifacts/
        execution-spec.md
        decision-log.md
        verification-plan.md
        open-questions.md
        gate-report.json
        resume.md
      runtime/
      scratch/
    phase-003-execute/
      phase.json
      artifacts/
        manage-codex-header.md
        output.md
        gate-report.json
        resume.md
      runtime/
        adapter-status.json
        adapter-lock.json
        relay/
          batch.json
          plan.json
          events.ndjson
          archive/
          prompts/
            prompt-header-slice-001.md
            prompt-slice-001.md
            review-header-slice-001.md
            review-prompt-slice-001.md
            converge-header.md
            converge-prompt.md
          handoffs/
            handoff-slice-001.md
            handoff-converge.md
          review-findings/
            review-findings-slice-001.md
          last-messages/
          logs/
          scratch/
      scratch/
```

Rooting rules:

- `state.json`, `events.ndjson`, `mission/`, `constraints/`, and `phases/` derive from `pipeline_root`.
- The execute child workflow derives every relay artifact from `relay_root = {pipeline_root}/phases/{phase_id}/runtime/relay`.
- No prompt, handoff, review finding, archive file, or event ledger may derive its path by guessing from `batch.json`.
- Resume always reads the recorded root from `state.json` and `phase.json`; it never infers a root from the current working directory.

## 2. Revised state.json Schema

`state.json` is now a thin active index. It is intentionally small and should stay under 2 KB. History is reconstructed from `events.ndjson` plus the per-phase `phase.json` files.

```json
{
  "schema_version": 2,
  "pipeline_id": "2026-03-18-worker-session-pinning",
  "pipeline_root": ".pipeline",
  "status": "active",
  "updated_at": "2026-03-18T19:24:00Z",
  "active_epoch_id": "epoch-002",
  "current_phase_id": "phase-003-execute",
  "mission_version": {
    "path": ".pipeline/mission/mission-v002.md",
    "sha256": "sha256:8db7c4d3..."
  },
  "active_constraint_set": {
    "path": ".pipeline/constraints/sets/constraint-set-002.json",
    "sha256": "sha256:77c0fa92..."
  },
  "latest_resume": {
    "phase_id": "phase-003-execute",
    "path": ".pipeline/phases/phase-003-execute/artifacts/resume.md",
    "sha256": "sha256:0f01b2aa..."
  },
  "child_workflow": {
    "phase_id": "phase-003-execute",
    "adapter_id": "manage-codex-relay",
    "status": "reviewing",
    "progress_summary": "Reviewing slice-002 of 4; no artifact drift detected.",
    "status_path": ".pipeline/phases/phase-003-execute/runtime/adapter-status.json",
    "last_checkpoint_at": "2026-03-18T19:24:00Z"
  }
}
```

Field meanings:

- `schema_version`: format version for rebuild and validation logic.
- `pipeline_id`: stable identifier for the pipeline run.
- `pipeline_root`: authoritative root for all top-level pipeline artifacts.
- `status`: `active`, `waiting_user`, `blocked`, or `complete`.
- `updated_at`: last successful index write.
- `active_epoch_id`: which epoch currently defines the active truth.
- `current_phase_id`: the only phase the orchestrator may actively advance.
- `mission_version`: pointer to the active mission document plus the hash recorded when activated.
- `active_constraint_set`: pointer to the compiled active constraint set plus the recorded hash.
- `latest_resume`: pointer to the most recent recorded `resume.md` plus the hash captured at the last checkpoint.
- `child_workflow`: nullable summary for the active execute child workflow. The pipeline reads this summary, not the child workflow’s private state.

What is deliberately absent:

- no phase array
- no historical gate results
- no per-phase constraint deltas
- no artifact manifests

Those moved to `phases/{id}/phase.json`.

## 3. phase.json Schema

Each phase owns its own durable metadata file. This is where lineage, gate results, artifact manifests, and execute-child state live.

Example execute phase:

```json
{
  "schema_version": 2,
  "phase_id": "phase-003-execute",
  "kind": "execute",
  "label": "Execute",
  "epoch_id": "epoch-002",
  "status": "in_progress",
  "lineage": {
    "origin_phase_id": "phase-002-align",
    "origin_event": "gate_passed",
    "reason": "alignment_ready"
  },
  "adapter": {
    "adapter_id": "manage-codex-relay",
    "adapter_version": "v1",
    "skill_overlay": "manage-codex",
    "relay_root": ".pipeline/phases/phase-003-execute/runtime/relay",
    "status_path": ".pipeline/phases/phase-003-execute/runtime/adapter-status.json"
  },
  "inputs": {
    "mission_version": {
      "path": ".pipeline/mission/mission-v002.md",
      "sha256": "sha256:8db7c4d3..."
    },
    "constraint_set": {
      "path": ".pipeline/constraints/sets/constraint-set-002.json",
      "sha256": "sha256:77c0fa92..."
    }
  },
  "constraint_delta": {
    "fixed": [
      "Execute uses the Swift-owned persistence design chosen in phase-002-align."
    ],
    "eliminated": [
      "Worker chooses persistence ownership during implementation."
    ],
    "remaining": []
  },
  "gate_result": {
    "gate_id": "execution_readiness_v2",
    "status": "passed",
    "checked_at": "2026-03-18T19:00:00Z",
    "evidence_paths": [
      ".pipeline/phases/phase-002-align/artifacts/execution-spec.md",
      ".pipeline/phases/phase-002-align/artifacts/decision-log.md",
      ".pipeline/phases/phase-002-align/artifacts/verification-plan.md"
    ],
    "blocking_gaps": []
  },
  "artifact_manifest": {
    "lock_state": "mutable",
    "items": [
      {
        "artifact_id": "manage-codex-header",
        "role": "input",
        "media_type": "text/markdown",
        "path": ".pipeline/phases/phase-003-execute/artifacts/manage-codex-header.md",
        "sha256": "sha256:d2102fd2...",
        "recorded_at": "2026-03-18T19:02:00Z",
        "locked_at": null
      },
      {
        "artifact_id": "adapter-status",
        "role": "runtime",
        "media_type": "application/json",
        "path": ".pipeline/phases/phase-003-execute/runtime/adapter-status.json",
        "sha256": "sha256:98bcfe44...",
        "recorded_at": "2026-03-18T19:24:00Z",
        "locked_at": null
      },
      {
        "artifact_id": "resume",
        "role": "output",
        "media_type": "text/markdown",
        "path": ".pipeline/phases/phase-003-execute/artifacts/resume.md",
        "sha256": "sha256:0f01b2aa...",
        "recorded_at": "2026-03-18T19:24:00Z",
        "locked_at": null
      }
    ]
  },
  "child_workflow": {
    "status": "reviewing",
    "progress_summary": "Reviewing slice-002 of 4.",
    "current_child_phase": "review",
    "current_slice_id": "slice-002",
    "counts": {
      "total_slices": 4,
      "completed_slices": 1,
      "review_rejections": 0,
      "convergence_attempts": 0
    },
    "last_checkpoint_at": "2026-03-18T19:24:00Z",
    "verdict": null
  },
  "timestamps": {
    "created_at": "2026-03-18T19:01:00Z",
    "started_at": "2026-03-18T19:02:00Z",
    "completed_at": null
  }
}
```

Schema rules:

- `phase.json` is the only place phase metadata lives durably.
- `artifact_manifest.items[*].sha256` is recorded when the artifact is registered and re-verified when the phase is completed.
- `artifact_manifest.lock_state` is `mutable` while the phase is in progress and `locked` after `phase_completed`.
- `child_workflow` is required for `execute` and `null` for non-execute phases.
- History comes from the event ledger. `phase.json` is the latest materialized view for that phase, not the sole audit trail.

## 4. Artifact Immutability Protocol

The design treats an artifact pointer as a content-addressed claim, not just a path.

### Artifact record format

Every artifact pointer stores:

- `path`
- `sha256`
- `media_type`
- `role`
- `recorded_at`
- `locked_at`

If the pointer targets a repository file outside the phase directory, the same rule applies: the path is only navigational; the hash is the historical truth.

### Locking lifecycle

1. `artifact_recorded`
The orchestrator records a path and its current SHA-256 in `phase.json`. The artifact is still mutable.

2. `phase_completed`
Before completion is accepted, the orchestrator recomputes hashes for every required output artifact, `resume.md`, and any supporting artifact cited by the gate or output summary.

3. Event lock
`events.ndjson` appends a `phase_completed` record containing the final hash list. Example:

```json
{
  "ts": "2026-03-18T19:28:00Z",
  "event": "phase_completed",
  "phase": "phase-002-align",
  "locked_artifacts": [
    {
      "artifact_id": "execution-spec",
      "path": ".pipeline/phases/phase-002-align/artifacts/execution-spec.md",
      "sha256": "sha256:1aa3c9de..."
    },
    {
      "artifact_id": "resume",
      "path": ".pipeline/phases/phase-002-align/artifacts/resume.md",
      "sha256": "sha256:6e19d0b1..."
    }
  ]
}
```

4. Manifest lock
`phase.json.artifact_manifest.lock_state` flips to `locked`, and every item gets `locked_at`.

### Resume drift check

Cold resume performs this sequence before using any historical artifact:

1. load `state.json`
2. resolve `latest_resume.path`
3. recompute the current SHA-256 of that file
4. compare it to `latest_resume.sha256`
5. if the phase is locked, recompute every locked artifact hash in `phase.json`

Drift behavior:

- if all hashes match, resume is allowed
- if any hash differs, the pipeline records `artifact_drift_detected`
- automatic resume stops
- the historical phase remains unchanged
- intentional updates must happen in a new successor phase, not by silently relocking the old one

Why this matters: a path is a mutable locator; a hash is a stable historical statement. That distinction is what keeps resume from reading today’s file while pretending it is yesterday’s decision.

## 5. Execute Adapter Interface

`execute` is a child workflow, not a magical phase. The pipeline talks to it only through an adapter.

### Boundary

- Pipeline owns `.pipeline/state.json`, `.pipeline/events.ndjson`, and `phases/{id}/phase.json`.
- Adapter owns `phases/{id}/runtime/adapter-status.json`.
- Adapter writes `phases/{id}/runtime/adapter-lock.json` once at attach time so the execute phase has an immutable record of `pipeline_root`, `relay_root`, and the packet hash it launched with.
- `manage-codex` owns the private child relay root under `phases/{id}/runtime/relay/`.
- The pipeline never reads `batch.json` directly.

### Adapter inputs

Required inputs to start an execute phase:

- `pipeline_root`
- `phase_id`
- `relay_root`
- `execution_packet_path`
- `execution_packet_sha256`
- `skill_overlay = manage-codex`
- `verification_commands`
- `success_criteria`

Recommended start command:

```bash
./scripts/pipeline/execute-adapter.sh start \
  --pipeline-root .pipeline \
  --phase phase-003-execute \
  --relay-root .pipeline/phases/phase-003-execute/runtime/relay \
  --packet .pipeline/phases/phase-003-execute/artifacts/manage-codex-header.md
```

### Adapter outputs

The adapter publishes exactly three public outputs:

- `runtime/adapter-status.json` for current child-workflow status
- `artifacts/output.md` for the execute-phase summary after terminal completion
- `artifacts/gate-report.json` for the execute exit verdict

Everything else inside `runtime/relay/` is child-workflow private state.

### Status reporting contract

`adapter-status.json` is the only status surface the pipeline reads:

```json
{
  "schema_version": 1,
  "adapter_id": "manage-codex-relay",
  "phase_id": "phase-003-execute",
  "pipeline_root": ".pipeline",
  "relay_root": ".pipeline/phases/phase-003-execute/runtime/relay",
  "status": "reviewing",
  "progress_summary": "Reviewing slice-002 of 4; last review was CLEAN.",
  "current_child_phase": "review",
  "current_slice_id": "slice-002",
  "counts": {
    "total_slices": 4,
    "completed_slices": 1,
    "review_rejections": 0,
    "convergence_attempts": 0
  },
  "latest_artifacts": {
    "handoff_path": ".pipeline/phases/phase-003-execute/runtime/relay/handoffs/handoff-slice-002.md",
    "handoff_sha256": "sha256:ca81d9c0...",
    "review_findings_path": ".pipeline/phases/phase-003-execute/runtime/relay/review-findings/review-findings-slice-002.md",
    "review_findings_sha256": "sha256:4c1a01c3..."
  },
  "last_checkpoint_at": "2026-03-18T19:24:00Z",
  "verdict": null
}
```

Status values:

- `not_started`
- `planning`
- `implementing`
- `reviewing`
- `reworking`
- `converging`
- `complete`
- `blocked`
- `drifted`

Natural checkpoint rule:

- The adapter updates `adapter-status.json` only at workflow boundaries the parent pipeline can reason about.
- Minimum checkpoints are: plan created, implementation dispatched, review recorded, convergence started, convergence finished, drift detected.
- The adapter may read `batch.json` internally, but it must translate that into the stable summary above.

This is the architectural payoff: the parent pipeline can show meaningful execute progress without coupling itself to relay’s internal schema.

## 6. Revised update-pipeline.sh Interface

`update-pipeline.sh` becomes root-first. `--state` is removed from the public contract because state is no longer the primary namespace. `--root` is the namespace.

### Pipeline CLI

```bash
./scripts/pipeline/update-pipeline.sh --root .pipeline --event init_pipeline --mission-path .pipeline/mission/mission-v001.md
./scripts/pipeline/update-pipeline.sh --root .pipeline --event mission_activated --mission-path .pipeline/mission/mission-v002.md
./scripts/pipeline/update-pipeline.sh --root .pipeline --event constraint_set_activated --constraints-path .pipeline/constraints/sets/constraint-set-002.json
./scripts/pipeline/update-pipeline.sh --root .pipeline --event phase_added --phase phase-002-align --kind align --adapter interactive-align-v1
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event phase_started
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event artifact_recorded --artifact-id execution-spec --artifact .pipeline/phases/phase-002-align/artifacts/execution-spec.md --role output --media-type text/markdown
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event phase_completed
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-003-execute --event child_checkpoint --status reviewing --summary "Reviewing slice-002 of 4."
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-003-execute --event artifact_drift_detected --artifact-id resume
./scripts/pipeline/update-pipeline.sh --root .pipeline --event pipeline_completed
./scripts/pipeline/update-pipeline.sh --root .pipeline --validate
./scripts/pipeline/update-pipeline.sh --root .pipeline --rebuild
```

Core events:

| Event | Required args | Effect |
| --- | --- | --- |
| `init_pipeline` | `--root`, `--mission-path` | Creates the rooted pipeline directory and initial index. |
| `mission_activated` | `--mission-path` | Updates the active mission pointer and hash in `state.json`. |
| `constraint_set_activated` | `--constraints-path` | Updates the active constraint-set pointer and hash in `state.json`. |
| `phase_added` | `--phase`, `--kind`, `--adapter` | Creates `phases/{id}/phase.json` and phase directories. |
| `phase_started` | `--phase` | Marks a phase `in_progress` and updates `current_phase_id`. |
| `artifact_recorded` | `--phase`, `--artifact-id`, `--artifact`, `--role`, `--media-type` | Hashes and records the artifact in `phase.json`. |
| `child_checkpoint` | `--phase`, `--status`, `--summary` | Copies adapter status into `phase.json.child_workflow` and `state.json.child_workflow`. |
| `phase_completed` | `--phase` | Rehashes required artifacts, records `phase_completed`, and locks the manifest. |
| `artifact_drift_detected` | `--phase`, `--artifact-id` | Records drift and blocks auto-resume. |
| `pipeline_completed` | `--root` | Clears `current_phase_id`, clears `child_workflow`, and marks `status=complete`. |

Validation rules:

- `state.json` must stay under 2048 bytes.
- exactly one phase may be `in_progress`
- `current_phase_id` must exist if present
- locked artifacts must still match their recorded hashes
- `state.json.pipeline_root` must match the invoked `--root`
- execute phases must have `adapter.relay_root`
- `state.json.child_workflow.status_path` must match the execute phase’s `adapter-status.json`

### Required relay-script changes

The parent pipeline change is not enough on its own. The child relay tooling must also become root-first.

#### `update-batch.sh`

Conceptual change:

- add `--root`
- derive `batch.json`, `plan.json`, `events.ndjson`, `archive/`, `prompts/`, `handoffs/`, `review-findings/`, `last-messages/`, and `logs/` from that root
- persist `relay_root` inside `batch.json` so child-workflow resume never guesses

Before:

- hard-coded `.relay/batch.json`
- hard-coded `.relay/archive`
- `events.ndjson` derived indirectly from the archive parent

After:

```bash
./scripts/relay/update-batch.sh \
  --root .pipeline/phases/phase-003-execute/runtime/relay \
  --event attempt_started \
  --slice slice-001
```

Derived paths:

- `batch.json = {root}/batch.json`
- `plan.json = {root}/plan.json`
- `events.ndjson = {root}/events.ndjson`
- `archive = {root}/archive/`
- `handoffs = {root}/handoffs/`
- `review-findings = {root}/review-findings/`

#### `compose-prompt.sh`

Conceptual change:

- add `--root`
- default prompt outputs under `{root}/prompts/`
- templates emit rooted artifact destinations, not hard-coded `.relay/*`

Before:

- examples assume `.relay/prompt.md`
- relay protocol instructs workers to write `.relay/handoff-*`

After:

```bash
./scripts/relay/compose-prompt.sh \
  --root .pipeline/phases/phase-003-execute/runtime/relay \
  --header .pipeline/phases/phase-003-execute/runtime/relay/prompts/prompt-header-slice-001.md \
  --template implement \
  --out .pipeline/phases/phase-003-execute/runtime/relay/prompts/prompt-slice-001.md
```

Template contract after rooting:

- handoffs go to `{root}/handoffs/`
- review findings go to `{root}/review-findings/`
- prompt products go to `{root}/prompts/`
- fallback logs and last-message files go to `{root}/last-messages/`

## 7. Revised SKILL.md Outline

This is the pipeline-orchestrator outline after the v2 fixes:

```md
---
name: pipeline
description: >
  Multi-phase development pipeline orchestrator. Use for `/pipeline`
  when the work needs explicit triage, alignment, and then autonomous execution.
---

# Pipeline

You are the pipeline orchestrator.
Your job is to shrink uncertainty phase by phase until autonomous execution is safe.

Loop:
- `triage -> align -> execute`
- append new phases when new information appears
- never reopen completed phases

Done only when:
- the final phase is complete
- `.pipeline/state.json` is clean
- any active execute child workflow reports `complete`

## Principles

- always operate with `--root`
- `state.json` is a thin index, not a history log
- `phases/{id}/phase.json` is the durable phase record
- all historical artifact pointers must carry SHA-256 hashes
- completed phases are immutable
- execute is a child workflow behind an adapter
- never read child `batch.json` directly; read `adapter-status.json`

## Filesystem Contract

- `{root}/state.json`
- `{root}/events.ndjson`
- `{root}/mission/`
- `{root}/constraints/sets/`
- `{root}/phases/{phase_id}/phase.json`
- `{root}/phases/{phase_id}/artifacts/`
- `{root}/phases/{phase_id}/runtime/`
- `{root}/phases/{phase_id}/scratch/`

## Setup

- read `AGENTS.md`
- if `{root}/state.json` exists, resume instead of restarting
- verify `state.json.pipeline_root == --root`
- run `update-pipeline.sh --root {root} --validate`
- verify locked artifact hashes before trusting `resume.md`

## Triage

- normalize the request
- decide whether align is required
- write phase-local artifacts
- do not put rich history in `state.json`

## Align

- choose one approach
- record decisions and rejected alternatives
- compile the active constraint set
- produce a locked `resume.md` before phase completion

## Execute

1. create `{phase}/runtime/relay/`
2. materialize `manage-codex-header.md`
3. start the execute adapter with `--relay-root`
4. let the adapter update `adapter-status.json` at natural checkpoints
5. mirror adapter checkpoints into `state.json.child_workflow`
6. on completion, summarize child outputs into execute artifacts

## Resume

- never infer roots from cwd
- never trust path-only pointers
- if a locked artifact hash drifts, stop automatic resume and record drift

## Forward-Only Rule

- completed phases stay historical
- intentional changes create a new successor phase
- do not relock edited artifacts in place
```

## 8. What Was Deferred and Why

These review findings are not fully solved by this revision:

- Authoritative live-state ownership during active subprocess execution.
Reason: v2 adds an adapter summary so the parent no longer peeks into child state, but it still does not define a full live-process authority matrix across crashes, detached workers, and externally resumed sessions.

- Generic phase adapter registry for every phase kind.
Reason: execute needed a formal adapter immediately because it hides a nested workflow. A full adapter catalog for triage, align, and future phase kinds is valuable, but not required to fix the four blocking issues.

- Stronger semantic closure for the align gate.
Reason: v2 preserves the gate concept and makes its artifacts durable, but it does not yet add first-class `decisions[]`, `prohibited_alternatives[]`, executable examples, or contract-test generation.

- Fine-grained constraint supersession instead of phase-level deltas.
Reason: the state split creates room for this later, but v2 still stores constraint narrowing at the phase level rather than as first-class typed records.

- Risk-based fast-path classification.
Reason: path rooting, state splitting, and execute encapsulation are prerequisites. Tightening the triage bypass heuristic can follow once the pipeline’s basic structure is stable.

- Crash-safe temp-directory promotion and incomplete-phase transaction semantics.
Reason: v2 adds lock-on-complete and drift detection, which prevents historical corruption, but it does not yet specify a full two-phase artifact promotion protocol for partial writes.
