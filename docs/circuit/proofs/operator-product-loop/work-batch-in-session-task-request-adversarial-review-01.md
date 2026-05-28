# Work Batch In-Session Task Request Adversarial Review 01

Date: 2026-05-27 local / 2026-05-28 UTC

## Scope

Reviewed the in-session Task request slice after focused tests, Debug app rebuild, and live manual verification. The goal was to let Claude Code request new same-batch Tasks from inside a Work Batch session through a local artifact while Capacitor keeps canonical state, existing claim/Done/Checkpoint behavior, and current terminal/session boundaries.

## Evidence Reviewed

- `docs/circuit/work-batch-in-session-task-request-spec.md`
- `docs/circuit/proofs/operator-product-loop/work-batch-in-session-task-request-manual-test-2026-05-27.md`
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskRequest.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskRequestTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift`

## Findings

No medium, high, or critical findings.

Low: V1 intentionally treats in-session Task requests as same-batch requests, even if the text might be unrelated. This keeps routing authority in Capacitor and avoids asking Claude to mutate canonical state, but a later UX pass may want an easy "move to a different batch" affordance.

## Checks

- Request artifacts are local to `.capacitor/work-batch-task-requests`.
- Blank and malformed requests are ignored.
- Duplicate artifacts are idempotent by canonical `task_id`.
- Future `requested_at` timestamps are capped at ingest time.
- Task requests are ingested before claims, Done reports, and checkpoints.
- Duplicate-version runtime polling now still checks Work Batch request artifacts, so a request file does not need a runtime snapshot version bump.
- The context mirror documents the request path without noisy visible terminal prompts.
- Live manual proof used the correct `CapacitorDebug.app` and the existing bound Work Batch session.

## Result

Clean review: no unresolved medium-or-above findings.
