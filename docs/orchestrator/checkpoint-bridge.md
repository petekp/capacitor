# Checkpoint Bridge

> Doc role: `canonical-spec`
> Status: Current. Describes the gate-to-checkpoint-to-decision-to-unblock pipeline.

## Overview

The checkpoint bridge connects method runner gates to the run kernel checkpoint system and the Swift review UI. When a method runner gate requires human approval, the bridge writes a file-based pending marker, emits a bridge-managed checkpoint into the runtime (via HTTP mutation), and then polls for a decision file. The Swift app detects the paused run through its normal runtime snapshot refresh, opens a review window, and when the user decides, sends a `SubmitDecision` mutation back through the runtime service. The hud-hook HTTP handler stages and commits the decision file as part of the accepted mutation so the polling bridge can unblock the gate.

## Pipeline Flow

1. **Gate hit** -- The method runner executor evaluates a gate and calls `InteractiveIO::emit_gate_checkpoint(context)` with a `GateCheckpointContext` containing gate_id, phase_id, checkpoint_kind, title, summary, manifest_path, media_artifacts, and mermaid_sources.
   - Trait definition: `core/capacitor-core/src/method_runner/adapters.rs:157-164`

2. **Path validation** -- `BridgeInteractiveIO::emit_gate_checkpoint` validates both `run_id` and `gate_id` via `validate_path_component()` to prevent path traversal. On failure, it falls back to the standard interactive prompt.
   - Validation: `checkpoint_bridge.rs:239-256`
   - `validate_path_component`: `checkpoint_bridge_protocol.rs:18-34`

3. **Pending marker write** -- The bridge writes a `CheckpointBridgePending` JSON file to `~/.capacitor/runtime/checkpoint-bridge/<run_id>/<checkpoint_id>.pending.json` using atomic rename (`write_json_atomic`).
   - `checkpoint_bridge.rs:258-270`

4. **Runtime mutation** -- The bridge POSTs a `MutateRunCommand` with `kind: EmitCheckpoint` to the runtime service endpoint (`/runtime/run/mutate`). The command carries `checkpoint_id` set to the gate_id, `checkpoint_decision_relay: "checkpoint_bridge"`, plus checkpoint metadata (kind, title, summary, manifest_path, media_artifacts, mermaid_sources).
   - `checkpoint_bridge.rs:67-95` (command construction)
   - `checkpoint_bridge.rs:166-185` (`post_checkpoint`)

5. **Gate armed** -- On successful mutation, the bridge stores `gate_id` in `current_gate_id`. The subsequent `capture_response()` call will poll for the decision file instead of falling back to stdin/fake IO.
   - `checkpoint_bridge.rs:283`

6. **Swift UI surfaces checkpoint** -- The Swift app's runtime snapshot refresh detects a run with `status == "paused"` and a non-nil `activeCheckpoint`. `AppState.reconcileRunCheckpointWindowTarget` selects the oldest eligible checkpoint and sets `runCheckpointWindowTarget`, which triggers the `RunCheckpointReviewWindow` to open.
   - Routing: `apps/swift/Sources/Capacitor/Models/AppState.swift:1776-1814`
   - Eligibility: `AppState.swift:1817-1818` -- `run.status == "paused" && run.activeCheckpoint != nil`
   - Window: `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift:3`

7. **User submits decision** -- The review window calls `appState.submitRunCheckpointDecision(projectPath:runID:checkpointID:action:note:)` which sends a `MutateRunCommand` with `kind: "submit_decision"`, `checkpoint_id`, `decision_action` ("approve" or "request_changes"), and optional `decision_note`.
   - `RunCheckpointReviewWindow.swift:437-458` (submit flow)
   - `AppState.swift:1414-1429` (mutation dispatch)

8. **Relay commits decision file** -- The hud-hook HTTP handler (`handle_runtime_mutate_run`) looks up the active checkpoint's relay requirement. For bridge-managed checkpoints, it reads the pending marker and writes a prepared `CheckpointBridgeDecision` file before entering the runtime mutation commit. The commit callback then performs the final prepared-file rename. If the pending marker is missing/malformed or the decision file cannot be committed, the run mutation is rejected and the active checkpoint remains visible for retry.
   - HTTP handler: `core/hud-hook/src/handlers.rs:498-535`
   - Relay logic: `core/hud-hook/src/checkpoint_bridge_relay.rs`

