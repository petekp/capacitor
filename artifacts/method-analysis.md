# Janitor Method Analysis

## Recommended Method Family

`method:janitor` is an artifact-centric delivery method.

Reasoning:
- The workflow ends in real source changes plus a terminal verification artifact, not a symbolic trace of another method.
- Every major phase naturally promotes a durable artifact that becomes the next phase's input.
- The dual-mode requirement changes approval mechanics, not the family. Interactive and autonomous runs still traverse the same artifact chain.
- Circuit breaker is not triggered. The workflow fits the live contract cleanly once mode is modeled as step-local behavior instead of duplicated topology.

## Phase Topology

Recommended topology: 5 serial phases, 8 total steps.

| Phase | Step | Action | Produces | Notes |
|---|---|---|---|---|
| Survey | 1. Cleanup Scope | interactive | `cleanup-scope.md` | Records `MODE`, target root, build/test/verify commands, exclusions, external-consumer notes, and risk boundaries. |
| Survey | 2. Category Survey Fanout | dispatch, parallel | `dead-code-findings.md`, `stale-docs-findings.md`, `orphaned-artifacts-findings.md`, `vestigial-comments-findings.md`, `redundant-abstractions-findings.md` | Fixed 5-worker fanout by detritus category. |
| Survey | 3. Survey Consolidation | synthesis | `survey-inventory.md` | Normalizes category findings into one canonical inventory. |
| Triage | 4. Triage Classification | synthesis | `triage-report.md` | Single topology step with mode-conditional approval behavior. |
| Prove | 5. Evidence Adjudication | dispatch | `evidence-log.md` | Proves or clears items marked `PROVE`, and can reopen triage if assumptions collapse. |
| Clean | 6. Cleanup Batch Execution | dispatch via `manage-codex` | `cleanup-batches.md` | One topology step containing an ordered per-batch execution loop. |
| Verify | 7. Verification Audit | dispatch | `verification-audit.md` | Diagnose-only assessment pass. No source edits. |
| Verify | 8. Verification Synthesis | synthesis | `verification-report.md` and `deferred-review.md` in autonomous mode | Terminal report and deferred-review publication. |

Why this shape is cleaner than the raw candidate list:
- Phase count stays at the corpus norm of 5.
- Step count reaches 8, which matches the live corpus better than a collapsed 5-step version.
- Parallelism is used only once, inside one survey step, which matches live method conventions.
- The verify phase gets an explicit diagnose-only assessment step before the terminal report, which is where the false-positive protection actually lives.

## Step Inventory

### Step 1: Cleanup Scope

- Action: `interactive`
- Produces: `cleanup-scope.md`
- Required sections:
  - `## Target Root`
  - `## Mode`
  - `## Build Command`
  - `## Test Command`
  - `## Optional Verify Command`
  - `## Scope Exclusions`
  - `## Known External Consumers`
  - `## High-Risk Boundaries`
- Purpose:
  - Freeze the runtime inputs before any scanning starts.
  - Make autonomous runs mechanically reproducible.
  - Surface the comp-sci-heavy part early: "dead" is a reachability claim, and reachability depends on dynamic dispatch, FFI, codegen, and external consumers, not just grep.

### Step 2: Category Survey Fanout

- Action: `dispatch`
- Execution: `parallel`
- Workers:
  - `dead-code`
  - `stale-docs`
  - `orphaned-artifacts`
  - `vestigial-comments`
  - `redundant-abstractions`
- Produces:
  - `dead-code-findings.md`
  - `stale-docs-findings.md`
  - `orphaned-artifacts-findings.md`
  - `vestigial-comments-findings.md`
  - `redundant-abstractions-findings.md`
- Recommendation: use the parallel shape, not one comprehensive worker.
- Reasoning:
  - The five categories are stable and semantically distinct, so worker prompts stay narrower and more accurate.
  - Category-specific heuristics reduce false positives. "Unused export" and "stale doc" need different proof standards.
  - The fanout stays inside one topology step, which is exactly how the live corpus models bounded parallelism.

