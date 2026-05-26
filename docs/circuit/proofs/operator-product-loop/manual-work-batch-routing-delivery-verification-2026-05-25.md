# Manual Work Batch Routing And Delivery Verification

Date: 2026-05-25

## Objective

Verify the live Capacitor app against the intended Task-to-Work-Batch UX:

- Adding a Task routes and executes automatically.
- Related Tasks join the right visible Work Batch/session.
- Unrelated Tasks create separate visible Work Batches.
- Existing Claude Code cockpits are woken in place when possible.
- Ghostty windows are not created unnecessarily.
- Claim, Done, queued, checkpoint, and idle states are represented honestly.
- Users do not need to understand session plumbing.

## Live App Context

- App bundle: `apps/swift/CapacitorDebug.app`
- Runtime service: `hud-hook serve --port 7474`
- Project manually tested: `/Users/petepetrash/Code/ever/arc-design-studio`
- Initial Ghostty window count during the core routing tests: `4`

## Manual Scenario

### 1. Existing Related Task Reused Existing Batch

Task:

`for manual verification, make the mobile prototype green border slightly softer and keep the change scoped to that prototype`

Observed:

- Routed into existing Work Batch `Mobile Prototype Polish`.
- Woke the existing visible Claude session instead of launching a new Ghostty window.
- Completion artifact was written under the batch worktree.
- The batch eventually showed idle/done state.

Evidence:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-arc-woken-2026-05-25T14-37-15-0700.png`
- `docs/circuit/proofs/operator-product-loop/manual-work-batch-arc-done-card-2026-05-25T14-53-22-0700.png`
- Claim artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray/.capacitor/work-batch-claims/01KSG879TXVA007KF8QW2HB0Z8.json`
- Done artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray/.capacitor/work-batch-completions/01KSG879TXVA007KF8QW2HB0Z8.json`

### 2. New Related Task Joined Same Batch

Task:

`for manual verification, keep the softer mobile prototype border visible at narrow widths only`

Observed:

- Classified into existing batch `batch-mobile-prototype-polish-01kserayxhgn3ats8c4jre50`.
- Classification rationale identified it as a direct follow-up to the previous mobile prototype border task.
- Delivery used `wake_existing_session`.
- Ghostty window count stayed at `4`.
- Completion artifact was written and the batch returned to idle/done.

Evidence:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-arc-related-queued-2026-05-25T14-54-28-0700.png`
- `docs/circuit/proofs/operator-product-loop/manual-work-batch-arc-related-done-2026-05-25T14-56-27-0700.png`
- Claim artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray/.capacitor/work-batch-claims/01KSGJ261BMW45GGXR14CWKS6J.json`
- Done artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray/.capacitor/work-batch-completions/01KSGJ261BMW45GGXR14CWKS6J.json`

### 3. Unrelated Task Created A Separate Batch

Task:

`for manual verification, add a short docs note under docs/manual-verification.md recording this Capacitor routing smoke test`

Observed:

- Classified as a new batch, `Verification & Routing Docs`.
- Created batch `batch-verification-routing-docs-01ksgjay9jmbcxyrd8wb8g`.
- Started a new Claude session because the work was unrelated.
- Ghostty window count stayed at `4`, so the launch reused existing Ghostty surface instead of creating another window.
- Completion artifact was written and the batch returned to idle/done.
- Project detail showed both batches as visible top-level Work Batches.

Evidence:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-arc-detail-multiple-batches-2026-05-25T15-00-39-0700.png`
- Claim artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-verification-routing-docs-01ksgj/.capacitor/work-batch-claims/01KSGJAY9JMBCXYRD8WB8GBYGS.json`
- Done artifact: `/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-verification-routing-docs-01ksgj/.capacitor/work-batch-completions/01KSGJAY9JMBCXYRD8WB8GBYGS.json`

### 4. Hook Cleanup Retest