9. **Bridge polls and unblocks** -- `BridgeInteractiveIO::capture_response()` polls for the decision file at 500ms intervals. When found, it normalizes the action ("approve"/"approved" -> "approved", "request_changes"/"rejected" -> "rejected", unknown -> "rejected"), clears `current_gate_id`, deletes the decision file, and returns the normalized response to the gate evaluator.
   - Poll loop: `checkpoint_bridge.rs:197-239`
   - Normalization: `checkpoint_bridge.rs:116-128`

## Protocol Format

The bridge communicates between method runner and hud-hook relay through JSON files in `~/.capacitor/runtime/checkpoint-bridge/<run_id>/`.

**Directory layout** (`checkpoint_bridge_protocol.rs:118-124`):

```
~/.capacitor/runtime/checkpoint-bridge/
  <run_id>/
    <checkpoint_id>.pending.json   # Written by bridge, read by relay
    <checkpoint_id>.json           # Written by relay, read by bridge
```

**`CheckpointBridgePending`** (`checkpoint_bridge_protocol.rs:36-47`):

```json
{
  "version": 1,
  "project_path": "/path/to/project",
  "run_id": "run-42",
  "checkpoint_id": "gate-review",
  "phase_id": "phase-001",
  "gate_type": "approval",
  "manifest_path": "/path/to/project/artifacts/checkpoint-manifest.json",
  "created_at": "2026-03-24T10:00:00+00:00"
}
```

**`CheckpointBridgeDecision`** (`checkpoint_bridge_protocol.rs:49-59`):

```json
{
  "version": 1,
  "run_id": "run-42",
  "checkpoint_id": "gate-review",
  "action": "approve",
  "note": "Looks good.",
  "decided_at": "2026-03-24T10:05:00+00:00"
}
```

Both structs use `#[serde(deny_unknown_fields)]` for strict deserialization. The protocol version is `CHECKPOINT_BRIDGE_PROTOCOL_VERSION = 1` (`checkpoint_bridge_protocol.rs:14`). The bridge rejects decision files with a mismatched version (`checkpoint_bridge.rs:145-150`).

All file writes use `write_json_atomic` (`checkpoint_bridge_protocol.rs:73-116`), which writes to a `.tmp` sibling and renames into place to prevent partial reads.

## Fail Modes

### Bridge Side (fail-closed)

Any failure in `emit_gate_checkpoint` cleans up state and falls back to the interactive prompt so the gate can still be resolved via stdin or auto-approve/reject:

- **Path validation failure** (unsafe `run_id` or `gate_id`): Falls back to prompt without writing any files. `checkpoint_bridge.rs:239-256`
- **Pending marker write failure**: Falls back to prompt. `checkpoint_bridge.rs:261-270`
- **Runtime mutation rejected** (`ok: false`): Deletes the pending marker and falls back to prompt. The `current_gate_id` is never set, so `capture_response()` delegates to the fallback IO. `checkpoint_bridge.rs:272-281`
- **Runtime mutation HTTP error**: Same cleanup and fallback path. `checkpoint_bridge.rs:177-183`
- **Decision file parse error** during poll: Returns "rejected" and deletes the corrupt file. `checkpoint_bridge.rs:225-232`
- **Decision file version mismatch**: Returns error, which triggers "rejected" response. `checkpoint_bridge.rs:145-150`

The key invariant: `current_gate_id` is only set to `Some(gate_id)` after all of pending marker write + runtime mutation succeed (`checkpoint_bridge.rs:283`). If either step fails, `capture_response()` falls through to the fallback IO.

### Relay Side (commit-coupled)

The bridge relay is part of the successful `SubmitDecision` commit for bridge-managed checkpoints:

