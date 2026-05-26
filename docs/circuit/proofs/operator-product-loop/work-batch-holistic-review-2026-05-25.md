# Work Batch Holistic Review

Date: 2026-05-25
Scope: Capacitor Work Batch Task routing, delivery, cockpit re-entry, and visible batch-card behavior.

## Product Invariants

- Adding a Task should route and execute automatically.
- Related Tasks should join the right visible Work Batch/session.
- Unrelated Tasks should create separate visible Work Batches.
- Checkpoints are the alignment safeguard and should win the primary open action.
- User re-entry should prefer the existing visible Claude Code cockpit before creating or resuming another one.
- Legacy project terminals are still allowed only when no managed Work Batch surface applies.

## Source Map

| Area | Evidence | Finding |
| --- | --- | --- |
| Project primary action | `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:304-345` | Project cards already route through Work Batch first, then fall back to legacy terminal only when no batch action applies. |
| Work Batch open rules | `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:453-505` | Pending checkpoints open before the cockpit; a single active bound batch opens directly; ambiguous active batches open Project Detail. |
| Delivery policy | `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift:25-70` | Automatic delivery distinguishes queue-only, wake, resume, checkpoint wait, duplicate cockpit wait, and delivery failure. This is the right state boundary. |
| Binding reconciliation | `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:34-75` | Duplicate same-worktree cockpits block open work, but completed all-done batches should stay idle/done rather than becoming attention items. |
| Cockpit session handling | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:485-510` | Manual cockpit opening can now try focus before resume without changing automatic delivery recovery behavior. |
| Router cockpit opening | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:611-631` | User-initiated Work Batch opening now passes the focus-first preference into the task-session coordinator. |
| Activity panel Open | `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift:185-228` | Completed tracked-project creations now re-enter through the Work Batch-aware primary action; ad hoc creations remain legacy terminal fallback. |

## Cleanup Ledger

| Risk | Severity | Decision | Outcome |
| --- | --- | --- | --- |
| User clicks a Work Batch/project card, but the binding is marked stale/done while the real Claude tab is visible, causing `claude --resume` to open another cockpit. | High | Fix now. Manual re-entry should try focusing the existing cockpit first, then resume only if focus fails. | Implemented `preferFocusBeforeResume` on `WorkBatchTaskSessionCoordinator.openExistingSession` and used it from `WorkBatchAutoRouter.openCockpit`. |
| Completed batches with all Tasks done can still appear as `Waiting` because old duplicate Claude cockpits remain in the batch worktree. | High | Fix now. Duplicate cockpits are actionable only when there is open work; completed all-done batches should stay idle/done. | Reconciler now short-circuits all-done batches to `.idle`/`.done` before duplicate detection, with regression coverage. |
| A pending checkpoint could be obscured by all-done cleanup or duplicate-cockpit summaries in inconsistent runtime states. | High | Fix now. Checkpoints are the alignment safeguard, so pending user decisions should stay visible even when session plumbing is weird. | Reconciler now skips all-done cleanup when a batch needs the user, and checkpoint summaries win over duplicate-cockpit summaries while still recording the duplicate issue. |
| Completed project-creation Activity card still called `launchTerminal(for:)` directly, bypassing Work Batch primary action. | Medium | Fix now for tracked projects; keep ad hoc fallback explicit. | Tracked creations now call `handlePrimaryProjectAction(for:)`; the remaining direct launch is commented as legacy ad hoc behavior. |
| `WorkBatchState.swift` mixes records, persistence, projections, open-action resolution, and context-summary resolution. | Medium | Defer. A file split would reduce cognitive load but does not fix a current user-visible bug. Do it as a mechanical cleanup slice with no behavior changes. | Deferred with acceptance: split into state store, projections, and action resolvers while keeping current tests green. |
| `ActivityPanel` has no direct view-level regression coverage. | Low | Cover the behavior through the shared action path for now; avoid brittle SwiftUI button tests. | The safer part is source-level and covered indirectly by primary action resolver/router tests. |
| Legacy method-runner/delegation concepts still exist near the new Work Batch model. | Low | Defer. They are still used by other slices and should be removed only with a broader product decision. | Leave in place; continue marking new-vs-legacy behavior in comments when touched. |

## Changes Made In This Pass

1. Manual Work Batch cockpit opening now tries to focus the existing visible terminal before launching a resume.
2. Automatic delivery still uses the existing delivery policy; the focus-first behavior is only for user re-entry through `openCockpit`.
3. All-done Work Batches now remain idle/done even if old duplicate Claude Code cockpits still exist.
4. Pending checkpoints stay visible ahead of cleanup/duplicate-cockpit summaries while still preserving duplicate-cockpit issue evidence.
5. Activity panel completed-project Open now uses the same Work Batch-aware primary action as project cards when the project is already tracked.
6. Added regression coverage for stale-binding focus-first re-entry, router-level cockpit opening, all-done duplicate cockpit reconciliation, and checkpoint-first reconciliation.

## Verification

Focused Swift verification passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatchTaskSessionTests|WorkBatchAutoRouterTests|WorkBatchProjectPrimaryActionResolverTests|AppStateWorkBatchOpenTests'
```

Result: 62 tests, 0 failures.

After the checkpoint-first reconciliation hardening:

```bash
swift test --package-path apps/swift --filter 'WorkBatchBindingReconcilerTests|WorkBatchTaskSessionTests|WorkBatchAutoRouterTests|WorkBatchProjectPrimaryActionResolverTests|AppStateWorkBatchOpenTests'
```

Result: 79 tests, 0 failures.

Full Swift verification passed:

```bash
swift test --package-path apps/swift
```

Result: 886 XCTest tests, 1 skipped, 0 failures; 19 Swift Testing tests passed.

Rust core verification passed:

```bash
CARGO_INCREMENTAL=0 cargo test -p capacitor-core -j1 --quiet
```

Result: all emitted `capacitor-core` suites passed.

App restart passed:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Result: build/relaunch completed; `CapacitorDebug.app` and `hud-hook serve --port 7474` were running afterward.

Manual smoke:

- Restarted `apps/swift/CapacitorDebug.app`.
- Opened `arc-design-studio` from its project card.
- Verified Project Detail showed visible Work Batch cards and did not spawn a new Ghostty window or tab.
- Clicked the `Mobile Prototype Polish` cockpit button while duplicate sessions were present; Ghostty stayed at 4 windows and 8 tabs.
- After the all-done duplicate cleanup and app restart, the live `arc-design-studio` Work Batch state shows both `Mobile Prototype Polish` and `Verification & Routing Docs` as `idle`, and their cockpit bindings as `done`.
- Screenshot: `docs/circuit/proofs/operator-product-loop/manual-work-batch-holistic-review-2026-05-25T1711.png`.

## Next Defensible Cleanup Slice

Split `WorkBatchState.swift` into smaller files without changing behavior:

- `WorkBatchRecords.swift` for Codable records.
- `WorkBatchStateStore.swift` for persistence.
- `WorkBatchProjection.swift` for projections and summaries.
- `WorkBatchOpenActions.swift` for checkpoint-first and project primary-action resolution.

Acceptance: no public behavior changes, all existing Work Batch tests pass, and no new product concepts are introduced.
