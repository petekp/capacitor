# Operator-Facing Claude Prompt Adversarial Review 02 - 2026-05-25

## Scope

Second clean review after the first adversarial pass. The review rechecked whether the implementation still preserves:

- automatic Task execution and Work Batch delivery,
- Claude Code-only execution,
- hidden Work Batch mechanics,
- honest claim/Done/Checkpoint artifact expectations,
- no new runner, flow engine, task DAG, broad memory, terminal/editor, or generalized host abstraction.

## Findings

No medium, high, or critical findings.

## Rechecked Edge Cases

1. New Work Batch launch:
   - Expected: Claude receives the Work Batch contract through `.capacitor/work-batch-agent-instructions.md`; the visible prompt is `Assessing tasks...`.
   - Evidence: `WorkBatchTaskSessionTests` checks generated instruction file content and launch script content.

2. Stale binding resume:
   - Expected: Claude resumes by session ID with the hidden instruction file and short visible prompt.
   - Evidence: `WorkBatchAutoRouterTests` checks the resume launch script includes `--append-system-prompt-file` and omits `Task claim`.

3. Live binding wake:
   - Expected: Capacitor nudges the existing cockpit instead of launching a new session; visible input remains short.
   - Evidence: `WorkBatchAutoRouterTests` checks no terminal launch script is created and the wake prompt is exactly `Assessing updated tasks...`.

4. Metadata hygiene:
   - Expected: the generated instruction file lives under `.capacitor` metadata and does not become app source or product state.
   - Evidence: `writeAgentInstructions` writes under `.capacitor` after installing the Work Batch metadata ignore rule.

## Residual Risk

Only low residual risk remains: the live terminal surface still needs to be visually checked after the desktop is unlocked. That does not invalidate the source/test result, but it should be the next manual check before declaring the operator-facing terminal experience fully verified.

## Verdict

Second consecutive review found no medium-or-above findings. The change is tight, scoped, and aligned with the intended Capacitor UX: the human sees operator-facing status, while Capacitor still gives Claude the full Work Batch contract.
