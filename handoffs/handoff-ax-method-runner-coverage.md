# Handoff: AX Method Runner Coverage

## What Was Done

Ran `method:flow-audit-and-repair` autonomously to add AX automation coverage for the orchestrator runs (method runner) feature. The method produced 8 artifacts in `.relay/method-runs/orchestrator-ax-audit/artifacts/`.

## Changes (7 files, +113/-4)

### Swift — Accessibility Identifiers Added

| File | Identifiers Added |
|------|-------------------|
| `AccessibilityIdentifiers.swift` | 8 new constants + 1 function: `ideaCaptureOverlay`, `ideaCaptureTextArea`, `methodSelector`, `methodSelectorDismiss`, `methodCard(for:)`, `runCompletion`, `ideaDetailRunMethod`, `ideaQueueFirstRow` |
| `IdeaCapturePopover.swift` | `ax.idea-capture-overlay` on overlay body, `ax.idea-capture-textarea` on CenteredTextEditor NSScrollView |
| `MethodSelectorView.swift` | `ax.method-selector` on panel, `ax.method-selector.dismiss` on X button, `ax.method-card.<id>` on each MethodCard |
| `ActivityPanel.swift` | `ax.run-completion` on RunCompletionCard |
| `IdeaDetailModal.swift` | Normalized `"idea_detail_run_method"` → `AccessibilityIdentifiers.ideaDetailRunMethodIdentifier` (`ax.idea-detail.run-method`) |
| `IdeaQueueView.swift` | `ax.idea-queue-first` on first row, `ax.idea-queue-row.<id>` on others |

### Shell — Test Harness Extended

`non-demo-ax-smoke.sh` gained:
- **Phase 3**: Method runner AX smoke (frontier profile)
  - Full scenario (with ideas): details → idea queue → "Run Method" → method selector → dismiss
  - Fallback scenario (no ideas): details navigation only
- `--skip-method-runner` flag
- Conditional idea detection from `~/.capacitor/ideas.json`

## Verification Results

| Check | Result |
|-------|--------|
| `swift build` | PASS (0 errors) |
| `swift test` | PASS (19/19 tests) |
| AX smoke (cards phase) | PASS |
| AX smoke (details phase) | FAIL (pre-existing — `ax.project-details.*` timeout in frontier) |
| Shell syntax check | PASS |

## What Remains (for you to review)

1. **Pre-existing details phase timeout** — `ax.project-details.capacitor` times out in frontier profile. Not caused by these changes. Needs separate investigation.

2. **Seed ideas for full Phase 3** — The full method-runner AX flow requires ideas in `~/.capacitor/ideas.json`. Consider adding idea seeding to `ax-automation-verify.sh` (similar to projects.json seeding).

3. **Live AX tree inspection** — Use Accessibility Inspector to verify:
   - `ax.idea-capture-textarea` propagates through NSViewRepresentable
   - `ax.method-selector` is reachable through the modal scrim overlay
   - `ax.method-card.*` identifiers appear on each MethodCard button

4. **Commit when ready** — Changes are staged but not committed. All changes are additive (accessibility modifiers only) with no visual or behavioral impact.

## Method Artifacts

```
.relay/method-runs/orchestrator-ax-audit/artifacts/
├── failure-brief.md
├── audit-trace.md
├── causal-map.md
├── repair-steer.md
├── regression-contract.md
├── repair-packet.md
├── repair-handoff.md
└── flow-verdict.md
```

Flow verdict: **PARTIAL** — all repair slices complete, but full Phase 3 exercise blocked by pre-existing details timeout + no seeded ideas.
