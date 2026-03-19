# Modular Development Pipeline — Design Spec

**Date:** 2026-03-18
**Status:** Approved for v1 implementation
**Author:** Pete Petrash + Claude (collaborative brainstorming + 5 Codex review passes)

## Overview

A `/pipeline` command that orchestrates multi-phase development workflows. The pipeline is a constraint refinement engine: each phase narrows the degrees of freedom until autonomous execution is safe.

v1 ships 3 phases (triage → align → execute), architected for N.

## Core Principles

1. **Constraint narrowing** — each phase's job is to eliminate ambiguity for subsequent phases.
2. **Interactive front, autonomous back** — early phases are collaborative (human + model), later phases run hands-free.
3. **LLMs own judgment, scripts own bookkeeping** — models decide what to do; deterministic scripts record what happened.
4. **Forward-only** — completed phases are immutable. Problems create new phases, never rewind.
5. **Pointers over content** — phase artifacts reference files by path + hash, never inline large content.
6. **Artifact-based resume** — cold-start from state files, not conversation memory.
7. **Single writer per namespace** — one controller writes each state surface.
8. **Self-instrumenting** — the pipeline produces structured telemetry for automated improvement.

## Directory Structure

All state lives under one root. Roots are repo-root-relative, resolved via `git rev-parse --show-toplevel`.

```
.pipeline/
  state.json                             # thin active index (<2KB)
  events.ndjson                          # append-only mutation ledger
  mission/
    mission-v001.md                      # immutable versioned mission docs
  constraints/
    sets/
      constraint-set-001.json            # compiled constraint sets
  phases/
    phase-001-triage/
      phase.json                         # durable phase metadata
      artifacts/
        input.md
        output.md
        gate-report.json
        resume.md
      scratch/                           # disposable working files
    phase-002-align/
      phase.json
      artifacts/
        execution-spec.md
        constraints.json
        decision-log.md                # recommended in v1; not required by gate_passed
        verification-plan.md
        open-questions.md
        gate-report.json
        resume.md
      scratch/
    phase-003-execute/
      phase.json
      artifacts/
        manage-codex-header.md
        output.md
        gate-report.json
        resume.md
      runtime/
        adapter-status.json              # the ONLY status surface the pipeline reads
        adapter-lock.json                # immutable record of launch parameters
        relay/                           # child workflow private state
          batch.json
          plan.json
          events.ndjson
          archive/
          prompts/
          handoffs/
          review-findings/
          last-messages/
      scratch/
```

**Rooting rules:**
- All paths derive from `pipeline_root`, recorded in `state.json`.
- **Path canonicalization:** Values stored in `state.json.pipeline_root` and `phase.json.adapter.relay_root` are always repo-root-relative strings (e.g., `.pipeline`, not absolute paths). All path resolution at runtime prepends the repo root obtained from `git rev-parse --show-toplevel`. Absolute paths are never stored. Path comparisons use normalized repo-root-relative form, not string equality.
- Execute child workflow derives all paths from `relay_root = {pipeline_root}/phases/{phase_id}/runtime/relay`.
- Resume resolves roots from stored repo-root-relative values, never from cwd.

## state.json — Thin Active Index

```json
{
  "schema_version": 2,
  "pipeline_id": "2026-03-18-example",
  "pipeline_root": ".pipeline",
  "repo_root": "/Users/petepetrash/Code/capacitor",
  "status": "active",
  "updated_at": "2026-03-18T19:24:00Z",
  "active_epoch_id": "epoch-001",
  "current_phase_id": "phase-002-align",
  "mission_version": {
    "path": ".pipeline/mission/mission-v001.md",
    "sha256": "sha256:..."
  },
  "active_constraint_set": {
    "path": ".pipeline/constraints/sets/constraint-set-001.json",
    "sha256": "sha256:..."
  },
  "latest_resume": {
    "phase_id": "phase-002-align",
    "path": ".pipeline/phases/phase-002-align/artifacts/resume.md",
    "sha256": "sha256:..."
  },
  "child_workflow": null
}
```

