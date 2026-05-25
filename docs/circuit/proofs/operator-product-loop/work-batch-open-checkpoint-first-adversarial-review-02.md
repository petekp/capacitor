# Work Batch Open Checkpoint-First Adversarial Review 02

Date: 2026-05-25

Scope:

- Same checkpoint-first Work Batch opening slice as Review 01.

Goal under review:

Confirm a second time that primary Open Batch is Checkpoint-first when a pending Checkpoint exists, while the terminal button remains the direct Claude Code cockpit path.

## Findings

No medium, high, or critical findings.

## Attack Notes

- No alternate caller bypasses `AppState.openWorkBatch`; current source search shows the Project Detail Work Batch list as the only production call path for this primary action.
- The separate `openWorkBatchCockpit` path is still available from the terminal button and from the fallback branch when no pending Checkpoint exists.
- Repeated Open Batch clicks generate a fresh focus request UUID, so the same pending Checkpoint can be refocused.
- The response path remains compatible with the existing Work Batch checkpoint exchange: it writes the response file, marks the Checkpoint answered, requeues the Task, rewrites the context mirror, and clears UI focus after acceptance.
- The slice stays inside the current Swift app and Work Batch protocol/state surfaces. It does not invoke old Circuit runtime or add method selection, runner/flow-engine, task-DAG, broad memory, generalized multi-host abstraction, or SaaS framing.

## Verification

- `swift test --package-path apps/swift --filter WorkBatchOpenActionResolverTests --filter AppStateWorkBatchOpenTests --filter WorkBatchAutoRouterTests --filter WorkBatchStateTests --filter WorkBatchCheckpointExchangeTests --filter WorkBatchTaskSessionTests --filter AppStateRuntimeSnapshotEffectTests`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh`

## Residual Risk

Live UI proof with a real pending Checkpoint would still be useful before declaring the broader product loop complete, but it is not a blocker for this slice because the decision routing, focus target scoping, and response follow-through are covered by focused Swift tests and the full Swift suite.
