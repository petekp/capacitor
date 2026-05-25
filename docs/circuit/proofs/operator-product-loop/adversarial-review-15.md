# Adversarial Review 15: Second Pass on Operator Evidence Brief

Date: 2026-05-24

## Scope

Second adversarial pass over the final operator evidence brief slice. Re-checked projection fallbacks, artifact boundaries, rendering order, and compatibility with the existing receipt-first debug proof window.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- `OperatorEvidenceBriefProjection.make` trims receipt fields and provides stable fallback copy for missing goal, summary, evidence, risk, and ask content.
- `ReceiptProofRenderingStore.loadProjection` reads the inserted goal body when available, but still renders from the normalized receipt if that body artifact is missing or unreadable.
- `ReceiptProofRenderingStore.makeProjection` keeps existing receipt validation: native result kind/status, AgentEvent kind/type, receipt kind, matching goal packet IDs, supported normalizer mode, no Circuit runtime normalization, and raw receipt payload equality.
- `ReceiptProofRenderingWindow.content` places the operator brief before metadata and raw details, while keeping the raw receipt and artifact sections available for inspection.
- Focused tests cover the main success path from inserted `/goal` body to operator brief and the blank-field fallback path.

## Checks

- Focused rendering tests passed.
- Focused product-loop slice passed: 52 Swift tests.
- Full Swift suite passed: 692 XCTest cases, 1 skipped, 0 failures, plus 19 Swift Testing cases.
- Relaunch passed with `CapacitorDebug` and `hud-hook serve --port 7474` running.
- Scoped diff check passed.

## Residual Risk

Low: duplicate evidence strings still share the same SwiftUI `ForEach` identity in the existing bullet-list helper. This predates the brief and has not shown up in the proof artifacts, but the helper should use indexed identity if receipt evidence becomes noisier.
