//! Run Kernel reducer.
//!
//! Handles `MutateRunCommand` mutations against run state.
//! Coexists with the delegation reducer during the strangler-pattern migration.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, Utc};

use super::utils::parse_rfc3339;
use crate::domain::{
    method_registry, now_rfc3339, ActiveCheckpoint, CaptureClaim, CaptureStatus,
    CheckpointDecision, CheckpointStatus, MutateRunCommand, MutationOutcome, PhaseInstance,
    PhaseStatus, RunMutationKind, RunState, RunStatus,
};

const TERMINAL_RUN_RETENTION: Duration = Duration::hours(24);
const CREATED_RUN_EXPIRY: Duration = Duration::hours(2);

/// Apply a run mutation to the runs map. Returns a `MutationOutcome`.
pub(crate) fn apply_run_mutation(
    runs: &mut BTreeMap<String, RunState>,
    command: MutateRunCommand,
) -> MutationOutcome {
    let project_path = command.project_path.trim().to_string();
    if project_path.is_empty() {
        return reject("missing project_path");
    }

    let run_id = command.run_id.trim().to_string();
    if run_id.is_empty() {
        return reject("missing run_id");
    }

    let key = run_key(&project_path, &run_id);

    match command.kind {
        RunMutationKind::Create => handle_create(runs, &key, &project_path, &run_id, &command),
        RunMutationKind::Start => handle_start(runs, &key, &command),
        RunMutationKind::Heartbeat => handle_heartbeat(runs, &key, &command),
        RunMutationKind::AdvancePhase => handle_advance_phase(runs, &key),
        RunMutationKind::EmitCheckpoint => handle_emit_checkpoint(runs, &key, &command),
        RunMutationKind::SubmitDecision => handle_submit_decision(runs, &key, &command),
        RunMutationKind::CaptureClaim => handle_capture_claim(runs, &key, &command),
        RunMutationKind::CaptureFailed => handle_capture_failed(runs, &key, &command),
        RunMutationKind::CaptureComplete => handle_capture_complete(runs, &key, &command),
        RunMutationKind::AttachSession => handle_attach_session(runs, &key, &command),
        RunMutationKind::DetachSession => handle_detach_session(runs, &key),
        RunMutationKind::Pause => handle_status_transition(runs, &key, RunStatus::Paused, "pause"),
        RunMutationKind::Resume => {
            handle_status_transition(runs, &key, RunStatus::Active, "resume")
        }
        RunMutationKind::Complete => {
            handle_status_transition(runs, &key, RunStatus::Completed, "complete")
        }
        RunMutationKind::Fail => handle_status_transition(runs, &key, RunStatus::Failed, "fail"),
        RunMutationKind::Cancel => {
            handle_status_transition(runs, &key, RunStatus::Cancelled, "cancel")
        }
    }
}

pub(crate) fn cleanup_runs(runs: &mut BTreeMap<String, RunState>) {
    cleanup_runs_at(runs, Utc::now());
}

