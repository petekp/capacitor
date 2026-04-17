//! Relay for writing checkpoint bridge decision files as part of run mutation commit.
//!
//! Called from the `/runtime/run/mutate` handler while a `SubmitDecision` mutation is committing.
//! Reads the pending marker, writes a `CheckpointBridgeDecision` via the shared
//! `checkpoint_bridge_protocol` format, then cleans up the pending file.
//! Missing pending markers are a no-op because non-bridge checkpoints use the same mutation.
//! Malformed pending markers and decision write failures reject the runtime mutation so the
//! active checkpoint remains visible and retryable.

use std::io::ErrorKind;
use std::path::Path;

use capacitor_core::{
    domain::{now_rfc3339, MutateRunCommand, RunMutationKind},
    method_runner::checkpoint_bridge_protocol::{
        decision_path, pending_path, write_json_atomic, CheckpointBridgeDecision,
        CheckpointBridgePending, CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
    },
};

pub fn relay_decision(home_dir: &Path, command: &MutateRunCommand) -> Result<(), String> {
    if command.kind != RunMutationKind::SubmitDecision {
        return Ok(());
    }

    let checkpoint_id = match command.checkpoint_id.as_deref() {
        Some(value) if !value.trim().is_empty() => value,
        _ => {
            return Err("missing checkpoint_id".to_string());
        }
    };

    let action = match command.decision_action.as_deref() {
        Some(value) if !value.trim().is_empty() => value.trim().to_string(),
        _ => {
            return Err("missing decision_action".to_string());
        }
    };

    let pending_file = pending_path(home_dir, &command.run_id, checkpoint_id);
    if !pending_file.exists() {
        return Ok(());
    }

    let pending_payload = fs_err::read_to_string(&pending_file)
        .map_err(|error| format!("failed to read pending marker {:?}: {error}", pending_file))?;

    let pending_marker: CheckpointBridgePending = serde_json::from_str(&pending_payload)
        .map_err(|error| format!("failed to parse pending marker {:?}: {error}", pending_file))?;

    if pending_marker.run_id != command.run_id {
        return Err(format!(
            "pending marker run_id {:?} does not match command run_id {:?}",
            pending_marker.run_id, command.run_id
        ));
    }
    if pending_marker.checkpoint_id != checkpoint_id {
        return Err(format!(
            "pending marker checkpoint_id {:?} does not match command checkpoint_id {:?}",
            pending_marker.checkpoint_id, checkpoint_id
        ));
    }

    let decision = CheckpointBridgeDecision {
        version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
        run_id: command.run_id.clone(),
        checkpoint_id: checkpoint_id.to_string(),
        action,
        note: command.decision_note.clone(),
        decided_at: now_rfc3339(),
    };
    let decision_file = decision_path(home_dir, &command.run_id, checkpoint_id);

    write_json_atomic(&decision_file, &decision)
        .map_err(|error| format!("failed to write decision file {:?}: {error}", decision_file))?;

    if let Err(error) = fs_err::remove_file(&pending_file) {
        tracing::warn!(
            path = ?pending_file,
            error = %error,
            "checkpoint bridge relay failed to remove pending marker"
        );
    }

    if let Some(run_dir) = pending_file.parent() {
        match fs_err::remove_dir(run_dir) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::DirectoryNotEmpty | ErrorKind::NotFound
                ) => {}
            Err(error) => {
                tracing::warn!(
                    path = ?run_dir,
                    error = %error,
                    "checkpoint bridge relay failed to remove run directory"
                );
            }
        }
    }

    Ok(())
}
