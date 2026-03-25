//! Relay for writing checkpoint bridge decision files after successful run mutations.
//!
//! Called from the `/runtime/run/mutate` handler when a `SubmitDecision` mutation succeeds.
//! Reads the pending marker, writes a `CheckpointBridgeDecision` via the shared
//! `checkpoint_bridge_protocol` format, then cleans up the pending file.
//! Fail-open: all errors are logged via `tracing::warn` but silently swallowed so that
//! a relay failure never blocks the mutation response path.

use std::io::ErrorKind;
use std::path::Path;

use capacitor_core::{
    domain::{now_rfc3339, MutateRunCommand, MutationOutcome, RunMutationKind},
    method_runner::checkpoint_bridge_protocol::{
        decision_path, pending_path, write_json_atomic, CheckpointBridgeDecision,
        CheckpointBridgePending, CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
    },
};

pub fn relay_decision(home_dir: &Path, command: &MutateRunCommand, outcome: &MutationOutcome) {
    if command.kind != RunMutationKind::SubmitDecision || !outcome.ok {
        return;
    }

    let checkpoint_id = match command.checkpoint_id.as_deref() {
        Some(value) if !value.trim().is_empty() => value,
        _ => {
            tracing::warn!(run_id = %command.run_id, "checkpoint bridge relay skipped: missing checkpoint_id");
            return;
        }
    };

    let action = match command.decision_action.as_deref() {
        Some(value) if !value.trim().is_empty() => value.trim().to_string(),
        _ => {
            tracing::warn!(
                run_id = %command.run_id,
                checkpoint_id = checkpoint_id,
                "checkpoint bridge relay skipped: missing decision_action"
            );
            return;
        }
    };

    let pending_file = pending_path(home_dir, &command.run_id, checkpoint_id);
    if !pending_file.exists() {
        return;
    }

    let pending_payload = match fs_err::read_to_string(&pending_file) {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(
                path = ?pending_file,
                error = %error,
                "checkpoint bridge relay skipped: failed to read pending marker"
            );
            return;
        }
    };

    let pending_marker: CheckpointBridgePending = match serde_json::from_str(&pending_payload) {
        Ok(marker) => marker,
        Err(error) => {
            tracing::warn!(
                path = ?pending_file,
                error = %error,
                "checkpoint bridge relay skipped: failed to parse pending marker"
            );
            return;
        }
    };

    let decision = CheckpointBridgeDecision {
        version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
        run_id: command.run_id.clone(),
        checkpoint_id: checkpoint_id.to_string(),
        action,
        note: command.decision_note.clone(),
        decided_at: now_rfc3339(),
    };
    let decision_file = decision_path(home_dir, &command.run_id, checkpoint_id);

    if let Err(error) = write_json_atomic(&decision_file, &decision) {
        tracing::warn!(
            path = ?decision_file,
            run_id = %pending_marker.run_id,
            checkpoint_id = %pending_marker.checkpoint_id,
            error = %error,
            "checkpoint bridge relay failed to write decision file"
        );
        return;
    }

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
}