pub(crate) fn cleanup_runs_at(runs: &mut BTreeMap<String, RunState>, now: DateTime<Utc>) {
    let expired_run_keys: Vec<_> = runs
        .iter()
        .filter(|(_, run)| is_expired_terminal_run(run, now))
        .map(|(key, _)| key.clone())
        .collect();

    for run in runs.values_mut() {
        expire_created_run_if_needed(run, now);
    }

    for key in expired_run_keys {
        runs.remove(&key);
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handle_create(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    project_path: &str,
    run_id: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    if runs.contains_key(key) {
        return reject("run already exists");
    }

    let method_id = match &command.method_id {
        Some(id) if !id.trim().is_empty() => id.trim().to_string(),
        _ => return reject("missing method_id for create"),
    };

    let method = match method_registry::find_method(&method_id) {
        Some(m) => m,
        None => return reject(&format!("unknown method: {method_id}")),
    };

    let involvement = command.involvement.unwrap_or(method.default_involvement);

    let phases: Vec<PhaseInstance> = method
        .phases
        .iter()
        .enumerate()
        .map(|(i, t)| PhaseInstance::from_template(t, i))
        .collect();

    let now = now_rfc3339();
    let run = RunState {
        id: run_id.to_string(),
        project_path: project_path.to_string(),
        method_id: method.id.clone(),
        method_name: method.name.clone(),
        involvement,
        status: RunStatus::Created,
        phases,
        current_phase_index: 0,
        active_checkpoint: None,
        past_checkpoints: Vec::new(),
        session_id: None,
        delegation_worker_id: command.delegation_worker_id.clone(),
        status_message: None,
        idea_id: command.idea_id.clone(),
        idea_title: command.idea_title.clone(),
        idea_description: command.idea_description.clone(),
        created_at: now.clone(),
        updated_at: now,
    };

    runs.insert(key.to_string(), run);
    ok("run created")
}

fn handle_start(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    // Idempotent: if already started, just update the message and timestamp.
    if run.status != RunStatus::Created {
        if let Some(msg) = normalized_optional_text(command.status_message.as_deref()) {
            run.status_message = Some(msg);
        }
        run.updated_at = now_rfc3339();
        return ok("run already started");
    }

    // Transition Created -> Active, activate phase 0.
    run.status = RunStatus::Active;
    if let Some(phase) = run.phases.get_mut(0) {
        phase.status = PhaseStatus::Active;
        phase.started_at = Some(now_rfc3339());
    }
    run.status_message = normalized_optional_text(command.status_message.as_deref());
    run.updated_at = now_rfc3339();
    ok("run started")
}

fn handle_heartbeat(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    if let Some(msg) = normalized_optional_text(command.status_message.as_deref()) {
        run.status_message = Some(msg);
    }
    run.updated_at = now_rfc3339();
    ok("heartbeat recorded")
}

fn handle_advance_phase(runs: &mut BTreeMap<String, RunState>, key: &str) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    if run.active_checkpoint.is_some() {
        return reject("active checkpoint must be decided before advancing");
    }

    let idx = run.current_phase_index as usize;

    // Complete current phase
    if let Some(phase) = run.phases.get_mut(idx) {
        phase.status = PhaseStatus::Completed;
        phase.completed_at = Some(now_rfc3339());
    }

    let next_idx = idx + 1;
    if next_idx >= run.phases.len() {
        // All phases done
        run.status = RunStatus::Completed;
        run.updated_at = now_rfc3339();
        return ok("all phases completed, run finished");
    }

    // Activate next phase
    run.current_phase_index = next_idx as u32;
    if let Some(phase) = run.phases.get_mut(next_idx) {
        phase.status = PhaseStatus::Active;
        phase.started_at = Some(now_rfc3339());
    }
    run.status = RunStatus::Active;
    run.updated_at = now_rfc3339();
    ok("advanced to next phase")
}

fn handle_emit_checkpoint(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    let checkpoint_kind = match &command.checkpoint_kind {
        Some(k) => k.clone(),
        None => return reject("missing checkpoint_kind"),
    };

    let title = command
        .checkpoint_title
        .as_deref()
        .unwrap_or("Checkpoint")
        .to_string();

    let checkpoint_id = command
        .checkpoint_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let phase_id = run
        .current_phase()
        .map(|p| p.id.clone())
        .unwrap_or_default();

    if let Some(active_checkpoint) = run.active_checkpoint.as_ref() {
        let same_checkpoint = checkpoint_id
            .map(|id| active_checkpoint.id == id)
            .unwrap_or(false)
            && active_checkpoint.kind == checkpoint_kind
            && active_checkpoint.title == title
            && active_checkpoint.manifest_path == command.checkpoint_manifest_path;

        if same_checkpoint {
            return ok("checkpoint already active");
        }

        return reject("checkpoint already active");
    }

    let now = now_rfc3339();
    let checkpoint_id = checkpoint_id
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{}:{}:ckpt-{}", run.id, phase_id, now.replace(':', "-")));

    let capture_url = normalized_optional_text(command.capture_url.as_deref());
    let capture_status = if capture_url.is_some() {
        CaptureStatus::Pending
    } else {
        CaptureStatus::NotRequested
    };

    run.active_checkpoint = Some(ActiveCheckpoint {
        id: checkpoint_id,
        phase_id,
        kind: checkpoint_kind,
        status: CheckpointStatus::Active,
        title,
        summary: command.checkpoint_summary.clone(),
        brief_path: command.checkpoint_brief_path.clone(),
        manifest_path: command.checkpoint_manifest_path.clone(),
        media_artifacts: command.checkpoint_media_artifacts.clone(),
        mermaid_sources: command.checkpoint_mermaid_sources.clone(),
        capture_status,
        capture_url,
        capture_claim: None,
        decision_relay: command.checkpoint_decision_relay,
        decision: None,
        created_at: now.clone(),
        decided_at: None,
    });

    run.status = RunStatus::Paused;
    run.updated_at = now;
    ok("checkpoint emitted, run paused")
}

fn handle_capture_claim(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status != RunStatus::Paused {
        return reject("run is not paused");
    }

    let checkpoint_id = match require_checkpoint_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let capture_request_id = match require_capture_request_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let client_id = match require_client_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };

    let observed_capture_url = normalized_optional_text(command.observed_capture_url.as_deref());
    let now = now_rfc3339();
    let checkpoint = match active_checkpoint_for_command(run, checkpoint_id) {
        Ok(checkpoint) => checkpoint,
        Err(outcome) => return outcome,
    };

    if checkpoint.capture_status != CaptureStatus::Pending {
        return reject("capture is not pending");
    }

    let capture_url = match normalized_optional_text(checkpoint.capture_url.as_deref()) {
        Some(value) => value,
        None => return reject("checkpoint capture_url missing"),
    };

    checkpoint.capture_status = CaptureStatus::InProgress;
    checkpoint.capture_url = Some(capture_url);
    checkpoint.capture_claim = Some(CaptureClaim {
        capture_request_id: capture_request_id.to_string(),
        client_id: client_id.to_string(),
        claimed_at: now.clone(),
        observed_capture_url,
    });

    run.updated_at = now;
    ok("capture claimed")
}

