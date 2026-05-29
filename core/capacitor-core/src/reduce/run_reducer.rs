//! Run Kernel reducer.
//!
//! Handles `MutateRunCommand` mutations against run state.
//! Coexists with the delegation reducer during the strangler-pattern migration.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, Utc};

use super::utils::parse_rfc3339;
use crate::domain::{
    method_registry, now_rfc3339, ActiveCheckpoint, CaptureClaim, CaptureStatus,
    CheckpointDecision, CheckpointDecisionRelay, CheckpointKind, CheckpointStatus,
    InvolvementLevel, MediaArtifact, MermaidSource, MutateRunCommand, MutationOutcome,
    PhaseInstance, PhaseStatus, RunMutationKind, RunState, RunStatus,
};

const TERMINAL_RUN_RETENTION: Duration = Duration::hours(24);
const CREATED_RUN_EXPIRY: Duration = Duration::hours(2);
const PAST_CHECKPOINT_RETENTION: usize = 50;

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
        RunMutationKind::Create {
            method_id,
            involvement,
            delegation_worker_id,
            idea_id,
            idea_title,
            idea_description,
        } => handle_create(
            runs,
            &key,
            &project_path,
            &run_id,
            method_id.as_deref(),
            involvement,
            delegation_worker_id,
            idea_id,
            idea_title,
            idea_description,
        ),
        RunMutationKind::Start { status_message } => {
            handle_start(runs, &key, status_message.as_deref())
        }
        RunMutationKind::Heartbeat { status_message } => {
            handle_heartbeat(runs, &key, status_message.as_deref())
        }
        RunMutationKind::AdvancePhase => handle_advance_phase(runs, &key),
        RunMutationKind::EmitCheckpoint {
            checkpoint_kind,
            checkpoint_title,
            checkpoint_summary,
            checkpoint_brief_path,
            checkpoint_manifest_path,
            checkpoint_media_artifacts,
            checkpoint_mermaid_sources,
            checkpoint_decision_relay,
            capture_url,
            checkpoint_id,
        } => handle_emit_checkpoint(
            runs,
            &key,
            EmitCheckpointArgs {
                checkpoint_kind,
                checkpoint_title,
                checkpoint_summary,
                checkpoint_brief_path,
                checkpoint_manifest_path,
                checkpoint_media_artifacts,
                checkpoint_mermaid_sources,
                checkpoint_decision_relay,
                capture_url,
                checkpoint_id,
            },
        ),
        RunMutationKind::SubmitDecision {
            checkpoint_id,
            decision_action,
            decision_note,
        } => handle_submit_decision(
            runs,
            &key,
            checkpoint_id.as_deref(),
            decision_action.as_deref(),
            decision_note,
        ),
        RunMutationKind::CaptureClaim {
            checkpoint_id,
            capture_request_id,
            client_id,
            observed_capture_url,
        } => handle_capture_claim(
            runs,
            &key,
            checkpoint_id.as_deref(),
            capture_request_id.as_deref(),
            client_id.as_deref(),
            observed_capture_url.as_deref(),
        ),
        RunMutationKind::CaptureFailed {
            checkpoint_id,
            capture_request_id,
            capture_failure_reason,
        } => handle_capture_failed(
            runs,
            &key,
            checkpoint_id.as_deref(),
            capture_request_id.as_deref(),
            capture_failure_reason.as_deref(),
        ),
        RunMutationKind::CaptureComplete {
            checkpoint_id,
            capture_request_id,
            completed_media_artifacts,
        } => handle_capture_complete(
            runs,
            &key,
            checkpoint_id.as_deref(),
            capture_request_id.as_deref(),
            completed_media_artifacts,
        ),
        RunMutationKind::AttachSession {
            session_id,
            delegation_worker_id,
        } => handle_attach_session(runs, &key, session_id, delegation_worker_id),
        RunMutationKind::DetachSession => handle_detach_session(runs, &key),
        RunMutationKind::Pause { status_message } => handle_status_transition(
            runs,
            &key,
            RunStatus::Paused,
            status_message.as_deref(),
            "pause",
        ),
        RunMutationKind::Resume { status_message } => handle_status_transition(
            runs,
            &key,
            RunStatus::Active,
            status_message.as_deref(),
            "resume",
        ),
        RunMutationKind::Complete { status_message } => handle_status_transition(
            runs,
            &key,
            RunStatus::Completed,
            status_message.as_deref(),
            "complete",
        ),
        RunMutationKind::Fail { status_message } => handle_status_transition(
            runs,
            &key,
            RunStatus::Failed,
            status_message.as_deref(),
            "fail",
        ),
        RunMutationKind::Cancel { status_message } => handle_status_transition(
            runs,
            &key,
            RunStatus::Cancelled,
            status_message.as_deref(),
            "cancel",
        ),
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

