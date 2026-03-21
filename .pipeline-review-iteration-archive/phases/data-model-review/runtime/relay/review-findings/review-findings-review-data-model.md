## Ship Review: Review the proposed numbered milestones data model

### ISSUES
- `Resume` is not bound to the active milestone identity. Swift already sends `milestone_id`, `brief_path`, and `manifest_path` when a review decision is submitted (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:436-449`), but the reducer ignores those fields on `Resume` and clears whichever pending review exists (`core/capacitor-core/src/reduce/mod.rs:378-427`). With numbered history, a stale approve or request-changes action can resume or complete the wrong milestone.
- Multiple workers per project are still blocked above the disk layout. The reducer stores delegations in `BTreeMap<String, ProjectDelegationState>` keyed by `project_path` (`core/capacitor-core/src/reduce/mod.rs:18-21,63-66`), `Start` rejects a second active delegation for the same project (`core/capacitor-core/src/reduce/mod.rs:234-243`), and Swift mirrors that singleton shape in `delegationStates: [String: RuntimeDelegationState]` (`apps/swift/Sources/Capacitor/Models/AppState.swift:101,1550-1553`). Per-worker milestone numbering is fine on disk, but the overall model is not concurrency-ready yet.
- Review readiness is still inferred from file existence only. Current reconciliation promotes a review as soon as `brief.md` and `manifest.json` both exist and no `decision.json` is present (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:544-569`). Extending that rule to numbered milestones leaves a race where partially written artifacts can surface as review-ready, and "pick the highest undecided milestone" can silently hide multiple undecided directories instead of flagging corruption.

### CONCERNS
- The proposal's `nextMilestoneID()` directory scan is weaker than deriving the successor from `current_review.milestone_id + 1`. Crash residue like an empty `02/` can cause skipped numbers or ambiguous lineage if the next milestone is inferred from disk instead of from the currently reviewed milestone.
- History lineage is only implied by directory order. Adding `supersedes_milestone_id` to each manifest or `next_milestone_id` to `decision.json` would make repair and audit much easier if gaps or retries ever occur.
- Test coverage is still single-milestone. The reducer and Swift delegation tests only exercise `milestones/01` (`core/capacitor-core/tests/delegation_contract.rs:42-57,127-141`, `apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift:78-90,244-259`). There is no regression coverage for second-pass review readiness, stale milestone rejection, empty-gap handling, or multiple undecided milestone detection.

### POSITIVE
- The current mutation vocabulary is close to sufficient. `ReviewReady` already accepts arbitrary milestone IDs and paths (`core/capacitor-core/src/reduce/mod.rs:318-376`), so review iteration can fit without inventing a completely new mutation family.
- The per-worker disk layout is clean. Keeping milestone history under `.capacitor/delegations/<worker>/milestones/` localizes state and avoids filename collisions between workers.
- The current review UI already renders the active `current_review` milestone dynamically (`apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift:41-43,113-131,242-259`), so it can follow numbered milestones once reconciliation selects the correct active review.

### VERDICT
ISSUES FOUND