**Statuses:** `active`, `waiting_user`, `blocked`, `complete`.

**Size target:** <2KB. No phase arrays, no historical gate results, no per-phase deltas. Those live in `phases/{id}/phase.json`.

## phase.json — Per-Phase Metadata

Each phase owns its durable metadata. Example for an align phase:

```json
{
  "schema_version": 2,
  "phase_id": "phase-002-align",
  "kind": "align",
  "epoch_id": "epoch-001",
  "status": "completed",
  "mode": "interactive",
  "skill": "solution-explorer",
  "lineage": {
    "origin_phase_id": "phase-001-triage",
    "origin_event": "gate_passed",
    "reason": "alignment_needed"
  },
  "constraint_delta": {
    "fixed": ["Pin persistence is Swift-owned app setting."],
    "eliminated": ["Rust-owned runtime truth for pin state."],
    "remaining": []
  },
  "gate_result": {
    "gate_id": "execution_readiness_v1",
    "status": "passed",
    "checked_at": "2026-03-18T19:00:00Z",
    "evidence_paths": [
      ".pipeline/phases/phase-002-align/artifacts/execution-spec.md",
      ".pipeline/phases/phase-002-align/artifacts/verification-plan.md"
    ],
    "blocking_gaps": []
  },
  "artifact_manifest": {
    "lock_state": "locked",
    "items": [
      {
        "artifact_id": "execution-spec",
        "role": "output",
        "path": ".pipeline/phases/phase-002-align/artifacts/execution-spec.md",
        "sha256": "sha256:...",
        "recorded_at": "2026-03-18T18:55:00Z",
        "locked_at": "2026-03-18T19:00:00Z"
      }
    ]
  },
  "timestamps": {
    "created_at": "2026-03-18T18:30:00Z",
    "started_at": "2026-03-18T18:31:00Z",
    "completed_at": "2026-03-18T19:00:00Z"
  }
}
```

Example for an execute phase:

```json
{
  "schema_version": 2,
  "phase_id": "phase-003-execute",
  "kind": "execute",
  "epoch_id": "epoch-001",
  "status": "in_progress",
  "mode": "autonomous",
  "skill": "manage-codex",
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
  "child_workflow": {
    "status": "reviewing",
    "progress_summary": "Reviewing slice-002 of 4.",
    "counts": {
      "total_slices": 4,
      "completed_slices": 1,
      "review_rejections": 0,
      "convergence_attempts": 0
    },
    "last_checkpoint_at": "2026-03-18T19:24:00Z",
    "verdict": null
  },
  "constraint_delta": {
    "fixed": ["Implementation uses Swift-owned persistence from align spec."],
    "eliminated": ["Worker choosing persistence strategy."],
    "remaining": []
  },
  "gate_result": null,
  "artifact_manifest": {
    "lock_state": "mutable",
    "items": [
      {
        "artifact_id": "manage-codex-header",
        "role": "input",
        "path": ".pipeline/phases/phase-003-execute/artifacts/manage-codex-header.md",
        "sha256": "sha256:...",
        "recorded_at": "2026-03-18T19:02:00Z",
        "locked_at": null
      }
    ]
  },
  "timestamps": {
    "created_at": "2026-03-18T19:01:00Z",
    "started_at": "2026-03-18T19:02:00Z",
    "completed_at": null
  }
}
```

Note: `child_workflow` is a cached mirror of `adapter-status.json` — see Live-State Authority Matrix for which surface is authoritative.

## Phase Slot Interface

Each phase is a pluggable slot:

| Field | Purpose |
|---|---|
| `kind` | Phase type: `triage`, `align`, `execute`, or future types |
| `skill` | Which skill to invoke (e.g., `pipeline`, `solution-explorer`, `manage-codex`) |
| `mode` | `interactive` (architecture judgment allowed) or `autonomous` (zero architecture judgment) |
| `input_contract` | What artifacts the phase reads (as path + hash pointers) |
| `output_contract` | What artifacts the phase must produce |
| `gate` | Criteria that must pass before the next phase starts |

