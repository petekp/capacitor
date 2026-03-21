# Execution Spec: Contextual Decision CTAs

## Manifest Schema Extension

Add optional `decisions` field to `manifest.json`:

```json
{
  "version": 1,
  "milestone_id": "01",
  "summary": "...",
  "artifacts": [...],
  "decisions": {
    "approve": {
      "label": "Merge to main",
      "description": "Tests pass, error handling is solid. Ready to ship."
    },
    "request_changes": {
      "label": "Tighten edge cases",
      "description": "Scanning logic handles happy path but overflow and non-contiguous numbering need guards."
    }
  }
}
```

- `decisions` is optional (backward compat)
- `decisions.approve` and `decisions.request_changes` each have `label` (short CTA text) and `description` (1-2 sentence context)
- If absent, fall back to current static text
- "Write a Response" is always static

## Changes

### 1. DelegationReviewManifest.swift
Add `decisions` field with nested types:
```swift
struct DecisionHint: Decodable {
    let label: String
    let description: String
}
struct DecisionHints: Decodable {
    let approve: DecisionHint?
    let requestChanges: DecisionHint?

    enum CodingKeys: String, CodingKey {
        case approve
        case requestChanges = "request_changes"
    }
}
let decisions: DecisionHints?
```

### 2. DelegationReviewWindow.swift
Read `manifest?.decisions?.approve` and `manifest?.decisions?.requestChanges` for card labels and descriptions. Fall back to static defaults.

### 3. DelegationLoopManager.swift — buildInitialPrompt()
Add instruction for the worker to include contextual decisions in the manifest:
```
8. Include a "decisions" field in the manifest with contextual labels:
   "decisions": {
     "approve": { "label": "<short CTA>", "description": "<why approve>" },
     "request_changes": { "label": "<short CTA>", "description": "<what needs work>" }
   }
```

### 4. DelegationLoopManager.swift — buildResumePrompt() (request_changes branch)
Same instruction for the next milestone's manifest.

## Verification
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
swift test --package-path apps/swift
```
