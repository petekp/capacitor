# Data Model Review: Numbered Milestones for Delegation Review Iteration

## What You're Reviewing

A proposed data model change to support review iteration in Capacitor's delegation system. Currently, milestones are hardcoded to a single directory (`milestones/01/`). The proposal introduces numbered milestones so users can request changes and get revised milestones for re-review.

## Proposed Data Model

### Disk Layout
```
.capacitor/delegations/<worker>/
  status.md
  completion.json
  launch-prompt.md
  resume-prompt.md
  milestones/
    01/                          # first milestone
      brief.md
      manifest.json
      decision.json              # user's decision
      decision.md
    02/                          # revision after request-changes
      brief.md
      manifest.json
      decision.json
      decision.md
    03/                          # current active review (no decision yet)
      brief.md
      manifest.json
```

### Rules
- Each `request_changes` decision creates the next numbered directory
- The worker writes revision artifacts into the next number
- The highest-numbered milestone without `decision.json` is the active review
- Milestones with `decision.json` are immutable history
- `approve` on any milestone triggers completion

### Rust Reducer Impact
- `MutateDelegationCommand` already has `milestone_id: Option<String>` — currently always "01"
- The reducer's `ReviewReady` handler stores whichever milestone ID is passed
- No new mutation kinds needed

### Swift Changes
- `Constants.milestoneID = "01"` replaced by computed `nextMilestoneID()` scanning milestones dir
- `workerPaths()` takes milestone ID parameter
- Reconciliation scans for highest-numbered milestone with `brief.md` + `manifest.json` but no `decision.json`
- Resume prompt tells worker to write to next milestone number
- `submitReviewDecision()` writes `decision.json` to current milestone, tells worker to write to next

### Worker Prompt Changes
- Launch: "Write milestone artifacts to milestones/01/" (same)
- Resume after request-changes: "Write revised artifacts to milestones/02/" (new)
- Resume after approve: "Finalize and write completion marker" (same intent)

## Your Task

Review this data model for:

1. **Structural soundness** — Does the numbered milestone model support the intended review iteration loop without ambiguity?
2. **Race conditions** — Can the reconciliation loop and the worker conflict? What if the worker is still writing when reconciliation scans?
3. **Edge cases** — What happens if a worker crashes mid-write? What if milestones/02/ exists but is empty? What if the user approves milestone 01 while 02 already exists?
4. **Reducer compatibility** — Does the existing `DelegationMutationKind` vocabulary handle all the needed state transitions, or are there gaps?
5. **Concurrency readiness** — This model should eventually support multiple workers per project. Does the per-worker milestone numbering conflict with that?
6. **Disk layout** — Is the directory structure clean? Any naming or organization issues?

## Files to Read

- `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` — current reconciliation, worker paths, resume prompts
- `core/capacitor-core/src/domain/types.rs` — `DelegationMutationKind`, `MutateDelegationCommand`, `ProjectDelegationState`
- `core/capacitor-core/src/reduce/mod.rs` — delegation reducer logic
- `docs/plans/orchestrator-status.md` — current state assessment
- `.pipeline/mission/mission-v001.md` — mission context

---
# Review Worker

Diagnose only. Do not modify source.

Read `AGENTS.md`. Re-run verification yourself; do not trust prior reports.

Classify failures:
- real: assertion failures, logic bugs, lint or format drift
- `SANDBOX_LIMITED`: permission denied bind, `sandbox-exec`, manifest or file-access
  restrictions

Check:
- correctness, invalid input handling, empty states, and edge cases
- concurrency or shared-state risks
- operational boundaries, dependency direction, and API surface
- residue: dead code, stale docs, TODO, FIXME, HACK, or temporary scaffolding
- tests that miss behavior, error paths, or public-interface coverage

---
# Ship Review

Audit the current code in the stated scope. There is no worker diff.

Review target:
{slice.task}

Success criteria: {slice.success_criteria}

Rerun every verification command from the header and judge the current state against the
criteria above.

Write `.pipeline/phases/data-model-review/runtime/relay/review-findings/review-findings-{slice_id}.md`:

```markdown
## Ship Review: {slice.task}

### ISSUES
### CONCERNS
### POSITIVE
### VERDICT
CLEAN or ISSUES FOUND
```

Write `.pipeline/phases/data-model-review/runtime/relay/handoffs/handoff-{slice_id}.md` with:

### Files Changed
None - review only.

### Tests Run
Exact command, pass or fail count, failures; mark sandbox-caused failures
`SANDBOX_LIMITED`.

### Verification
If `./scripts/verify/verify.sh` ran, report the result. Otherwise say not run.

### Verdict
`CLEAN` or `ISSUES FOUND`

### Completion Claim
`COMPLETE`, `PARTIAL`, or `BLOCKED`

### Issues Found
Concrete problems or unresolved concerns.

### Next Steps
If `PARTIAL` or `BLOCKED`, name the next concrete action.