**v1 standard slots:**

| Kind | Default Skill | Mode | Primary Output |
|---|---|---|---|
| `triage` | `pipeline` | interactive | `output.md` (goal, non-goals, unknowns, recommended phases) |
| `align` | `solution-explorer` or `write-a-prd` | interactive | `execution-spec.md` + `constraints.json` + `verification-plan.md` (`decision-log.md` recommended) |
| `execute` | `manage-codex` | autonomous | Child workflow summary in `output.md` |

## Triage Phase

**Purpose:** Classify the task and decide which phases are needed.

**Fast-path bypass:** Triage can skip directly to execute when the task has no architectural ambiguity. The model is the classifier — it considers: scope size, boundary crossings, persistence/concurrency/API surface, and whether verification is obvious. This is judgment, not a file-count heuristic.

**Outputs:** Normalized goal, explicit non-goals, unknowns, recommended next phases, fast-path decision.

**Gate:** Pass to align if ambiguity remains. Pass to execute if the task is already execution-ready.

## Align Phase

**Purpose:** Collapse solution ambiguity into constraints tight enough for autonomous execution.

**May invoke sub-skills:** `brainstorming`, `solution-explorer`, `architecture-exploration`, `write-a-prd`, or domain-specific skills.

**Output artifacts:**
- `execution-spec.md` — one chosen approach with scope, ownership, behavior, edge cases
- `constraints.json` — machine-validatable constraint contract
- `verification-plan.md` — exact verification commands
- `decision-log.md` — recommended in v1 for rejected alternatives with reasons
- `open-questions.md` — must be empty before gate passes

**Gate:** Execution Readiness Gate (see below).

### constraints.json Schema

The align phase produces `artifacts/constraints.json` — the machine-validatable constraint contract. When the gate passes, this file is promoted (copied) to `.pipeline/constraints/sets/constraint-set-{NNN}.json` and `state.json.active_constraint_set` is updated to point at the promoted copy. The per-phase artifact and the promoted set are the same content; the promotion step gives the pipeline a stable cross-phase reference.

```json
{
  "schema_version": 1,
  "produced_by_phase": "phase-002-align",
  "goal": "Let users pin Worker Sessions so important sessions stay visible across relaunch.",
  "allowed_paths": [
    "apps/swift/Sources/Capacitor/Models/AppState.swift",
    "apps/swift/Sources/Capacitor/Models/SessionStateManager.swift",
    "apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift"
  ],
  "forbidden_paths": [
    "core/capacitor-core/src/reduce/",
    "core/capacitor-core/src/domain/types.rs"
  ],
  "interface_changes": [
    "Add `pinnedSessionIDs: Set<String>` to AppState",
    "Add `togglePin(sessionID:)` method to SessionStateManager"
  ],
  "invariants": [
    "Pin state is Swift-owned; no Rust reducer changes",
    "Pinned sessions sort first within their project, then by existing freshness ordering"
  ],
  "verification_commands": [
    "swift test --package-path apps/swift --filter SessionStateManagerTests",
    "./scripts/dev/restart-alpha-stable.sh"
  ],
  "non_goals": [
    "No multi-user sync for pin state",
    "No runtime-service pin persistence"
  ],
  "open_questions": [],
  "success_criteria": [
    "Pinned sessions appear at top of project column",
    "Pin state persists across relaunch via UserDefaults"
  ]
}
```

**Required fields for gate validation:** `allowed_paths` (non-empty, no wildcards), `interface_changes` (non-empty for non-trivial work), `verification_commands` (non-empty), `non_goals` (non-empty), `open_questions` (must be empty array).

## Execution Readiness Gate

The critical boundary between interactive and autonomous work.

**Machine-checkable criteria:**
- `constraints.json` exists and validates against schema
- `allowed_paths` is explicit (no wildcards like "wherever needed")
- `interface_changes` is explicit (no "clean up internals" without named types/files)
- `verification_commands` is non-empty
- `non_goals` is non-empty
- `open_questions` is empty

**Human judgment criterion (the litmus test):**

