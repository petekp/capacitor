# Work Batch Routing Implementation Adversarial Review 01

Date: 2026-05-25

Scope: implementation of the Work Batch Binding Reconciliation and Delivery Policy slice against `CONTEXT.md` and `docs/circuit/task-work-batch-routing-edge-case-plan.md`.

## Sources Checked

- `CONTEXT.md:7-16`: Task capture should bias toward execution; checkpoints are safeguards, not preflight forms.
- `CONTEXT.md:35-56`: Batch Cockpit Binding, Batch Cockpit Recovery, Quiet Execution, Work Batch Context Mirror, and Batch Routing Slice definitions.
- `CONTEXT.md:79-112`: Open Batch, Batch Classification, Non-Disruptive Delivery, Task Session, and Batch Worktree definitions.
- `docs/circuit/task-work-batch-routing-edge-case-plan.md:86-118`: related Task delivery into healthy and stale bindings.
- `docs/circuit/task-work-batch-routing-edge-case-plan.md:138-180`: manual batch-worktree sessions, duplicate sessions, and exact cockpit opening.
- `docs/circuit/task-work-batch-routing-edge-case-plan.md:196-224`: idempotent reroute and stale visible summary acceptance.
- `docs/circuit/task-work-batch-routing-edge-case-plan.md:263-346`: required implementation steps.

## Implementation Checks

- Reconciler is pure and uses runtime session `sessionId` plus Batch Worktree path matching before changing binding state: `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:24-98`.
- Manual root sessions are not adopted because matching requires the session cwd or project path to be inside the Batch Worktree: `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:116-128`.
- Duplicate same-worktree sessions are treated as suspicious and keep unfinished Tasks queued: `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:46-62`.
- Runtime snapshots now feed Work Batch reconciliation before effects continue: `apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift:208-216`.
- Existing related Tasks rewrite the mirror and queue visibly without starting another process when the binding is healthy: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:137-193`.
- Stale/waiting/done bindings resume via the stored binding in the Batch Worktree: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:163-177` and `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:394-427`.
- Opening a running cockpit focuses first and stops before resume if focus fails: `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:403-439`.
- Projection priority now makes waiting or newly queued Work Batch state beat older working summaries: `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:254-299`.
- User-facing open failures preserve plain router/coordinator reasons instead of hiding them behind a generic toast: `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:441-459`.

## Tests And Manual Evidence

- Focused slice: `swift test --package-path apps/swift --filter 'WorkBatch|ProjectCardContextLineResolverTests|AppStateRuntimeSnapshotEffectTests'` passed, 65 tests.
- Full Swift: `swift test --package-path apps/swift` passed, 795 XCTest cases with 1 skipped and 0 failures, plus 19 Swift Testing tests.
- App restart: `./scripts/dev/restart-alpha-stable.sh` rebuilt and relaunched `CapacitorDebug` with `hud-hook serve --port 7474`.
- Live `arc-design-studio` state check: `Mobile Prototype Polish` is `waiting`, its green-border Task is `queued`, and its Batch Cockpit Binding is `stale` with the stored Claude session id.
- Scoped whitespace check over the touched Swift files passed. Global `git diff --check` is still blocked by unrelated trailing whitespace in `.claude/dead-code-report.md`, which predates this slice.

## Findings

- No medium, high, or critical findings.

Low residual risks:

- Running Claude sessions are not force-injected with new Task text. The Task is queued and the context mirror is rewritten, which matches the non-disruptive delivery policy for this slice.
- The live manual check exercised the stale binding path in `arc-design-studio`; duplicate and healthy-focus paths are covered by tests rather than by opening extra real Claude sessions.
- A duplicate-cockpit Task route still records the Task as added while the card becomes `waiting` with the duplicate reason. That is acceptable for this slice because the Work Batch surface carries the recovery state.

## Result

Clean for medium-or-above findings.
