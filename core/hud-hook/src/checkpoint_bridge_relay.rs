//! Relay for staging and committing checkpoint bridge decision files.
//!
//! Called from the `/runtime/run/mutate` handler around `SubmitDecision` mutations.
//! Preparation validates the runtime-owned relay requirement, reads the pending marker, and
//! writes a prepared `CheckpointBridgeDecision` via the shared `checkpoint_bridge_protocol`
//! format before the reducer commit. The reducer commit only performs the final rename, keeping
//! expensive filesystem work outside the runtime state lock. Missing pending markers are a no-op
//! for non-bridge checkpoints and an error for bridge-managed checkpoints.

use std::ffi::OsString;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use capacitor_core::{
    domain::{now_rfc3339, CheckpointDecisionRelay, MutateRunCommand, RunMutationKind},
    method_runner::checkpoint_bridge_protocol::{
        decision_path, pending_path, write_json_atomic, CheckpointBridgeDecision,
        CheckpointBridgePending, CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
    },
};

#[derive(Debug)]
pub struct PreparedCheckpointBridgeDecision {
    pending_file: PathBuf,
    prepared_decision_file: PathBuf,
    decision_file: PathBuf,
}

pub fn prepare_decision(
    home_dir: &Path,
    command: &MutateRunCommand,
    relay: Option<CheckpointDecisionRelay>,
) -> Result<Option<PreparedCheckpointBridgeDecision>, String> {
    if command.kind != RunMutationKind::SubmitDecision {
        return Ok(None);
    }
    if relay != Some(CheckpointDecisionRelay::CheckpointBridge) {
        return Ok(None);
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
        return Err(format!(
            "missing checkpoint bridge pending marker {:?}",
            pending_file
        ));
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
    let prepared_decision_file = prepared_decision_path(&decision_file);

    write_json_atomic(&prepared_decision_file, &decision).map_err(|error| {
        format!(
            "failed to write prepared decision file {:?}: {error}",
            prepared_decision_file
        )
    })?;

    Ok(Some(PreparedCheckpointBridgeDecision {
        pending_file,
        prepared_decision_file,
        decision_file,
    }))
}

pub fn commit_prepared_decision(prepared: &PreparedCheckpointBridgeDecision) -> Result<(), String> {
    fs_err::rename(&prepared.prepared_decision_file, &prepared.decision_file).map_err(|error| {
        format!(
            "failed to commit prepared decision file {:?} to {:?}: {error}",
            prepared.prepared_decision_file, prepared.decision_file
        )
    })
}

pub fn cleanup_committed_decision(prepared: &PreparedCheckpointBridgeDecision) {
    if let Err(error) = fs_err::remove_file(&prepared.pending_file) {
        tracing::warn!(
            path = ?prepared.pending_file,
            error = %error,
            "checkpoint bridge relay failed to remove pending marker"
        );
    }

    if let Some(run_dir) = prepared.pending_file.parent() {
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

pub fn cleanup_prepared_decision(prepared: &PreparedCheckpointBridgeDecision) {
    if let Err(error) = fs_err::remove_file(&prepared.prepared_decision_file) {
        if error.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!(
                path = ?prepared.prepared_decision_file,
                error = %error,
                "checkpoint bridge relay failed to remove prepared decision file"
            );
        }
    }
}

pub fn cleanup_after_failed_mutation(prepared: &PreparedCheckpointBridgeDecision) {
    if prepared.decision_file.exists() {
        cleanup_committed_decision(prepared);
    } else {
        cleanup_prepared_decision(prepared);
    }
}

fn prepared_decision_path(decision_file: &Path) -> PathBuf {
    let file_name = decision_file
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| OsString::from("checkpoint-bridge-decision"));
    let mut prepared_name = file_name;
    prepared_name.push(".prepared");
    decision_file.with_file_name(prepared_name)
}
