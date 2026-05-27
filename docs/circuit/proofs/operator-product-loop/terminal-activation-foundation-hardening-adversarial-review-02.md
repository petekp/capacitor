# Terminal Activation Foundation Hardening - Adversarial Review 02

Date: 2026-05-25 local.

## Scope

Second adversarial pass after Review 01's row tap fix and live retest.

Reviewed:

- `TerminalActivationTrace` field coverage and escaping.
- `TerminalActivationCoordinator` direct focus, tmux client, switch, post-switch focus, and launch trace points.
- `TerminalLauncher` launch-last logging.
- `GhosttyTerminalDriver` `.alreadySelected` policy.
- `WorkBatchAutoRouter` duplicate/stale binding re-entry behavior.
- `WorkBatchBindingReconciler` checkpoint/done/duplicate precedence.
- `WorkBatchTaskSessionCoordinator` focus-before-resume and Claude resume policy.
- `WorkBatchListSection` summary button, terminal icon, checkpoint card, and unresolve button separation.
- restart script duplicate debug process cleanup.
- state-machine doc, helper script, proof artifact, and screenshots.

## Findings

No medium, high, or critical findings.

## Evidence

- Direct Ghostty selected-CWD matches return `.alreadySelected`, and the coordinator only accepts that as done when no tmux client exists. With a tmux client present, it still switches before focusing.
- Work Batch cockpit opening reconciles the binding first, blocks truly foreign duplicate sessions, and focuses without resume when only duplicate assigned-session processes are present.
- Pending checkpoints win over duplicate cockpit summaries; completed batches are not pulled back into active state by old/duplicate cockpits.
- The Work Batch row no longer has a parent gesture that can collide with terminal-icon or unresolve buttons.
- Focused verification passed after the final UI patch: `swift test --package-path apps/swift --filter 'AppStateWorkBatchOpenTests|WorkBatchOpenActionResolverTests|WorkBatchTaskSessionTests|TerminalActivationCoordinatorTests|RestartAppScriptTests'` ran 37 tests with 0 failures.
- Broader activation/session verification also passed after the final UI patch: `swift test --package-path apps/swift --filter 'GhosttyTerminalDriverTests|GhosttyAutomationClientTests|TerminalActivationCoordinatorTests|TerminalLauncherTests|TmuxRouterTests|SessionResolutionPolicyTests|WorkBatchAutoRouterTests|WorkBatchBindingReconcilerTests|WorkBatchTaskSessionTests|WorkBatchProjectPrimaryActionResolverTests|WorkBatchOpenActionResolverTests|AppStateWorkBatchOpenTests|RestartAppScriptTests'` ran 186 tests with 0 failures.
- Live retest after restart: clicking the `Mobile Prototype Polish` terminal icon made Ghostty frontmost, preserved the same Ghostty window list, preserved the same Claude process list, and logged `surface="terminal_icon" route="work_batch_cockpit" outcome="focused_existing"`.

## Residual Low Risk

- The manual helper currently tails the shared app debug log, so recently run test traces can appear next to live traces. The timestamps and real project paths make them distinguishable. A future cleanup could route test observer lines away from the live log.

## Verdict

Clean. This is the second consecutive post-fix review with no medium-or-above findings.
