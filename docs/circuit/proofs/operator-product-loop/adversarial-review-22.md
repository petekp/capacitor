# Adversarial Review 22: Consolidated Product Loop Audit

Date: 2026-05-24

## Scope

First adversarial pass over the full recent product-loop slice rather than a single increment. Reviewed the storyboard plan, receipt loop boundary, migration inventory, receipt proof evidence, prior operator-product-loop reviews, current Swift/Python diffs, and the local tests around attention, method runs, receipt runs, action routing, and checkpoint evidence packets.

## Findings

No medium, high, or critical findings remain after the fixes below.

## Issues Found And Resolved During This Pass

1. Medium: method-run setup failures could leave a created run unresolved.
   - Attack: start from the ordinary idea method path and fail before subprocess launch.
   - Evidence: the run creation mutation happens before `MethodRunCoordinator.startRun`; setup and launch errors could previously throw before a fail mutation.
   - Resolution: `MethodRunCoordinator.startRun` now calls the fail mutation for setup, binary resolution, launch, and nonzero process failures.
   - Regression: `MethodRunCoordinatorTests.testStartRunFailsWhenIntentContextCannotBeWritten`.

2. Medium: receipt-loop start rejection could leave Project Detail waiting to open a future proof.
   - Attack: try to start a second ordinary receipt loop while the one-visible-Claude-receipt-session guard is active.
   - Evidence: Project Detail sets an open-after-capture flag before invoking the method; the rejected-start path returned with only a toast.
   - Resolution: the rejected-start path posts `.circuitFirstSliceDidFail`.
   - Regression: `AppStateReceiptLoopRunStateTests.testRejectedReceiptGoalPacketRunPostsFailureNotification`.

## Evidence Checked

- The implementation still uses the in-repo `circuit_protocol/` planner and normalizer.
- Swift planning still shells to `scripts/circuit/plan-goal-packet.py` in this repo, not the old Circuit runtime.
- The receipt loop still targets one visible Claude Code CLI session for the live path.
- Attention routing opens checkpoint reviews by exact run/checkpoint identity.
- Delegation review routing remains behind the existing delegation primary-action policy.
- Completed receipt cards only open the receipt proof when the item explicitly targets `.receiptProof`.
- Checkpoint and receipt review surfaces lead with operator briefs while leaving raw artifacts available.
- The new fixes do not add queues, retries, task DAGs, a flow engine, broad memory, a SaaS workflow, a new terminal/editor, or generalized host routing.

## Checks

- Protocol unittest and planner/normalizer `--check` commands passed.
- Focused Swift product-loop suite passed: 79 XCTest cases.
- Full Swift suite passed: 708 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- Swift-only restart passed; live processes after restart were `CapacitorDebug` PID 55056 and `hud-hook serve --port 7474` PID 55127.

## Residual Risk

Low: the current return brief is a current-state brief, not a full since-last-looked delta.

Low: the follow-through monitor and revision continuity storyboard scenes remain planned but not yet implemented.

Low: legacy Codex compatibility naming still exists in adapter/test/proof compatibility fields. It is not a live Claude boundary failure.