### Step 3: Survey Consolidation

- Action: `synthesis`
- Consumes all five category findings plus `cleanup-scope.md`
- Produces: `survey-inventory.md`
- Purpose:
  - Deduplicate cross-category findings.
  - Normalize severity, paths, line references, and category names.
  - Create the single canonical inventory that downstream steps consume.

### Step 4: Triage Classification

- Action: `synthesis`
- Consumes: `survey-inventory.md`, `cleanup-scope.md`
- Produces: `triage-report.md`
- Recommended type: `synthesis` with an interactive approval slow-path, not `interactive` with an autonomous fast-path.
- Reasoning:
  - The core job is artifact authorship: classify each finding into confidence, risk, and action.
  - That artifact must exist in both modes with the same structure.
  - The user checkpoint is a gate on a drafted artifact, not a different topology step.
  - In method terms, action type should describe who writes the canonical artifact. Here the orchestrator should always write it.

### Step 5: Evidence Adjudication

- Action: `dispatch`
- Consumes: `triage-report.md`, `cleanup-scope.md`
- Produces: `evidence-log.md`
- Recommendation: keep this as a single worker, not a second parallel fanout.
- Reasoning:
  - Proof work needs one consistent standard across git history, dynamic usage, and external-consumer checks.
  - Splitting proof by category risks inconsistent dead/keep thresholds for the same symbol family.

### Step 6: Cleanup Batch Execution

- Action: `dispatch`
- Adapter: `manage-codex`
- Consumes: `triage-report.md`, `evidence-log.md`, `cleanup-scope.md`
- Produces: `cleanup-batches.md`
- Recommendation: use `manage-codex` here, and only here.
- Reasoning:
  - This is the only step that mutates source.
  - It needs ordered slices, per-slice verification, review/converge behavior, and reliable resume after interruption.
  - Survey and Prove do not benefit from `manage-codex`; they are evidence collection, not implementation loops.

### Step 7: Verification Audit

- Action: `dispatch`
- Consumes: `cleanup-batches.md`, `triage-report.md`, `evidence-log.md`, `cleanup-scope.md`
- Produces: `verification-audit.md`
- Diagnose-only contract:
  - This step is assessment only - the worker does NOT modify source code.
  - If issues are found, remediation happens by reopening Clean or Prove, not by letting the audit worker fix code.

### Step 8: Verification Synthesis

- Action: `synthesis`
- Consumes: `cleanup-batches.md`, `verification-audit.md`, `triage-report.md`, `evidence-log.md`
- Produces:
  - `verification-report.md`
  - `deferred-review.md` when `MODE=autonomous`
- Purpose:
  - Publish the terminal verdict.
  - Collate all deferred items into one asynchronous review surface.
  - Preserve traceability from removed item -> reason -> evidence -> verification result.

## Action Map

| Step | Recommended action | Why |
|---|---|---|
| Cleanup Scope | `interactive` | Needs human-provided runtime inputs and risk boundaries. |
| Category Survey Fanout | `dispatch` | Mechanical search work with bounded independent workers. |
| Survey Consolidation | `synthesis` | Canonical artifact normalization belongs with the orchestrator. |
| Triage Classification | `synthesis` | Same artifact in both modes; mode changes approval, not authorship. |
| Evidence Adjudication | `dispatch` | Mechanical proof gathering with explicit verdict schema. |
| Cleanup Batch Execution | `dispatch` + `adapter: manage-codex` | Code edits, verification, revert behavior, and resume all live here. |
| Verification Audit | `dispatch` | Independent assessment should be externalized from the code-editing step. |
| Verification Synthesis | `synthesis` | Final verdict and deferred publication should be orchestrator-authored. |

## Dual-Mode Design