- **Wrong mutation kind**: No-op.
- **No pending marker on disk for non-bridge checkpoint**: No-op.
- **No pending marker on disk for bridge-managed checkpoint**: Returns an error. The runtime mutation is rejected and the active checkpoint remains visible/retryable.
- **Malformed or unreadable pending marker**: Returns an error. The runtime mutation is rejected and the active checkpoint remains visible/retryable.
- **Decision file write failure**: Returns an error. The runtime mutation is rejected and the active checkpoint remains visible/retryable.
- **Pending marker cleanup failure after decision write**: Logs warning but does not reject, because the bridge can already unblock from the decision file.

The key invariant: bridge-managed status is runtime truth (`active_checkpoint.decision_relay == checkpoint_bridge`), not inferred from filesystem marker presence. For bridge-managed checkpoints, the runtime does not accept and clear a `SubmitDecision` unless the bridge decision file was committed successfully.

Accepted decisions move the decided checkpoint from `active_checkpoint` into the run's bounded `past_checkpoints` history, preserving the decision, timestamp, and review metadata for snapshot consumers. The run kernel keeps the most recent 50 decided checkpoints per run.

### Timeout Behavior

`DECISION_POLL_TIMEOUT` is 3600 seconds (1 hour). Defined at `checkpoint_bridge.rs:28`. After timeout, `capture_response` returns `InteractiveResponse { body: "rejected" }` so the method runner can proceed rather than blocking forever. The poll interval is 500ms (`checkpoint_bridge.rs:223`).

## CLI Integration

The `method-runner` binary accepts bridge flags to enable runtime-service-backed checkpoint IO:

| Flag | Purpose |
|------|---------|
| `--bridge-run-id <run-id>` | Enable bridge mode for the given run id |
| `--bridge-project-path <path>` | Override bridge project path (defaults to `--root`) |
| `--real` | Use real subprocess adapters (orthogonal to bridge) |

- `BridgeOptions` struct: `core/capacitor-core/src/bin/method_runner.rs:20-23`
- Flag parsing: `method_runner.rs:371-377`
- `--bridge-project-path` requires `--bridge-run-id`: `method_runner.rs:311-313`
- `bridge_project_path` defaults to `--root` when omitted: `method_runner.rs:322-325`

**`make_interactive_io()` selection** (`method_runner.rs:449-477`):

1. Constructs a fallback IO based on `--approve` / `--reject` / `--response-dir` (default: auto-approve)
2. If no bridge options are present, returns the fallback directly
3. If bridge is enabled, discovers the runtime service endpoint via `RuntimeServiceEndpoint::discover()`, then wraps the fallback in `BridgeInteractiveIO`

The fallback IO is passed as the `fallback` field of `BridgeInteractiveIO`. Prompt emissions always delegate to the fallback (`checkpoint_bridge.rs:189-191`). Response capture only uses the bridge path when `current_gate_id` is `Some`; otherwise it delegates to fallback (`checkpoint_bridge.rs:199-201`).

## Identity Invariant

`checkpoint_id == gate_id` for all bridge-managed checkpoints. This is established in `checkpoint_command()` at `checkpoint_bridge.rs:84` where the command's `checkpoint_id` is set to `context.gate_id`, and in `pending_marker()` at `checkpoint_bridge.rs:104` where the pending marker's `checkpoint_id` is also the gate_id.

This identity is what allows the relay to find the correct pending marker: the Swift UI sends back the `checkpoint_id` from the runtime snapshot in its `SubmitDecision` mutation, and the relay uses that same ID to look up `<checkpoint_id>.pending.json` on disk.

## Key Files

| File | Purpose |
|------|---------|
| `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` | `BridgeInteractiveIO` -- emit checkpoint, poll for decision, normalize response |
| `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs` | JSON protocol structs, file path helpers, atomic write utility |
| `core/capacitor-core/src/method_runner/adapters.rs:157-164` | `InteractiveIO` trait with `emit_gate_checkpoint` default impl |
| `core/hud-hook/src/checkpoint_bridge_relay.rs` | stages prepared decision files, commits final decision files, and cleans relay artifacts |
| `core/hud-hook/src/handlers.rs` | HTTP handler that couples bridge relay commit to `SubmitDecision` runtime mutation |
| `core/capacitor-core/src/bin/method_runner.rs` | CLI flags (`--bridge-run-id`, `--bridge-project-path`) and `make_interactive_io()` |
| `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift` | SwiftUI review window -- content pane, decision rail, submit flow |
| `apps/swift/Sources/Capacitor/Models/AppState.swift:1776-1882` | Checkpoint target reconciliation, eligibility, and ordering |