During manual worker runs, Claude transcripts showed stale hook errors:

`error: unrecognized subcommand 'handle'`

Root cause:

- `~/.claude/settings.json` still contained retired Capacitor hook commands:
  - `CAPACITOR_HOOK_MARKER=1 $HOME/.local/bin/hud-hook handle`
  - older no-token curl commands that posted to `http://127.0.0.1:7474/hook`
- Current `hud-hook` exposes `serve` and `cwd`, not `handle`.
- Setup health considered the settings installed because current hooks were present, so the app did not repair the retired entries.

Fix:

- Retired Capacitor hook commands are now recognized as Capacitor-owned.
- Setup health reports repair-needed when retired or duplicate managed entries remain.
- Normal hook installation rewrites/deduplicates them into the current tokenized `/hook` command.

Post-fix observation:

- `rg -n "hud-hook.*handle|CAPACITOR_HOOK_MARKER" ~/.claude/settings.json` found no matches.
- Managed hook command count is `14`, one per managed Claude event.
- App and runtime service relaunched successfully.
- Ghostty window count remained `4`.

Evidence:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-post-hook-cleanup-2026-05-25T15-26-20-0700.png`

## Final Live State

`/Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/state.json`

- `Mobile Prototype Polish`: `idle`, `0` queued tasks
- `Verification & Routing Docs`: `idle`, `0` queued tasks

`/Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/cockpit-bindings.json`

- `Mobile Prototype Polish`: `done`, Claude session `0bf0e773-06b2-42b9-bd60-7993be3f139d`
- `Verification & Routing Docs`: `done`, Claude session `aaeb13da-3948-4e53-9cc3-a1101b385299`

## Issues Found And Fixed

1. Runtime snapshots could mark exact live Claude sessions as absent.
   - Fixed with process-backed exact session lookup by batch worktree.

2. Related Tasks could resume or launch instead of waking an already visible cockpit.
   - Fixed with `wake_existing_session` delivery and Ghostty terminal-ID targeted input.

3. Agent-written claim/completion/checkpoint dates with fractional seconds could fail to decode.
   - Fixed with shared `capacitorISO8601` decoding.

4. Done reports could lose to later wake/claim timestamps.
   - Fixed so Done artifacts are terminal worker claims and remain monotonic.

5. Idle Work Batch summaries could fall back to stale legacy session text.
   - Fixed with Work Batch project context summary resolution.

6. Retired Capacitor hook entries could remain active beside current hooks.
   - Fixed setup ownership detection and repair-needed health reporting.

## Automated Verification

Passed:

```bash
CARGO_INCREMENTAL=0 cargo test -p capacitor-core runtime::setup -j1
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|CompletionReport|CheckpointExchange|AutoRouter|DeliveryPolicy|TaskSession|State)Tests|AppStateRuntimeSnapshotEffectTests|GhosttyAutomationClientTests|WorkBatchBindingReconcilerTests|WorkBatchClaudeProcessScannerTests|ProjectCardContextLineResolverTests|GhosttyTerminalDriverTests'
swift test --package-path apps/swift
```

Focused Swift result:

- 149 tests passed
- 0 failures

Full Swift result:

- 874 XCTest tests passed
- 1 test skipped
- 0 failures
- Swift Testing suites passed: 19 tests

## Adversarial Reviews

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-routing-delivery-adversarial-review-01.md`: no medium, high, or critical findings.
- `docs/circuit/proofs/operator-product-loop/manual-work-batch-routing-delivery-adversarial-review-02.md`: no medium, high, or critical findings.

## Residual Notes

- A pre-existing legacy open Task remains in the old project task list for `arc-design-studio`; it predates this manual routing scenario and is not a failure of the Work Batch delivery slice.
- Completed batch Claude processes can remain visible after Done. Capacitor marks the Work Batch idle/done while keeping the cockpit binding session ID, so future related work can still target the right batch identity.
