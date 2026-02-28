# Feedback Form v2 (Alpha)

## Goal

Make feedback capture frictionless with one text input, AI-inferred structure, and optional GitHub issue creation.

## UX Spec

- Sheet title: `Feedback`
- Body content:
  - Single textarea only (no label, no required fields)
  - Height: ~3 lines
  - Placeholder: `Share anything including bugs, ideas, feature requests...`
- Option:
  - Checkbox: `Open a GitHub issue (optional)`
- Primary CTA:
  - If checked: `Open GitHub Issue`
  - If unchecked: `Share feedback`
  - Visual style: prominent/primary button
- Secondary CTA:
  - `Cancel` (non-prominent)

## Behavior

- Feedback can be submitted even when textarea is empty.
- In-sheet telemetry/path consent controls are removed.
- Submission routing:
  - `Open a GitHub issue` checked: open GitHub draft + send ingest payload (if configured).
  - `Open a GitHub issue` unchecked: send ingest payload only (if configured).
- If ingest endpoint is unavailable and GitHub is unchecked, show an error toast.

## Telemetry Funnel

- `quick_feedback_opened`
- `quick_feedback_field_completed`
- `quick_feedback_submit_attempt`
- `quick_feedback_submit_success`
- `quick_feedback_submit_failure`
- `quick_feedback_abandoned`

Submit events include:

- `issue_requested`
- `issue_opened`
- `endpoint_attempted`
- `endpoint_succeeded`

## Verification

- Unit tests:
  - `QuickFeedbackSubmitterTests`
  - `QuickFeedbackFunnelTests`