Use one topology. Mode changes gate behavior and eligible item sets inside the same step contracts.

### Mode model

- `MODE=interactive`
  - Step 4 pauses on a drafted `triage-report.md` for user review.
  - Step 6 pauses before each cleanup batch is dispatched.
  - High-risk items may proceed only after explicit user approval.
- `MODE=autonomous`
  - Step 4 auto-approves only items that are low-risk and either already high-confidence or later become confirmed-dead in Step 5.
  - Step 6 dispatches only auto-eligible batches.
  - Borderline items are never touched; they accumulate into the final `deferred-review.md`.

### Why triage should be `synthesis`

This is the cleaner option because it separates two different concerns:
- Artifact construction: deterministic classification of findings.
- Approval policy: whether a human must bless the classification before execution.

That separation matters architecturally. It keeps the artifact schema stable across modes, which makes resume and reopen logic far simpler. In other words, we avoid coupling the existence of the report to the existence of a live human checkpoint.

### Why Clean should stay one step

The per-batch loop is runtime choreography inside Step 6, not separate topology:
- compute ordered batches from triage + proof outputs
- in interactive mode, ask before each batch
- in autonomous mode, skip the ask and auto-dispatch only eligible batches
- append each batch result into the same canonical `cleanup-batches.md`

This preserves one topology while still honoring the brief's per-batch checkpoint rule.

### Autonomous safety rule

Autonomous mode should never remove an item merely because it was found. Removal eligibility is:
- low risk
- no unresolved external-consumer signal
- either `high-confidence` at triage or `CONFIRMED-DEAD` during proof
- included in a batch whose build/test gate passes

Everything else becomes deferred review, not silent keep/remove.

## Artifact Chain and Promotion Rules

### Canonical chain

```text
cleanup-scope.md
  -> survey-inventory.md
  -> triage-report.md
  -> evidence-log.md
  -> cleanup-batches.md
  -> verification-report.md
  -> deferred-review.md   [autonomous only]
```

### Non-canonical intermediate outputs

- Step 2 worker artifacts are intermediate findings, not canonical chain artifacts.
- Step 7 `verification-audit.md` is an intermediate assessment artifact normalized into `verification-report.md`.
- Step 6 per-batch `manage-codex` handoffs are relay state, not canonical artifacts.

### Promotion rules

- Step 2: all five category findings must exist and pass their schema checks before Step 3 promotes `survey-inventory.md`.
- Step 5: if the worker writes only `handoffs/handoff.md`, the orchestrator synthesizes `evidence-log.md` manually before promotion.
- Step 6: the orchestrator reads each batch's convergence artifact, `batch.json`, and last slice handoff, then appends a normalized entry into `cleanup-batches.md`.
- Step 8: `deferred-review.md` is synthesized from deferred sections accumulated in `triage-report.md`, `evidence-log.md`, `cleanup-batches.md`, and `verification-audit.md`. It is not written piecemeal as a canonical artifact earlier in the chain.

### Canonical schema expectations

- `survey-inventory.md`: one row per candidate with category, path, line or path anchor, rationale, and ambiguity flags
- `triage-report.md`: one row per survey item with confidence, risk, action (`REMOVE`, `PROVE`, `KEEP`, `DEFER`), and mode-approval status
- `evidence-log.md`: one block per proved item with evidence, verdict (`CONFIRMED-DEAD` or `KEEP`), and any triage adjustment
- `cleanup-batches.md`: ordered batch manifest with batch id, eligibility basis, files touched, verification commands, result (`REMOVED`, `REVERTED`, `DEFERRED`, `KEPT`)
- `verification-report.md`: final verdict, removal manifest, verification summary, reopen target if needed
- `deferred-review.md`: every untouched borderline item with current evidence, reason deferred, and suggested next human question

## Gate Plan