## Test Contracts

### `core/capacitor-core/tests/method_runner/checkpoint_bridge.rs`

| Test | What it proves |
|------|---------------|
| `t4_checkpoint_bridge_protocol_paths_are_stable` (line 613) | Pending and decision file paths match the documented layout |
| `t5_bridge_emits_runtime_mutation_and_pending_marker` (line 629) | `emit_gate_checkpoint` POSTs the correct `MutateRunCommand` and writes a valid pending marker |
| `t6_bridge_normalizes_approve_to_approved` (line 701) | Decision with action "approve" becomes response "approved" |
| `t7_bridge_normalizes_request_changes_to_rejected` (line 748) | Decision with action "request_changes" becomes response "rejected" |
| `t8_executor_only_bridges_human_gates` (line 793) | Only human-type gates go through the bridge; auto gates skip it |
| `t9_bridge_generated_manifest_stays_swift_compatible` (line 881) | Checkpoint metadata round-trips correctly for the Swift decoder |
| `t13_bridge_crash_recovery_reemits_idempotently_and_returns_existing_decision_immediately` (line 1084) | After crash/restart, re-emitting a checkpoint picks up an existing decision file without re-polling |
| `t14_bridge_isolates_same_gate_id_across_concurrent_runs` (line 1190) | Two runs with the same gate_id use separate bridge directories and do not cross-contaminate |
| `t15_bridge_falls_back_to_prompt_when_mutation_rejected` (line 1359) | Runtime rejection triggers fallback to interactive prompt (fail-closed) |
| `t15_bridge_falls_back_to_prompt_when_server_unreachable` (line 1399) | Unreachable server triggers fallback to interactive prompt (fail-closed) |

### `core/hud-hook/tests/serve_integration.rs`

| Test | What it proves |
|------|---------------|
| `runtime_run_submit_decision_writes_checkpoint_bridge_file_when_pending_marker_exists` | Relay writes decision file and cleans up pending marker on successful `SubmitDecision` |
| `runtime_run_submit_decision_is_noop_without_checkpoint_bridge_pending_marker` | Relay is a no-op when no pending marker exists (non-bridge mutations) |
| `runtime_run_submit_decision_ignores_stale_bridge_marker_for_non_bridge_checkpoint` | Stale bridge marker files do not affect checkpoints without runtime bridge relay ownership |
| `runtime_run_submit_decision_rejects_bridge_checkpoint_when_pending_marker_is_missing` | Bridge-owned checkpoints reject decisions when the pending marker is missing |
| `runtime_run_submit_decision_does_not_write_checkpoint_bridge_file_when_mutation_is_rejected` | Relay does not write decision file when the runtime rejects the mutation |
| `runtime_run_submit_decision_rejects_when_checkpoint_bridge_pending_marker_is_malformed` | Malformed pending markers reject the mutation and leave the checkpoint retryable |
| `runtime_run_submit_decision_rejects_when_checkpoint_bridge_decision_file_cannot_be_written` | Decision write failures reject the mutation and leave the checkpoint retryable |
| `runtime_run_submit_decision_does_not_write_checkpoint_bridge_file_when_unauthorized` | Unauthorized requests never trigger the relay |

### `apps/swift/Tests/CapacitorTests/AppStateRunCheckpointTests.swift`

| Test | What it proves |
|------|---------------|
| `testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState` (line 7) | Checkpoint targeting is independent of delegation review state |
| `testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst` (line 50) | Queue ordering selects oldest checkpoint first |
| `testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears` (line 87) | After a checkpoint clears, the next queued checkpoint surfaces automatically |
| `testSubmitRunCheckpointDecisionMutatesRuntimeRunWithCheckpointIdentity` (line 146) | Decision submission sends correct mutation payload including `checkpoint_id` and `decision_action` |
