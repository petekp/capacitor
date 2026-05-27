# Work Batch Done And Unresolve Adversarial Review 01

Date: 2026-05-25

Scope: Work Batch Done report ingest, canonical Task/Batch state update, visible card behavior, Unresolve, same-session recovery, Batch Worktree metadata hygiene, and alignment with the current `CONTEXT.md` product stance.

## Findings

No open medium, high, or critical findings remain.

Resolved during this review:

- Medium: route save could overwrite a Done ingest that happened while model classification was awaiting. Fixed by reloading and reconciling state after the classifier returns, before applying the route. Regression covered by `testCompletionIngestDuringClassificationIsNotOverwrittenByRouteSave`.
- Medium: Capacitor-generated Work Batch metadata could dirty the Batch Worktree and become commit noise. Fixed by installing `.capacitor/` into Git's actual common `info/exclude` for worktrees, from both Done report and context mirror writes. Covered by report-store and context-mirror ignore tests, and verified manually in the live arc-design-studio batch worktree.
- Low: the Unresolve button lived inside a row-wide tap area that also opened the cockpit. Fixed by limiting the open gesture to the batch header/summary and keeping task-row actions separate.

## Rechecked Failure Modes

- Claude Code can claim a Task Done by writing a narrow Done report in `.capacitor/work-batch-completions/<task-id>.json`.
- Capacitor ingests only reports that match the bound Work Batch and an existing Task id.
- Done ingest is idempotent; a second poll does not re-toast or rewrite state for an already Done Task.
- A partially Done batch keeps open Tasks visible and does not mark the binding Done.
- A fully Done batch becomes idle, the binding becomes Done, and a live terminal does not make it look active again.
- Unresolve removes stale Done reports, requeues the same Task in the same Work Batch, rewrites the context mirror, and reuses the same Batch Cockpit Binding.
- Runtime snapshot application reconciles Work Batch bindings before ingesting completion reports.
- The visible Work Batch row exposes a terminal action and only shows Unresolve for Done Tasks.
- The implementation stays Claude Code only and does not introduce old Circuit runtime, runner/flow-engine behavior, task DAGs, broad memory, generalized multi-host abstraction, SaaS framing, method selection, or headless-only execution.

## Source Evidence

- Done report model, parsing, canonical path, malformed JSON skipping, deletion, and local metadata ignore: `apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:3-180`.
- Work Batch Context Mirror tells Claude Code how to write Done reports and installs the metadata ignore before writing: `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:119-179`.
- Router reloads state after classifier await before saving a route: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:127-168`.
- Unresolve requeues the Task, deletes stale reports, keeps the same binding, and rewrites the mirror: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:323-388`.
- Completion ingest updates Task, Batch, Binding, summary, result payload, and mirror rewrite: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:441-551`.
- Done binding is stable even if the Claude terminal remains alive: `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:65-72`.
- Runtime snapshots reconcile bindings, ingest reports, and hand results to AppState: `apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift:205-221`.
- AppState marks source Tasks Done/Open and resumes stale/waiting/done bindings on Unresolve: `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:461-529`.
- Work Batch UI separates header open from Done task Unresolve: `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift:43-123`.

## Test Evidence

- Report store tests cover write/load, malformed JSON tolerance, deletion by Task id, and common-gitdir ignore installation: `apps/swift/Tests/CapacitorTests/WorkBatchCompletionReportTests.swift:6-133`.
- Context mirror tests cover Done report instructions and ignore installation: `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:186-248`.
- Router tests cover classification/ingest race, Done ingest, partial Done, Unresolve, duplicate cockpit handling, and rerouting cleanup: `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:510-940`.
- AppState runtime snapshot tests cover binding reconciliation and Done ingest toast/state update: `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift:54-255`.
- Focused command passed: `swift test --package-path apps/swift --filter WorkBatchCompletionReportTests --filter WorkBatchTaskSessionTests --filter WorkBatchAutoRouterTests --filter WorkBatchBindingReconcilerTests --filter AppStateRuntimeSnapshotEffectTests`.
- Full command passed: `swift test --package-path apps/swift` with 807 XCTest cases passed, 1 skipped, and 19 Swift Testing tests passed.
- Relaunch passed after unloading a local legacy `com.capacitor.daemon` LaunchAgent that was respawning the old daemon: `./scripts/dev/restart-alpha-stable.sh`.

## Manual Evidence

Manual proof used the real arc-design-studio Work Batch `Mobile Prototype Polish`.

- Seeded Done report in the Batch Worktree for Task `01KSERAYXHGN3ATS8C4JRE50P9`.
- After app ingest, canonical state had Task status `done`, Batch status `idle`, and Binding status `done`.
- Context mirror showed the Task as `[done] add a green border around the mobile prototype`.
- `git status --short -- .capacitor/work-batch-completions .capacitor/work-batch-context.md` in the Batch Worktree returned no output.
- `git check-ignore -v` showed `.capacitor/` came from `/Users/petepetrash/Code/ever/arc-design-studio/.git/info/exclude`.

## Result

Clean for medium-or-above findings after fixes.