| Step | Gate type | Gate contract |
|---|---|---|
| Cleanup Scope | `outputs_present` | `cleanup-scope.md` must name target root, `MODE`, build command, test command, and at least one high-risk boundary or explicit `None`. |
| Category Survey Fanout | `outputs_present` | All five category findings must exist and each must include candidate paths plus a category-specific uncertainty note. |
| Survey Consolidation | `outputs_present` | `survey-inventory.md` must deduplicate overlaps, preserve category labels, and include ambiguity flags for every candidate. |
| Triage Classification | `outputs_present` | Every survey item must have confidence, risk, action, and rationale. In interactive mode, the artifact must record an approval or revision decision before the gate passes. In autonomous mode, the artifact must record the exact auto-approval rule and deferred counts. |
| Evidence Adjudication | `evidence-reopen` | Outcomes: `evidence_sufficient -> continue`; `queue_adjustment_required -> update triage-report.md`; `risk_boundary_invalidated -> interactive-reopen`. A reopen must name the governing item or boundary, not just say "needs review". |
| Cleanup Batch Execution | `outputs_present` | `cleanup-batches.md` must show ordered batches, a terminal disposition for every batch candidate, verification results after each executed batch, and explicit revert evidence for every failed batch. |
| Verification Audit | `outputs_present` | `verification-audit.md` must contain full build/test results, warning delta, diff sanity findings, manifest cross-check, and a candidate verdict. This step is diagnose-only. |
| Verification Synthesis | `verdict-consistency` | Outcomes: `clean`, `partial`, `reopen`. `clean` requires verification checks and removal manifest to agree. `partial` requires every unresolved item to appear in deferred review with no failing executed batch. `reopen` requires an exact failing boundary and named reopen target (`cleanup-batches.md`, `evidence-log.md`, or `triage-report.md`). |

### False-positive protection by stage

- Survey is intentionally recall-heavy and precision-light.
- Triage adds a confidence/risk matrix before any proof or deletion.
- Prove upgrades or clears only ambiguous items.
- Clean re-tests every executed batch and reverts failures.
- Verify uses an independent diagnose-only pass before publishing the final verdict.

## External Inputs and Notes

Required setup inputs:
- `TARGET_ROOT`
- `MODE` with allowed values `interactive` or `autonomous`
- `BUILD_CMD`
- `TEST_CMD`

Optional but recommended:
- `VERIFY_CMD` for project-specific structural verification
- `KNOWN_EXTERNAL_CONSUMERS` or explicit `unknown`
- `SCOPE_EXCLUSIONS`
- `WARNING_BASELINE_CMD` if warnings are not covered by build/test output

Notes:
- Keep `VERIFY_CMD` optional so the method stays generic, but wire it into Step 7 whenever provided.
- Do not encode a third mode for `--dry-run` in v1. If added later, treat it as an early stop after Step 5 with the same artifact schemas, not as a topology fork.
- Use project terms consistently in artifacts. For Capacitor specifically, prefer `Artifact`, `Worker`, `Orchestrator`, and `Decision` over ad hoc synonyms.

## Resume and Reopen Plan

### Resume order

Resume should be relay-first, then artifact-first:

1. Check the current step's relay directory for in-flight worker output.
2. Validate any step-local promoted artifact against its gate.
3. Resume from the first step whose artifact is missing or fails its gate.

### Step-specific resume notes

- Step 2: inspect each worker output separately; rerun only missing or gate-failing categories.
- Step 4: if `triage-report.md` exists but interactive approval is absent, resume inside Step 4 rather than restarting Survey.
- Step 5: if some proved items have verdicts and others do not, rerun proof only for unresolved items.
- Step 6: before re-dispatching any batch, inspect the batch child root's `batch.json`, then `handoffs/handoff-converge.md`, then the last slice handoff. Never rerun a converged batch.
- Step 7: if `verification-audit.md` exists and passes its gate, resume at Step 8.

### Reopen routing

