# Adversarial Review 14: Operator Evidence Brief

Date: 2026-05-24

## Scope

First clean adversarial pass after adding the receipt rendering operator brief. Reviewed the projection from normalized Claude receipt artifacts into goal, claim, evidence, risk, and ask fields, plus the debug proof UI that now leads with the operator brief while preserving raw receipt details and artifacts.

Primary files reviewed:

- `apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift`
- `apps/swift/Tests/CapacitorTests/ReceiptProofRenderingTests.swift`

## Findings

No medium, high, or critical findings remain.

## Review Notes

- The brief is derived from existing local proof artifacts only: the inserted goal body and the normalized receipt. It does not call the old Circuit runtime, add queues, retries, a task DAG, a flow engine, or a generalized host abstraction.
- The UI now leads with operator-decision fields before metadata and raw receipt details, which matches the storyboard target for an evidence packet that can be reviewed without spelunking.
- Raw receipt summary, evidence, risks, next action, artifact paths, and boundary notes are still available after the brief, preserving the existing proof window for low-level inspection.
- The earlier self-review finding was fixed before this pass: blank or whitespace-only summary, evidence, risk, or next action fields now use plain fallback copy instead of rendering an empty brief.

## Checks

- `swift test --package-path apps/swift --filter ReceiptProofRenderingTests/testProjectionBuildsOperatorEvidenceBriefFromReceiptAndGoalBody`
- `swift test --package-path apps/swift --filter ReceiptProofRenderingTests/testOperatorEvidenceBriefUsesPlainFallbacksWhenReceiptFieldsAreEmpty`
- `swift test --package-path apps/swift --filter ReceiptProofRenderingTests`
- `swift test --package-path apps/swift --filter 'ReceiptProofRenderingTests|CircuitReceiptProductLoopTests|ReceiptFirstProofAdapterTests|AppStateReceiptLoopRunStateTests|OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests'`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- `pgrep -fl CapacitorDebug`
- `pgrep -fl hud-hook`
- `git diff --check -- . ':!.claude/dead-code-report.md'`

## Residual Risk

Low: the goal extraction intentionally stays simple and uses the first non-empty line of the inserted body, preferring `/goal ...` when present. If later goal packets grow frontmatter or richer structure, this should move to a typed parser instead of line scanning.
