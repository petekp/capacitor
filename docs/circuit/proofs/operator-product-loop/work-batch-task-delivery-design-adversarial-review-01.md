# Work Batch Task Delivery Design Adversarial Review 01

Date: 2026-05-25

Scope: `docs/circuit/work-batch-task-delivery-policy.md` against the Goal for getting newly added Tasks into an existing Capacitor Work Batch Claude Code session.

## Checks

- Rechecked the recommendation against current routing behavior in `WorkBatchAutoRouter`.
- Rechecked launch/resume and context-mirror behavior in `WorkBatchTaskSession`.
- Rechecked binding reconciliation, duplicate cockpit detection, stale binding handling, and unfinished Task requeueing in `WorkBatchBindingReconciler`.
- Rechecked existing callback boundaries in `WorkBatchCheckpointExchange` and `WorkBatchCompletionReport`.
- Rechecked visible state and checkpoint-first open behavior in `WorkBatchState`.
- Rechecked runtime liveness fields in `RuntimeClient`.
- Rechecked explicit non-goals: no old Circuit runtime, runner, flow engine, task DAG, broad memory platform, generalized multi-host abstraction, new terminal/editor, or SaaS workflow framing.

## Findings

- No medium, high, or critical findings.

Low residual risks:

- The recommendation depends on Claude Code following the mirror instruction to write a claim before starting queued work. The design mitigates this by keeping queued state honest, using Done/Checkpoint callbacks independently, and adding a no-claim watchdog before claiming progress.
- The recommendation intentionally does not implement live terminal injection. That can make pickup feel less immediate while a Claude session is actively busy, but it avoids the higher-risk failure mode of injecting into the wrong prompt or creating a duplicate cockpit.
- The safe-wake extension still needs real runtime-payload validation during implementation, especially around whether `state`, `toolsInFlight`, and activity timestamps reliably identify an input boundary.

## Pre-Review Tightening

- Added delivery generation and watermark requirements so stale claim files cannot re-mark reopened or updated Tasks as working.
- Added retry-suppression acceptance criteria so refresh loops cannot repeatedly nudge the same queued Task.
- Made terminal injection explicitly deferred until exact-session targeting and input-boundary proof exist.

## Result

Clean for medium-or-above findings.
