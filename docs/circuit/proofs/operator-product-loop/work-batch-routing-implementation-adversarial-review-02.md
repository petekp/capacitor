# Work Batch Routing Implementation Adversarial Review 02

Date: 2026-05-25

Scope: second clean adversarial review of the same implementation after Review 01.

## Rechecked Failure Modes

- A captured Task still routes automatically through the Work Batch path rather than requiring method selection.
- Related Tasks join the existing Work Batch and do not launch a duplicate Claude process when a live exact binding exists.
- Stale bindings reconnect through `claude --resume <stored session id>` in the Batch Worktree.
- Project-root manual Claude sessions are not silently adopted as Work Batch cockpits.
- A same-worktree different Claude session id is treated as duplicate/waiting, not silently adopted.
- Re-routing one Task id cleans old batch membership.
- Persistent healthy, stale, and duplicate reconciliation states do not rewrite timestamps every snapshot.
- Batch projection priority prevents unrelated older work, such as a footer breakpoint summary, from outranking newly queued or waiting mobile prototype work.
- The slice remains Claude Code only and does not introduce old Circuit runtime, runner/flow-engine behavior, task DAGs, broad memory, generalized multi-host routing, SaaS framing, or preflight method selection.

## Evidence

- Reconciler tests cover exact live match, missing session, launch grace, manual root non-adoption, duplicate same-worktree sessions, and no-churn steady states: `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift:6-175`.
- Router tests cover new batch launch, related existing batch queueing, stale resume, reroute cleanup, duplicate no-resume, and duplicate open refusal: `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:7-57`, `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:107-180`, `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:568-752`.
- Task session tests cover focus-without-resume, focus-failure-without-resume, and stale resume in the Batch Worktree: `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:55-169`.
- Projection tests cover waiting and queued Work Batches outranking older working summaries: `apps/swift/Tests/CapacitorTests/WorkBatchStateTests.swift:143-194`.
- Runtime snapshot integration test covers AppState applying a snapshot and reconciling a stale binding to running: `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift:54-153`.
- Final verification repeated the focused slice and full Swift suite after the last code change.

## Findings

- No medium, high, or critical findings.

Low residual risks:

- If a Task is captured before any runtime snapshot has arrived, the router can only use persisted binding status until the first snapshot reconciles it. This is acceptable because snapshot reconciliation is now wired into app refresh.
- Full Done callback semantics are intentionally still outside this slice. Tasks can remain queued/open until the future Done/Unresolve path lands.

## Result

Second consecutive clean review for medium-or-above findings.