fn handle_submit_decision(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    let checkpoint_id = match require_checkpoint_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };

    let checkpoint = match active_checkpoint_for_command(run, checkpoint_id) {
        Ok(checkpoint) => checkpoint,
        Err(outcome) => return outcome,
    };

    let action = match normalize_decision_action(command.decision_action.as_deref()) {
        Ok(action) => action,
        Err(outcome) => return outcome,
    };

    let now = now_rfc3339();
    checkpoint.decision = Some(CheckpointDecision {
        action: action.clone(),
        note: command.decision_note.clone(),
    });
    checkpoint.status = CheckpointStatus::Decided;
    checkpoint.decided_at = Some(now.clone());

    // Archive checkpoint and resume run.
    let decided_checkpoint = run.active_checkpoint.take();
    if let Some(checkpoint) = decided_checkpoint {
        run.past_checkpoints.push(checkpoint);
    }

    run.status = RunStatus::Active;
    run.updated_at = now;
    ok(&format!("decision recorded: {action}"))
}

fn normalize_decision_action(action: Option<&str>) -> Result<String, MutationOutcome> {
    let action = match action {
        Some(a) if !a.trim().is_empty() => a.trim().to_ascii_lowercase(),
        _ => return Err(reject("missing decision_action")),
    };

    // Normalize bridge/protocol aliases into runtime-facing actions. This prevents
    // the runtime from resuming the run with an action that the bridge adapter
    // or other consumers don't understand, which would desynchronize state.
    match action.as_str() {
        "approve" | "approved" => Ok("approve".to_string()),
        "request_changes" | "rejected" => Ok("request_changes".to_string()),
        _ => Err(reject(&format!("unrecognized decision_action: {action:?}"))),
    }
}

fn handle_capture_complete(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    if command.completed_media_artifacts.is_empty() {
        return reject("completed_media_artifacts must not be empty");
    }
    with_validated_capture_mutation(runs, key, command, |checkpoint| {
        checkpoint
            .media_artifacts
            .extend(command.completed_media_artifacts.clone());
        checkpoint.capture_status = CaptureStatus::Completed;
        ok("capture completed")
    })
}

fn handle_capture_failed(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let capture_failure_reason =
        match normalized_optional_text(command.capture_failure_reason.as_deref()) {
            Some(value) => value,
            None => return reject("missing capture_failure_reason"),
        };
    with_validated_capture_mutation(runs, key, command, |checkpoint| {
        checkpoint.capture_status = CaptureStatus::Failed {
            reason: capture_failure_reason,
        };
        ok("capture failed")
    })
}