#[allow(clippy::too_many_arguments)]
fn handle_create(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    project_path: &str,
    run_id: &str,
    method_id: Option<&str>,
    involvement: Option<InvolvementLevel>,
    delegation_worker_id: Option<String>,
    idea_id: Option<String>,
    idea_title: Option<String>,
    idea_description: Option<String>,
) -> MutationOutcome {
    if runs.contains_key(key) {
        return reject("run already exists");
    }

    let method_id = match method_id {
        Some(id) if !id.trim().is_empty() => id.trim().to_string(),
        _ => return reject("missing method_id for create"),
    };

    let method = match method_registry::find_method(&method_id) {
        Some(m) => m,
        None => return reject(&format!("unknown method: {method_id}")),
    };

    let involvement = involvement.unwrap_or(method.default_involvement);

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
        next_checkpoint_history_ordinal: 0,
        session_id: None,
        delegation_worker_id,
        status_message: None,
        idea_id,
        idea_title,
        idea_description,
        created_at: now.clone(),
        updated_at: now,
    };

    runs.insert(key.to_string(), run);
    ok("run created")
}

fn handle_start(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    status_message: Option<&str>,
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
        if let Some(msg) = normalized_optional_text(status_message) {
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
    run.status_message = normalized_optional_text(status_message);
    run.updated_at = now_rfc3339();
    ok("run started")
}

fn handle_heartbeat(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    status_message: Option<&str>,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    if let Some(msg) = normalized_optional_text(status_message) {
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

    if run.status != RunStatus::Active {
        return reject("run is not active");
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

/// Payload for `EmitCheckpoint`, destructured from the `RunMutationKind` variant.
struct EmitCheckpointArgs {
    checkpoint_kind: Option<CheckpointKind>,
    checkpoint_title: Option<String>,
    checkpoint_summary: Option<String>,
    checkpoint_brief_path: Option<String>,
    checkpoint_manifest_path: Option<String>,
    checkpoint_media_artifacts: Vec<MediaArtifact>,
    checkpoint_mermaid_sources: Vec<MermaidSource>,
    checkpoint_decision_relay: Option<CheckpointDecisionRelay>,
    capture_url: Option<String>,
    checkpoint_id: Option<String>,
}

fn handle_emit_checkpoint(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    args: EmitCheckpointArgs,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    let checkpoint_kind = match args.checkpoint_kind {
        Some(k) => k,
        None => return reject("missing checkpoint_kind"),
    };

    let title = args
        .checkpoint_title
        .as_deref()
        .unwrap_or("Checkpoint")
        .to_string();

    let checkpoint_id = args
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
            && active_checkpoint.manifest_path == args.checkpoint_manifest_path;

        if same_checkpoint {
            return ok("checkpoint already active");
        }

        return reject("checkpoint already active");
    }

    let now = now_rfc3339();
    let checkpoint_id = checkpoint_id
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{}:{}:ckpt-{}", run.id, phase_id, now.replace(':', "-")));

    let capture_url = normalized_optional_text(args.capture_url.as_deref());
    let capture_status = if capture_url.is_some() {
        CaptureStatus::Pending
    } else {
        CaptureStatus::NotRequested
    };
    let history_ordinal = next_checkpoint_history_ordinal(run);
    run.next_checkpoint_history_ordinal = history_ordinal.saturating_add(1);

    run.active_checkpoint = Some(ActiveCheckpoint {
        id: checkpoint_id,
        history_ordinal: Some(history_ordinal),
        phase_id,
        kind: checkpoint_kind,
        status: CheckpointStatus::Active,
        title,
        summary: args.checkpoint_summary,
        brief_path: args.checkpoint_brief_path,
        manifest_path: args.checkpoint_manifest_path,
        media_artifacts: args.checkpoint_media_artifacts,
        mermaid_sources: args.checkpoint_mermaid_sources,
        capture_status,
        capture_url,
        capture_claim: None,
        decision_relay: args.checkpoint_decision_relay,
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
    checkpoint_id: Option<&str>,
    capture_request_id: Option<&str>,
    client_id: Option<&str>,
    observed_capture_url: Option<&str>,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status != RunStatus::Paused {
        return reject("run is not paused");
    }

    let checkpoint_id = match require_checkpoint_id(checkpoint_id) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let capture_request_id = match require_capture_request_id(capture_request_id) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let client_id = match require_client_id(client_id) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };

    let observed_capture_url = normalized_optional_text(observed_capture_url);
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
    checkpoint_id: Option<&str>,
    decision_action: Option<&str>,
    decision_note: Option<String>,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    let checkpoint_id = match require_checkpoint_id(checkpoint_id) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };

    let checkpoint = match active_checkpoint_for_command(run, checkpoint_id) {
        Ok(checkpoint) => checkpoint,
        Err(outcome) => return outcome,
    };

    let action = match normalize_decision_action(decision_action) {
        Ok(action) => action,
        Err(outcome) => return outcome,
    };

    let now = now_rfc3339();
    checkpoint.decision = Some(CheckpointDecision {
        action: action.clone(),
        note: decision_note,
    });
    checkpoint.status = CheckpointStatus::Decided;
    checkpoint.decided_at = Some(now.clone());

    // Archive checkpoint and advance the run according to the decision.
    let decided_checkpoint = run.active_checkpoint.take();
    if let Some(checkpoint) = decided_checkpoint {
        archive_decided_checkpoint(run, checkpoint);
    }

    run.status = if action == "request_changes" {
        RunStatus::Paused
    } else {
        RunStatus::Active
    };
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

fn archive_decided_checkpoint(run: &mut RunState, checkpoint: ActiveCheckpoint) {
    run.past_checkpoints.push(checkpoint);
    let overflow = run
        .past_checkpoints
        .len()
        .saturating_sub(PAST_CHECKPOINT_RETENTION);
    if overflow > 0 {
        run.past_checkpoints.drain(0..overflow);
    }
}

fn next_checkpoint_history_ordinal(run: &RunState) -> u64 {
    let next_after_existing_ordinals = run
        .past_checkpoints
        .iter()
        .chain(run.active_checkpoint.iter())
        .filter_map(|checkpoint| checkpoint.history_ordinal)
        .max()
        .map_or(0, |ordinal| ordinal.saturating_add(1));
    let next_after_legacy_records =
        run.past_checkpoints.len() as u64 + u64::from(run.active_checkpoint.is_some());

    run.next_checkpoint_history_ordinal
        .max(next_after_existing_ordinals)
        .max(next_after_legacy_records)
}

fn handle_capture_complete(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    checkpoint_id: Option<&str>,
    capture_request_id: Option<&str>,
    completed_media_artifacts: Vec<MediaArtifact>,
) -> MutationOutcome {
    if completed_media_artifacts.is_empty() {
        return reject("completed_media_artifacts must not be empty");
    }
    with_validated_capture_mutation(runs, key, checkpoint_id, capture_request_id, |checkpoint| {
        checkpoint.media_artifacts.extend(completed_media_artifacts);
        checkpoint.capture_status = CaptureStatus::Completed;
        ok("capture completed")
    })
}

fn handle_capture_failed(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    checkpoint_id: Option<&str>,
    capture_request_id: Option<&str>,
    capture_failure_reason: Option<&str>,
) -> MutationOutcome {
    let capture_failure_reason = match normalized_optional_text(capture_failure_reason) {
        Some(value) => value,
        None => return reject("missing capture_failure_reason"),
    };
    with_validated_capture_mutation(runs, key, checkpoint_id, capture_request_id, |checkpoint| {
        checkpoint.capture_status = CaptureStatus::Failed {
            reason: capture_failure_reason,
        };
        ok("capture failed")
    })
}

fn handle_attach_session(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    session_id: Option<String>,
    delegation_worker_id: Option<String>,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status.is_terminal() {
        return reject("run is in terminal state");
    }

    run.session_id = session_id;

    // Also link delegation worker if provided
    if delegation_worker_id.is_some() {
        run.delegation_worker_id = delegation_worker_id;
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
    status_message: Option<&str>,
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
    if let Some(msg) = normalized_optional_text(status_message) {
        run.status_message = Some(msg);
    }
    run.updated_at = now_rfc3339();
    ok(&format!("run {label}"))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn require_checkpoint_id(checkpoint_id: Option<&str>) -> Result<&str, MutationOutcome> {
    checkpoint_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing checkpoint_id"))
}

fn require_capture_request_id(capture_request_id: Option<&str>) -> Result<&str, MutationOutcome> {
    capture_request_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing capture_request_id"))
}

fn require_client_id(client_id: Option<&str>) -> Result<&str, MutationOutcome> {
    client_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| reject("missing client_id"))
}

fn with_validated_capture_mutation(
    runs: &mut BTreeMap<String, RunState>,
    key: &str,
    checkpoint_id: Option<&str>,
    capture_request_id: Option<&str>,
    apply: impl FnOnce(&mut ActiveCheckpoint) -> MutationOutcome,
) -> MutationOutcome {
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    if run.status != RunStatus::Paused {
        return reject("run is not paused");
    }

    let checkpoint_id = match require_checkpoint_id(checkpoint_id) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let capture_request_id = match require_capture_request_id(capture_request_id) {
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
