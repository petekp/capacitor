# Work Batch Checkpoint-First Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the live checkpoint-first proof, source routing, checkpoint UI, response write path, cleanup evidence, and focused verification.

## Findings

No medium, high, or critical findings.

Low: The project card's status chip still read `Idle` while the card summary said `Checkpoint ready`. This does not break routing or the checkpoint answer flow, but it is visually weaker than the intended "decision needs you" feeling. The Work Batch row did show `Waiting`, and the project-card click correctly went checkpoint-first.

Low: The live proof used a temporary state injection rather than a naturally agent-created checkpoint request. The source and tests cover request ingestion from `.capacitor/work-batch-checkpoints`, and the live proof covered the operator-facing checkpoint-first route and answer path. A future end-to-end worker-created checkpoint should still be captured.

## Rechecked Requirements

- Pending checkpoint wins over cockpit re-entry.
- Project-card route logs `outcome="checkpoint"`.
- Project Detail checkpoint route logs `outcome="needs_input"`.
- Answer field is visible and focused.
- Recommended action is rendered in the checkpoint card.
- Answer submission writes a response artifact.
- Stale/done-task checkpoint closes cleanly after answer.
- Temporary state and response artifacts were restored/removed.
- No Ghostty, tmux, or Claude process was launched during the checkpoint proof.

## Verdict

Clean for this milestone. Do not mark the full hardening goal complete yet; unrelated Task live routing, project-level visual status for checkpoints, project-level route evidence, and a real two-Claude Ghostty/tmux duplicate matrix remain open.