fn handle_attach_session(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    run.session_id = command.session_id.clone();

    // Also link delegation worker if provided
    if command.delegation_worker_id.is_some() {
        run.delegation_worker_id = command.delegation_worker_id.clone();
    }

    // If this is the first activation, start the first phase
    if run.status == RunStatus::Created {
        run.status = RunStatus::Active;
        if let Some(phase) = run.phases.get_mut(0) {
            phase.status = PhaseStatus::Active;
            phase.started_at = Some(now_rfc3339());
        }
    }

    run.updated_at = now_rfc3339();
    ok("session attached")
}

fn handle_detach_session(runs: &mut BTreeMap<String, RunState>, key: &str) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    run.session_id = None;
    run.updated_at = now_rfc3339();
    ok("session detached")
}

fn handle_status_transition(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    target: RunStatus,
    label: &str,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is already in terminal state");
    }

    // For resume, ensure we're paused
    if target == RunStatus::Active && run.status != RunStatus::Paused {
        return reject("can only resume a paused run");
    }

    run.status = target;
    run.updated_at = now_rfc3339();
    ok(&format!("run {label}"))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn require_checkpoint_id(command: &MutateRunCommand) -> Result<&str, MutationOutcome> {
    command
        .checkpoint_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing checkpoint_id"))
}

fn require_capture_request_id(command: &MutateRunCommand) -> Result<&str, MutationOutcome> {
    command
        .capture_request_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing capture_request_id"))
}

fn require_client_id(command: &MutateRunCommand) -> Result<&str, MutationOutcome> {
    command
        .client_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing client_id"))
}

fn with_validated_capture_mutation(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    command: &MutateRunCommand,
    apply: impl FnOnce(&mut ActiveCheckpoint) -> MutationOutcome,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status != RunStatus::Paused {
        return reject("run is not paused");
    }

    let checkpoint_id = match require_checkpoint_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let capture_request_id = match require_capture_request_id(command) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };

    let outcome = {
        let checkpoint = match active_checkpoint_for_command(run, checkpoint_id) {
            Ok(checkpoint) => checkpoint,
            Err(outcome) => return outcome,
        };

        if checkpoint.capture_status != CaptureStatus::InProgress {
            return reject("capture is not in progress");
        }

        let claim = match checkpoint.capture_claim.as_ref() {
            Some(claim) => claim,
            None => return reject("capture claim missing"),
        };
        if claim.capture_request_id != capture_request_id {
            return reject("capture_request_id does not match active claim");
        }

        apply(checkpoint)
    };

    if outcome.ok {
        run.updated_at = now_rfc3339();
    }
    outcome
}

fn normalized_optional_text(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn is_expired_terminal_run(run: &RunState, now: DateTime<Utc>) -> bool {
    run.status.is_terminal()
        && timestamp_is_older_than(run.updated_at.as_str(), TERMINAL_RUN_RETENTION, now)
}

fn expire_created_run_if_needed(run: &mut RunState, now: DateTime<Utc>) {
    if run.status != RunStatus::Created {
        return;
    }

    if !timestamp_is_older_than(run.created_at.as_str(), CREATED_RUN_EXPIRY, now) {
        return;
    }

    run.status = RunStatus::Failed;
    run.updated_at = now.to_rfc3339();
}

fn timestamp_is_older_than(value: &str, threshold: Duration, now: DateTime<Utc>) -> bool {
    let Some(timestamp) = parse_rfc3339(value) else {
        return false;
    };

    now.signed_duration_since(timestamp) > threshold
}

fn active_checkpoint_for_command<'a>(
    run: &'a mut RunState,
    checkpoint_id: &str,
) -> Result<&'a mut ActiveCheckpoint, MutationOutcome> {
    let checkpoint = match run.active_checkpoint.as_mut() {
        Some(checkpoint) => checkpoint,
        None => return Err(reject("no active checkpoint")),
    };

    if checkpoint.id != checkpoint_id {
        return Err(reject("checkpoint_id does not match active checkpoint"));
    }

    if checkpoint.status != CheckpointStatus::Active {
        return Err(reject("checkpoint is not active"));
    }

    Ok(checkpoint)
}

fn run_key(project_path: &str, run_id: &str) -> String {
    format!("{project_path}#{run_id}")
}

fn ok(message: &str) -> MutationOutcome {
    MutationOutcome {
        ok: true,
        message: message.to_string(),
    }
}

fn reject(message: &str) -> MutationOutcome {
    MutationOutcome {
        ok: false,
        message: message.to_string(),
    }
}

#[cfg(test)]
mod tests;