> If two strong workers could read the execution packet and reasonably produce materially different architectures, the gate fails.

**Enforcement:** Any failed criterion blocks execute. A blocked gate appends a new interactive phase. The gate cannot be bypassed by prose — `update-pipeline.sh` enforces that execute phases cannot start unless the predecessor gate passed.

## Execute Phase

Execute is a **child workflow** behind an adapter boundary. The pipeline never reads `batch.json` directly.

**Adapter inputs:** `pipeline_root`, `phase_id`, `relay_root`, `execution_packet_path`, `execution_packet_sha256`, `verification_commands`, `success_criteria`.

**Adapter outputs (the only public surfaces):**
- `runtime/adapter-status.json` — current child workflow status
- `artifacts/output.md` — execute summary after completion
- `artifacts/gate-report.json` — exit verdict

**adapter-status.json (full schema):**
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
    "handoff_sha256": "sha256:...",
    "review_findings_path": ".pipeline/phases/phase-003-execute/runtime/relay/review-findings/review-findings-slice-002.md",
    "review_findings_sha256": "sha256:..."
  },
  "last_checkpoint_at": "2026-03-18T19:24:00Z",
  "verdict": null
}
```

**Status values:** `not_started`, `planning`, `implementing`, `reviewing`, `reworking`, `converging`, `complete`, `blocked`, `drifted`.

## Live-State Authority Matrix

| Surface | Writer | Reader | Authoritative When |
|---|---|---|---|
| `state.json` | Pipeline orchestrator only | Orchestrator, resume logic | Always (derived index) |
| `phases/{id}/phase.json` | Pipeline orchestrator only | Orchestrator, sub-skills | Phase is active or completed |
| `events.ndjson` | `update-pipeline.sh` only | Rebuild logic, retro analysis | Always (append-only truth) |
| `adapter-status.json` | Execute adapter only | Pipeline orchestrator | Child workflow is active |
| `adapter-lock.json` | Execute adapter (once, at attach) | Pipeline orchestrator, resume | Always after creation (immutable) |
| `runtime/relay/*` | manage-codex (via `update-batch.sh`) | Execute adapter only | During execution |

**Child workflow status authority:** `adapter-status.json` is authoritative for child workflow status while `adapter-lock.json` exists and `adapter-status.json.last_checkpoint_at` is within the stale threshold (30 minutes). `phase.json.child_workflow` and `state.json.child_workflow` are cached mirrors — they are always overwritten by the next `child_checkpoint` event and never read as truth during active execution. When these surfaces disagree, `adapter-status.json` wins unconditionally.

**Resume reconciliation order:**
1. Read `state.json` → resolve `pipeline_root` by prepending `git rev-parse --show-toplevel` to the stored repo-root-relative root
2. If `child_workflow` is non-null, read `adapter-status.json`
3. If adapter-status is fresher than `state.json.updated_at`, copy adapter status into `state.json.child_workflow` and `phase.json.child_workflow` via a `child_checkpoint` event (reconcile forward)
4. If adapter-status is stale (no checkpoint in >30 minutes of wall time), mark status `stale_child` and surface to user
5. Verify locked artifact hashes before trusting any historical phase
6. Never dispatch a new child workflow if `adapter-lock.json` exists and `adapter-status.json` is not terminal

**Duplicate dispatch prevention:** `adapter-lock.json` is written once at child workflow attach. Resume checks for its existence before creating a new child. If lock exists and adapter-status is non-terminal, the child is still running (or crashed) — surface to user, do not re-dispatch.

## Forward-Only with Epochs

When execution reveals the approach was wrong:
1. Active phases get `status: "superseded"` with `superseded_by` pointer
2. `active_epoch_id` increments in `state.json`
3. New phase inserted with `lineage.origin_reason: "discovered_constraint_gap"`
4. Old artifacts preserved for auditability — completed phases are never modified
5. Only the active epoch's constraint set is authoritative

## Artifact Immutability Protocol

**Recording:** When an artifact is registered, `update-pipeline.sh` computes its SHA-256 and records path + hash in `phase.json`.

**Locking:** When `phase_completed` fires, the script re-hashes all required output artifacts. The `phase_completed` event in `events.ndjson` records the final hash list. `phase.json.artifact_manifest.lock_state` flips to `locked`.

**Resume drift check:** On cold resume, re-hash every locked artifact referenced by the current phase chain. If any hash differs, record `artifact_drift_detected` and stop automatic resume. Intentional changes must happen in a new successor phase.

## update-pipeline.sh Interface

Root-first. All paths derived from `--root`.

```bash
# Initialize
./scripts/pipeline/update-pipeline.sh --root .pipeline --event init_pipeline --mission-path .pipeline/mission/mission-v001.md

# Phase lifecycle
./scripts/pipeline/update-pipeline.sh --root .pipeline --event phase_added --phase phase-002-align --kind align --skill solution-explorer --mode interactive
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event phase_started
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event artifact_recorded --artifact-id execution-spec --artifact .pipeline/phases/phase-002-align/artifacts/execution-spec.md --role output
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event phase_completed

# Gate
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event gate_passed --summary "Execution readiness confirmed"
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-002-align --event gate_failed --summary "open_questions nonzero"

# Execute child workflow
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-003-execute --event child_checkpoint --status reviewing --summary "Reviewing slice-002 of 4"

# Epoch transition
./scripts/pipeline/update-pipeline.sh --root .pipeline --phase phase-003-execute --event superseded --by phase-004-align

# Completion
./scripts/pipeline/update-pipeline.sh --root .pipeline --event pipeline_completed

# Maintenance
./scripts/pipeline/update-pipeline.sh --root .pipeline --validate
./scripts/pipeline/update-pipeline.sh --root .pipeline --rebuild
```

**Event table:**

| Event | Required Args | Effect |
|---|---|---|
| `init_pipeline` | `--root`, `--mission-path` | Creates pipeline directory, `plan.json`, and initial `state.json` |
| `phase_added` | `--phase`, `--kind`, `--skill`, `--mode` | Creates `phases/{id}/phase.json` and subdirectories |
| `phase_started` | `--phase` | Marks phase `in_progress`, updates `current_phase_id` |
| `artifact_recorded` | `--phase`, `--artifact-id`, `--artifact`, `--role` | Hashes file, records in `phase.json.artifact_manifest` |
| `phase_completed` | `--phase` | Re-hashes all required artifacts, locks manifest, marks phase done |
| `gate_passed` | `--phase`, `--summary` | Records passed gate in `phase.json.gate_result`, enables next phase |
| `gate_failed` | `--phase`, `--summary` | Records failed gate, blocks autonomous phase progression |
| `child_checkpoint` | `--phase`, `--status`, `--summary` | Copies adapter status into `phase.json.child_workflow` and `state.json.child_workflow` |
| `superseded` | `--phase`, `--by` | Marks phase `superseded`, sets `superseded_by`, increments `active_epoch_id` |
| `constraint_set_activated` | `--constraints-path` | Updates `state.json.active_constraint_set` pointer and hash |
| `mission_activated` | `--mission-path` | Updates `state.json.mission_version` pointer and hash |
| `artifact_drift_detected` | `--phase`, `--artifact-id` | Records drift, blocks automatic resume |
| `pipeline_completed` | (none beyond `--root`) | Clears `current_phase_id`, marks `status=complete`, appends retrospective |

**Validation rules:**
- `state.json` < 2048 bytes
- Exactly one phase `in_progress`
- `current_phase_id` exists if present
- Locked artifacts match recorded hashes
- `pipeline_root` matches invoked `--root`
- Execute phases have `adapter.relay_root`
- No execute phase starts unless predecessor gate passed

## update-batch.sh Changes

Add `--root` flag that threads through all path derivation:

```bash
./scripts/relay/update-batch.sh \
  --root .pipeline/phases/phase-003-execute/runtime/relay \
  --slice slice-001 --event attempt_started
```

Derived paths: `{root}/batch.json`, `{root}/plan.json`, `{root}/events.ndjson`, `{root}/archive/`, `{root}/handoffs/`, `{root}/review-findings/`, `{root}/prompts/`.

**Backward compatibility:** When `--root` is omitted, defaults to `.relay/` (existing standalone behavior preserved).

## compose-prompt.sh Changes

Add `--root` flag. Worker output paths in templates use `{root}/handoffs/` and `{root}/review-findings/` instead of hardcoded `.relay/`.

## Pipeline Retrospective (Self-Improvement)

When `pipeline_completed` fires, `update-pipeline.sh` computes and appends a `pipeline_retrospective` event:

```json
{
  "ts": "2026-03-18T20:30:00Z",
  "event": "pipeline_retrospective",
  "pipeline_id": "2026-03-18-example",
  "metrics": {
    "total_phases": 3,
    "epoch_resets": 0,
    "gate_failures": 0,
    "gate_failure_reasons": [],
    "rework_phases": 0,
    "triage_to_execute_minutes": 45,
    "execute_slices": 3,
    "execute_review_rejections": 1,
    "execute_convergence_attempts": 1,
    "fast_path_used": false
  }
}
```

**v2 extension:** A `/pipeline-retro` skill reads accumulated retrospective events across archived pipelines, surfaces patterns (recurring gate failures, rework hotspots, token budget violations), and proposes concrete changes to the SKILL.md and scripts.

## SKILL.md Outline

Target ~130 lines. Section line counts below are approximate guidance, not normative limits.

```
---
name: pipeline
description: >
  Multi-phase development pipeline orchestrator. Use for /pipeline
  when work needs deliberate triage, alignment, and autonomous execution.
---

# Pipeline

You are the pipeline orchestrator.
Your job is to shrink uncertainty phase by phase until autonomous execution is safe.

Loop: triage -> align -> execute
Append new phases when new information appears. Never reopen completed phases.

Done when: final phase complete, state.json clean, any child workflow reports complete.

## Principles                        [~8 lines]
## Filesystem Contract               [~10 lines]
## Setup & Resume                    [~12 lines]
## Triage                            [~15 lines: classify, fast-path, gate]
## Align                             [~20 lines: sub-skills, required artifacts, gate]
## Execution Readiness Gate          [~12 lines: criteria, litmus test, enforcement]
## Execute                           [~15 lines: adapter boundary, child workflow, summary]
## Forward-Only Rule                 [~8 lines: superseded status, epochs]
## Circuit Breakers                  [~6 lines: gate fails twice, architecture questions in execute, drift]
## User Briefing                     [~4 lines: one-line between phases, full on escalation/completion]
```

## Explicit Deferrals (v2 Hardening)

| Item | Why Deferred |
|---|---|
| Generic phase adapter registry | Execute needed an adapter immediately; triage/align can use skill contracts for v1 |
| Semantic closure fields (`decisions[]`, `prohibited_alternatives[]`) | The litmus test is the human gate for v1; structured commitments add schema complexity we haven't earned |
| Fine-grained constraint supersession | Phase-level deltas work for 1-2 epochs; typed constraint records needed at 5+ |
| Risk-based fast-path classifier | The model is the classifier for v1; structured risk signals needed after usage data |
| Crash-safe temp-directory promotion | Hash drift detection + stopping is sufficient for v1; transaction semantics needed for production |
| Immutable copies of external artifacts | Hash drift detection for v1; copied artifacts or git blob IDs for v2 |
| `/pipeline-retro` skill | Retrospective events ship in v1; the analysis skill ships in v2 |

## Artifacts Produced by This Design Process

| Artifact | Location |
|---|---|
| Original architecture proposal | `.relay/review-findings-slice-001.md` |
| Adversarial review (10 risks) | `.relay/review-findings-slice-002.md` |
| Design review (10 weaknesses) | `.pipeline/design-review.md` |
| Design v2 (addressed findings) | `.pipeline/design-v2.md` |
| Fresh v2 review | `.pipeline/design-v2-review.md` |
| This spec | `docs/superpowers/specs/2026-03-18-modular-pipeline-design.md` |
