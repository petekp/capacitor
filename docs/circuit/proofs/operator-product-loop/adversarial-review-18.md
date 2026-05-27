# Adversarial Review 18: Attention Action Routing

Date: 2026-05-24

## Scope

First adversarial pass on the field-of-work action routing slice. Reviewed the new attention primary-action resolver, the `ProjectsView` card tap path, checkpoint target routing, receipt proof targeting, and the receipt loop single-session guard against the product-loop goal.

## Findings

No medium, high, or critical findings remain.

## Issues Resolved During Review

- Medium: ordinary receipt loops were guarded only per project, even though the receipt-first product boundary keeps one visible Claude Code receipt session. Fixed by making `beginReceiptLoopRun` reject any already-running receipt loop across projects and covering it with `testBeginReceiptLoopRunRejectsSecondRunningLoopAcrossProjects`.
- Medium: completed receipt cards could have opened the single global receipt proof window for an older receipt after a newer receipt completed. Fixed by adding an explicit `.receiptProof` attention target, making only the latest renderable completed receipt target that proof surface, and falling back to the ordinary project action otherwise.

## Evidence Checked

- Checkpoint action routing: a `.checkpoint` attention item resolves to `openRunCheckpointReview(projectPath:runID:checkpointID:)`, and `ProjectsView` sets the exact `RunCheckpointWindowTarget`.
- Delegation action routing: a `.delegationReview` attention item reuses `ProjectPrimaryActionResolver`, so disabled delegation still falls back to the ordinary project action.
- Receipt action routing: completed/failed receipt items open the proof window only when the attention target is explicitly `.receiptProof`.
- Ordinary work routing: running and dormant attention items resolve to the existing project primary action path.
- Receipt concurrency: a running receipt loop in any project blocks a second ordinary receipt loop start.

## Checks

- Focused Swift slice passed: `OperatorAttentionPrimaryActionResolverTests`, `OperatorAttentionProjectionTests`, `OperatorFieldOfWorkProjectionTests`, `ProjectPrimaryActionResolverTests`, `AppStateRunCheckpointTests`, `AppStateReceiptLoopRunStateTests`, and `ReceiptProofRenderingTests`.
- Full Swift suite passed: 705 XCTest cases, 1 skipped, 0 failures, plus 19 Swift Testing cases.

## Residual Risk

Low: the receipt proof surface is still a single latest-proof window. Older completed receipt cards now avoid opening the wrong proof, but per-run receipt proof history still belongs to the later richer artifact capture work.
