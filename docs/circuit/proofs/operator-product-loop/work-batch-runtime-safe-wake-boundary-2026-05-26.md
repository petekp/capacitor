# Work Batch Runtime Safe Wake Boundary

Date: 2026-05-26

## Scenario

Related Tasks should join the right Work Batch without launching another Claude Code cockpit. If the exact bound Claude session is actively working, Capacitor should only queue the Task. If the exact bound session is alive and actually waiting for input, Capacitor may send the small wake prompt.

## Product Policy

- Process-scan evidence can prove that the assigned Claude session exists, but it cannot prove that terminal input is safe.
- Runtime snapshot evidence is required for production safe wake.
- A runtime safe wake boundary is satisfied only when the exact assigned session is in the Batch Worktree, has no GC reason, is explicitly alive, is `ready`, and has `tools_in_flight == 0`.
- A second narrow safe boundary is allowed for the live `signal_absence` shape: direct process evidence proves the exact assigned Claude session is alive in the Batch Worktree, runtime says `signal_absence`, runtime says no tools are in flight, and the runtime state source says Claude was awaiting input.
- A `working` session, a session with tools in flight, or process-only evidence without runtime input-boundary evidence must defer wake and leave the Task queued.

## Source Changes

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
  - `safeWakeBoundaryAllowsInputOverride` remains available for tests.
  - Production safe wake now derives from `latestRuntimeSessions`.
  - `exactLiveSessionExists` still accepts process-scanner evidence for liveness, but `safeWakeBoundarySatisfied` requires reducer-backed runtime state.
  - Process-backed `signal_absence` now counts as safe only when the exact assigned process is present, the runtime snapshot is for the same batch worktree/session, no tools are in flight, and the state source is `meta_awaiting_input`.
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
  - Added runtime-ready safe wake coverage.
  - Added process-backed `signal_absence` awaiting-input safe wake coverage.
  - Added process-backed `signal_absence` deferral coverage when awaiting-input evidence or tool-count evidence is missing.
  - Added runtime-working deferral coverage.
  - Added runtime-ready-with-tools-in-flight deferral coverage.
- `docs/circuit/work-batch-task-delivery-policy.md`
  - Updated the safe wake section from a later extension to the current runtime-backed policy.
- `scripts/dev/restart-app.sh`, `scripts/dev/refresh-uniffi-bindings.sh`, `scripts/ci/check-uniffi-bindings.sh`, `scripts/bootstrap.sh`
  - Changed UniFFI generation to use `cargo run --release` so the restart/check scripts stay on the release target that owns the dylib.
- `tests/dev-scripts/restart-app.bats`
  - Added a restart-script guard for release-target UniFFI generation.

## Verification

Passed:

```bash
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift --filter 'WorkBatchDeliveryPolicyTests|WorkBatchAutoRouterTests|AppStateRuntimeSnapshotEffectTests'
swift test --package-path apps/swift
bats tests/dev-scripts
./scripts/ci/check-uniffi-bindings.sh
./scripts/dev/restart-alpha-stable.sh
```

Focused Swift result:

- 64 tests passed.
- The new safe wake cases passed.

Follow-up focused result:

- 3 focused process-backed safe-wake tests passed.
- The positive live-shape case still wakes the exact assigned session.
- The two negative cases defer wake when the direct process scan finds the assigned session but runtime evidence does not prove an input boundary.

Broad Swift result:

- 919 XCTest cases passed.
- 19 Swift Testing cases passed.
- 1 existing test was skipped.

Restart result:

- The first default restart attempt exposed a stall in the debug-target UniFFI generation path.
- After switching UniFFI generation to the release target, the default restart completed.
- Live process evidence after restart:
  - `CapacitorDebug.app` pid `7555`
  - `hud-hook serve --port 7474` pid `7628`
  - `/health` returned `status: ok`, `protocol_version: 1`, `schema_version: 3`, `auth_mode: bearer`, and `service_mode: bootstrap_only`.

## Manual Status

Partially exercised in the running app:

- Computer Use opened the fresh `CapacitorDebug.app` from `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.
- The app showed all visible projects as `Idle`.
- Process evidence showed no live Claude Code CLI process to use for a real ready-session safe-wake scenario.
- Runtime logs showed the app ingesting snapshots from the restarted runtime service.

Follow-up live check result:

1. Added a related no-op verification Task to the real `parable-school` `Typeface unification from source parable` Work Batch.
2. The Task joined the existing batch instead of creating a new batch.
3. Before the patch, the Task stayed queued because runtime reported the assigned session as `signal_absence`, `idle`, `is_alive=false`, even though direct process evidence showed the exact Claude process alive in the Batch Worktree.
4. After the patch and `./scripts/dev/restart-alpha-stable.sh`, Capacitor delivered `claude_wake` to the existing assigned session without launching a new Ghostty/tmux/Claude cockpit.
5. Claude wrote a claim artifact and then a Done artifact; Capacitor marked the Task done and the batch ready.

State evidence after completion:

```json
{
  "batch": "Typeface unification from source parable",
  "status": "ready",
  "task": "01KSK2QPJEJVNWY12ATPPEAQ3X",
  "task_status": "done",
  "last_delivery_attempt_at": "2026-05-26T21:47:04Z",
  "last_delivery_attempt_kind": "wake_existing_session",
  "last_claim_at": "2026-05-26T21:47:04Z"
}
```

Activation trace:

```text
[2026-05-26T21:47:07.876Z] [TerminalActivation] surface="work_batch_session" route="claude_wake" action="wake_existing" outcome="delivered" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,terminal_input"
```

Artifacts:

```text
/Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source/.capacitor/work-batch-claims/01KSK2QPJEJVNWY12ATPPEAQ3X.json
/Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source/.capacitor/work-batch-completions/01KSK2QPJEJVNWY12ATPPEAQ3X.json
```

Result: pass.

## Remaining Risk

- Runtime `ready` must continue to mean "Claude Code is at a safe input boundary." The process-backed `signal_absence` exception must stay narrow and require runtime awaiting-input evidence.
- The wake prompt is intentionally tiny: `Assessing updated tasks...`. If this still leaks too much or too little in the actual Claude session, tune the prompt after live observation rather than widening the policy.
