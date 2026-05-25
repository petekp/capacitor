# Adversarial Review 16: Product Loop Hardening Pass

Date: 2026-05-24

## Scope

First clean adversarial pass after reviewing the recent product-loop implementation end to end. Reviewed the storyboard plan, protocol planner, ordinary idea-to-run context, receipt loop state, return brief, operator attention projection, field-of-work grouping, checkpoint/delegation review routing, receipt rendering, and focused test coverage.

Primary files reviewed:

- `docs/circuit/storyboard-indexed-product-loop-plan.md`
- `circuit_protocol/goal_packet_planning.py`
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift`
- focused product-loop tests under `apps/swift/Tests/CapacitorTests/`

## Findings

No medium, high, or critical findings remain.

## Issues Found And Resolved Before This Clean Pass

- Medium: regular method runs could still launch after failing to prepare `context.json`, which meant intent and success criteria could silently disappear before checkpoint review. `MethodRunCoordinator.startRun` now fails with `MethodRunError.contextUnavailable` if the run directory or context file cannot be prepared, and `MethodRunCoordinatorTests` covers both the success and blocked-write paths.
- Medium: delegation reviews were not part of `OperatorAttentionProjection`, so a project with `review_needed` or `resume_failed` delegation state could be omitted from `Needs You`. The projection now accepts `delegationStatesByProjectPath`, maps active delegation reviews into `Needs You`, and `ProjectsView` passes `appState.runState.delegationStates`.

## Evidence Checked

- The product path remains owner-first: Capacitor owns local session lifecycle, attention projection, artifact storage, and rendering; Circuit remains the in-repo headless protocol layer.
- No old `/Users/petepetrash/Code/capacitor-circuit` runtime dependency was introduced.
- No runner platform, flow engine, task DAG, retry platform, broad memory store, SaaS workflow, new terminal/editor, or generalized multi-host abstraction was introduced.
- Receipt and checkpoint surfaces still keep raw evidence available while moving operator-facing summaries earlier.
- Delegation reviews, paused run checkpoints, stale sessions/runs, running receipt loops, completed receipt loops, and dormant projects are now all accounted for by the attention/field-of-work projection.

## Checks

- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift --filter MethodRunCoordinatorTests`
- `swift test --package-path apps/swift --filter OperatorAttentionProjectionTests/testDelegationReviewAppearsInNeedsYou`
- `swift test --package-path apps/swift --filter 'OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|ReturnBriefContentTests|ProjectPrimaryActionResolverTests|AppStateRunCheckpointTests'`
- `swift test --package-path apps/swift --filter 'MethodRunCoordinatorTests|MethodRunContextTests|IdeaRunIntentProjectionTests|CircuitReceiptGoalPacketMethodTests|AppStateReceiptLoopRunStateTests|ReceiptLoopRunStateTests|OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|ReturnBriefContentTests|OperatorViewStateStoreTests|CircuitReceiptProductLoopTests|ReceiptFirstProofAdapterTests|ReceiptProofRenderingTests|ProjectPrimaryActionResolverTests|AppStateRunCheckpointTests'`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- `pgrep -fl CapacitorDebug`
- `pgrep -fl hud-hook`
- `git diff --check -- . ':!.claude/dead-code-report.md'`

## Residual Risk

Low: the return brief has the storage primitive for last-opened state, but most counts are still current-state counts rather than a full "since last seen" diff. That is acceptable for the current foundation slice and belongs to the next memory/continuity increment.