- Reopen to `triage-report.md` when proof changes item classification or reveals wrong risk labels.
- Reopen to `evidence-log.md` when verification says a removed item lacked sufficient proof.
- Reopen to `cleanup-batches.md` when a verification failure is caused by a concrete executed batch.
- Reopen to `cleanup-scope.md` only when build/test/verify commands or target-root assumptions were wrong.

### Terminal verdict semantics

- `clean`: all executed removals verified, no unresolved failing boundary
- `partial`: executed removals verified, but deferred items remain for later human review
- `reopen`: at least one executed removal or proof boundary failed verification and must be revisited

## Adapter and Worker Contracts

### Survey workers

- Use standard `dispatch`, not `manage-codex`.
- Each worker owns one category only.
- Each worker writes its category artifact plus standard `handoffs/handoff.md`.
- Skill budget: 0-2 total skills. Prefer one domain skill only when the codebase needs language-aware analysis.
- Parallel completeness rule: the step passes only when all five worker artifacts exist and satisfy schema checks.

### Evidence worker

- Use standard `dispatch`, not `manage-codex`.
- Worker contract must include:
  - full text or digest of `triage-report.md`
  - exact list of `PROVE` items
  - required verdict vocabulary: `CONFIRMED-DEAD`, `KEEP`
  - explicit requirement to search outside the immediate directory when repository scope allows
  - explicit dynamic-usage checklist: reflection, FFI, generated code, macro expansion, string lookup, plugin registration, external consumers

### Clean adapter seam

Use `manage-codex` only in Step 6, with one child relay root per cleanup batch:

```text
${RUN_ROOT}/phases/step-6/batches/<batch-id>/
```

Required contract for each batch child root:
- create child root directories: `archive/`, `handoffs/`, `last-messages/`, `review-findings/`
- write `CHARTER.md` from the approved batch spec, including:
  - batch id and ordered item list
  - evidence references back to `triage-report.md` and `evidence-log.md`
  - allowed files or file scope
  - verification commands
  - explicit revert-on-failure rule
- compose the prompt with real `manage-codex` calls, not pseudocode
- require child files:
  - `CHARTER.md`
  - `batch.json`
  - `handoffs/handoff-<slice-id>.md`
  - `handoffs/handoff-converge.md`
- readback order after convergence:
  - `handoffs/handoff-converge.md`
  - `batch.json`
  - last implementation slice handoff
- outer synthesis rule:
  - append a normalized batch record into `cleanup-batches.md`
  - if convergence says `ISSUES REMAIN`, escalate instead of pretending the batch succeeded

### Why not `manage-codex` for Survey or Prove

`manage-codex` is a slice implementation loop. It shines when code changes must survive review and convergence. Survey and Prove are evidence-production steps, so a simpler dispatch contract is both cheaper and less error-prone.

## Inline Reference Requirements

The generated `SKILL.md` should inline the minimum reference pack needed for a fresh session to execute `method:janitor` without opening other docs:

- canonical header schema with exact relay headings
- triage decision table:
  - low-risk + high-confidence -> `REMOVE`
  - low-risk + low-confidence -> `PROVE`
  - high-risk + any ambiguity -> `PROVE` in interactive mode, `DEFER` in autonomous mode unless later explicitly approved by a human
- proof checklist for dynamic usage and external-consumer analysis
- per-batch `manage-codex` adapter contract, including child-root layout and readback order
- diagnose-only wording for Verification Audit
- resume rules, especially relay-first checks and batch-level resume
- bounded final verdict vocabulary and reopen targets

The generated `method.yaml` should contain only topology-level truth:
- phase ids, step ids, titles, actions
- consumes and produces
- parallel fanout shape
- gate types and outcome names
- `adapter: manage-codex` only on Cleanup Batch Execution

Anything involving concrete commands, child-root layout, approval wording, fallback synthesis, or proof heuristics belongs in `SKILL.md`, not `method.yaml`.
