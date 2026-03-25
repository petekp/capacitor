//! Run Kernel reducer.
//!
//! Handles `MutateRunCommand` mutations against run state.
//! Coexists with the delegation reducer during the strangler-pattern migration.

use std::collections::BTreeMap;

use crate::domain::{
    method_registry, now_rfc3339, ActiveCheckpoint, CaptureClaim, CaptureStatus,
    CheckpointDecision, CheckpointStatus, MutateRunCommand, MutationOutcome, PhaseInstance,
    PhaseStatus, RunMutationKind, RunState, RunStatus,
};

/// Apply a run mutation to the runs map. Returns a `MutationOutcome`.
pub fn apply_run_mutation(
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
        session_id: None,
        delegation_worker_id: command.delegation_worker_id.clone(),
        created_at: now.clone(),
        updated_at: now,
    };

    runs.insert(key.to_string(), run);
    ok("run created")
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

    let action = match &command.decision_action {
        Some(a) if !a.trim().is_empty() => a.trim().to_string(),
        _ => return reject("missing decision_action"),
    };

    // Validate that the action is one of the recognized values. This prevents
    // the runtime from resuming the run with an action that the bridge adapter
    // or other consumers don't understand, which would desynchronize state.
    match action.as_str() {
        "approve" | "approved" | "request_changes" | "rejected" => {}
        _ => return reject(&format!("unrecognized decision_action: {action:?}")),
    }

    let now = now_rfc3339();
    checkpoint.decision = Some(CheckpointDecision {
        action: action.clone(),
        note: command.decision_note.clone(),
    });
    checkpoint.status = CheckpointStatus::Decided;
    checkpoint.decided_at = Some(now.clone());

    // Clear checkpoint and resume run
    let decided_checkpoint = run.active_checkpoint.take();
    // Keep the decided checkpoint data in the phase history (future enhancement)
    let _ = decided_checkpoint;

    run.status = RunStatus::Active;
    run.updated_at = now;
    ok(&format!("decision recorded: {action}"))
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{CheckpointKind, InvolvementLevel};

    fn empty_runs() -> BTreeMap<String, RunState> {
        BTreeMap::new()
    }

    fn create_command(run_id: &str, method_id: &str) -> MutateRunCommand {
        MutateRunCommand {
            kind: RunMutationKind::Create,
            project_path: "/test/project".to_string(),
            run_id: run_id.to_string(),
            method_id: Some(method_id.to_string()),
            involvement: None,
            checkpoint_kind: None,
            checkpoint_title: None,
            checkpoint_summary: None,
            checkpoint_brief_path: None,
            checkpoint_manifest_path: None,
            checkpoint_media_artifacts: vec![],
            checkpoint_mermaid_sources: vec![],
            capture_url: None,
            checkpoint_id: None,
            capture_request_id: None,
            client_id: None,
            observed_capture_url: None,
            capture_failure_reason: None,
            decision_action: None,
            decision_note: None,
            session_id: None,
            delegation_worker_id: None,
            completed_media_artifacts: vec![],
        }
    }

    fn mutate(
        runs: &mut BTreeMap<String, RunState>,
        mut cmd: MutateRunCommand,
        kind: RunMutationKind,
    ) -> MutationOutcome {
        cmd.kind = kind;
        apply_run_mutation(runs, cmd)
    }

    fn base_cmd(run_id: &str) -> MutateRunCommand {
        MutateRunCommand {
            kind: RunMutationKind::Create, // will be overridden
            project_path: "/test/project".to_string(),
            run_id: run_id.to_string(),
            method_id: None,
            involvement: None,
            checkpoint_kind: None,
            checkpoint_title: None,
            checkpoint_summary: None,
            checkpoint_brief_path: None,
            checkpoint_manifest_path: None,
            checkpoint_media_artifacts: vec![],
            checkpoint_mermaid_sources: vec![],
            capture_url: None,
            checkpoint_id: None,
            capture_request_id: None,
            client_id: None,
            observed_capture_url: None,
            capture_failure_reason: None,
            decision_action: None,
            decision_note: None,
            session_id: None,
            delegation_worker_id: None,
            completed_media_artifacts: vec![],
        }
    }

    fn attach_session(runs: &mut BTreeMap<String, RunState>, run_id: &str) {
        let mut cmd = base_cmd(run_id);
        cmd.session_id = Some("s1".to_string());
        let result = mutate(runs, cmd, RunMutationKind::AttachSession);
        assert!(result.ok, "{}", result.message);
    }

    fn emit_pending_checkpoint(
        runs: &mut BTreeMap<String, RunState>,
        run_id: &str,
        capture_url: &str,
    ) -> String {
        let mut cmd = base_cmd(run_id);
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_url = Some(capture_url.to_string());
        let result = mutate(runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        runs.values()
            .next()
            .expect("run exists")
            .active_checkpoint
            .as_ref()
            .expect("checkpoint exists")
            .id
            .clone()
    }

    fn claim_capture(
        runs: &mut BTreeMap<String, RunState>,
        run_id: &str,
        checkpoint_id: &str,
        capture_request_id: &str,
    ) -> MutationOutcome {
        let mut cmd = base_cmd(run_id);
        cmd.checkpoint_id = Some(checkpoint_id.to_string());
        cmd.capture_request_id = Some(capture_request_id.to_string());
        cmd.client_id = Some("client-1".to_string());
        cmd.observed_capture_url = Some(" http://localhost:4173 ".to_string());
        mutate(runs, cmd, RunMutationKind::CaptureClaim)
    }

    fn active_checkpoint_id(runs: &BTreeMap<String, RunState>, run_id: &str) -> String {
        runs.values()
            .find(|run| run.id == run_id)
            .expect("run exists")
            .active_checkpoint
            .as_ref()
            .expect("checkpoint exists")
            .id
            .clone()
    }

    #[test]
    fn create_run_with_valid_method() {
        let mut runs = empty_runs();
        let result = apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        assert!(result.ok, "create should succeed: {}", result.message);
        assert_eq!(runs.len(), 1);

        let run = runs.values().next().unwrap();
        assert_eq!(run.id, "run-001");
        assert_eq!(run.method_id, "execution_only");
        assert_eq!(run.status, RunStatus::Created);
        assert_eq!(run.phases.len(), 1);
        assert_eq!(run.phases[0].name, "Execute");
        assert_eq!(run.current_phase_index, 0);
    }

    #[test]
    fn create_run_with_invalid_method() {
        let mut runs = empty_runs();
        let result = apply_run_mutation(&mut runs, create_command("run-001", "nonexistent"));
        assert!(!result.ok);
        assert!(result.message.contains("unknown method"));
        assert!(runs.is_empty());
    }

    #[test]
    fn create_duplicate_run_rejected() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        let result = apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        assert!(!result.ok);
        assert!(result.message.contains("already exists"));
    }

    #[test]
    fn create_multi_phase_method() {
        let mut runs = empty_runs();
        let result = apply_run_mutation(&mut runs, create_command("run-002", "shape_and_execute"));
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.phases.len(), 2);
        assert_eq!(run.phases[0].name, "Shape");
        assert_eq!(run.phases[1].name, "Execute");
    }

    #[test]
    fn attach_session_activates_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("session-abc".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::AttachSession);
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Active);
        assert_eq!(run.session_id.as_deref(), Some("session-abc"));
        assert_eq!(run.phases[0].status, PhaseStatus::Active);
    }

    #[test]
    fn emit_checkpoint_pauses_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("First milestone".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Paused);
        assert!(run.active_checkpoint.is_some());
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.title, "First milestone");
        assert_eq!(ckpt.status, CheckpointStatus::Active);
    }

    #[test]
    fn submit_decision_resumes_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("M1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
        cmd.decision_action = Some("approve".to_string());
        cmd.decision_note = Some("Looks good".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::SubmitDecision);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Active);
        assert!(run.active_checkpoint.is_none());
    }

    #[test]
    fn advance_phase_works() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "shape_and_execute"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let result = mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::AdvancePhase,
        );
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        assert_eq!(run.current_phase_index, 1);
        assert_eq!(run.phases[0].status, PhaseStatus::Completed);
        assert_eq!(run.phases[1].status, PhaseStatus::Active);
    }

    #[test]
    fn advance_past_last_phase_completes_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let result = mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::AdvancePhase,
        );
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Completed);
    }

    #[test]
    fn terminal_run_rejects_mutations() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        // Complete it
        mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::AdvancePhase,
        );

        // Try to emit checkpoint
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(!result.ok);
        assert!(result.message.contains("terminal"));
    }

    #[test]
    fn cancel_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let result = mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Cancel);
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Cancelled);
    }

    #[test]
    fn full_lifecycle_multi_phase() {
        let mut runs = empty_runs();

        // Create with shape_and_execute
        apply_run_mutation(&mut runs, create_command("run-001", "shape_and_execute"));

        // Attach session → activates run, starts phase 1 (Shape)
        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        // Emit proposal checkpoint in Shape phase
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
        cmd.checkpoint_title = Some("Approach proposal".to_string());
        mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);

        // Submit decision
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
        cmd.decision_action = Some("approve".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::SubmitDecision);
        assert!(result.ok, "{}", result.message);

        // Advance to Execute phase
        mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::AdvancePhase,
        );

        let run = runs.values().next().unwrap();
        assert_eq!(run.current_phase_index, 1);
        assert_eq!(run.phases[1].name, "Execute");
        assert_eq!(run.status, RunStatus::Active);

        // Emit milestone checkpoint in Execute phase
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("First milestone".to_string());
        mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);

        // Approve milestone
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
        cmd.decision_action = Some("approve".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::SubmitDecision);
        assert!(result.ok, "{}", result.message);

        // Advance past last phase → run completes
        let result = mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::AdvancePhase,
        );
        assert!(result.ok);

        let run = runs.values().next().unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert!(run
            .phases
            .iter()
            .all(|p| p.status == PhaseStatus::Completed));
    }

    #[test]
    fn involvement_level_override() {
        let mut runs = empty_runs();
        let mut cmd = create_command("run-001", "execution_only");
        cmd.involvement = Some(InvolvementLevel::Autonomous);
        apply_run_mutation(&mut runs, cmd);

        let run = runs.values().next().unwrap();
        assert_eq!(run.involvement, InvolvementLevel::Autonomous);
    }

    #[test]
    fn delegation_worker_id_bridge() {
        let mut runs = empty_runs();
        let mut cmd = create_command("run-001", "execution_only");
        cmd.delegation_worker_id = Some("worker-abc".to_string());
        apply_run_mutation(&mut runs, cmd);

        let run = runs.values().next().unwrap();
        assert_eq!(run.delegation_worker_id.as_deref(), Some("worker-abc"));
    }

    #[test]
    fn emit_checkpoint_with_media_artifacts() {
        use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType, MermaidSource};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("With media".to_string());
        cmd.checkpoint_media_artifacts = vec![MediaArtifact {
            artifact_type: MediaArtifactType::Screenshot,
            path: "terminal-001.png".to_string(),
            label: "Terminal".to_string(),
            width: Some(2560),
            height: Some(1440),
            duration_secs: None,
        }];
        cmd.checkpoint_mermaid_sources = vec![MermaidSource {
            label: "Architecture".to_string(),
            source: "graph LR; A-->B".to_string(),
        }];
        cmd.capture_url = Some("http://localhost:3000".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.media_artifacts.len(), 1);
        assert_eq!(ckpt.media_artifacts[0].label, "Terminal");
        assert_eq!(ckpt.mermaid_sources.len(), 1);
        assert_eq!(ckpt.mermaid_sources[0].label, "Architecture");
        assert_eq!(ckpt.capture_status, CaptureStatus::Pending);
        assert_eq!(ckpt.capture_claim, None);
    }

    #[test]
    fn capture_complete_updates_checkpoint() {
        use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");

        let claim = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(claim.ok, "{}", claim.message);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(checkpoint_id);
        cmd.capture_request_id = Some("request-1".to_string());
        cmd.completed_media_artifacts = vec![
            MediaArtifact {
                artifact_type: MediaArtifactType::Screenshot,
                path: "terminal-001.png".to_string(),
                label: "Terminal capture".to_string(),
                width: Some(2560),
                height: Some(1440),
                duration_secs: None,
            },
            MediaArtifact {
                artifact_type: MediaArtifactType::Screenshot,
                path: "browser-001.png".to_string(),
                label: "Browser capture".to_string(),
                width: Some(1920),
                height: Some(1080),
                duration_secs: None,
            },
        ];
        let result = mutate(&mut runs, cmd, RunMutationKind::CaptureComplete);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.media_artifacts.len(), 2);
        assert_eq!(ckpt.capture_status, CaptureStatus::Completed);
        let claim = ckpt.capture_claim.as_ref().expect("capture claim");
        assert_eq!(claim.capture_request_id, "request-1");
        assert_eq!(claim.client_id, "client-1");
        assert_eq!(
            claim.observed_capture_url.as_deref(),
            Some("http://localhost:4173")
        );
    }

    #[test]
    fn capture_complete_rejects_without_claim() {
        use crate::domain::{MediaArtifact, MediaArtifactType};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(checkpoint_id);
        cmd.capture_request_id = Some("request-1".to_string());
        cmd.completed_media_artifacts = vec![MediaArtifact {
            artifact_type: MediaArtifactType::Screenshot,
            path: "/tmp/capture.png".to_string(),
            label: "screenshot".to_string(),
            width: Some(1280),
            height: Some(800),
            duration_secs: None,
        }];
        let result = mutate(&mut runs, cmd, RunMutationKind::CaptureComplete);
        assert!(!result.ok);
        assert!(result.message.contains("not in progress"));
    }

    #[test]
    fn emit_checkpoint_with_capture_url_auto_sets_pending() {
        use crate::domain::CaptureStatus;

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        attach_session(&mut runs, "run-001");

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("URL capture".to_string());
        cmd.capture_url = Some("http://localhost:3000".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_status, CaptureStatus::Pending);
        assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:3000"));
        assert_eq!(ckpt.capture_claim, None);
    }

    #[test]
    fn emit_checkpoint_with_blank_capture_url_stays_not_requested() {
        use crate::domain::CaptureStatus;

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_url = Some("   ".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_status, CaptureStatus::NotRequested);
        assert_eq!(ckpt.capture_url, None);
        assert_eq!(ckpt.capture_claim, None);
    }

    #[test]
    fn capture_claim_transitions_pending_to_in_progress() {
        use crate::domain::CaptureStatus;

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id =
            emit_pending_checkpoint(&mut runs, "run-001", " http://localhost:3000 ");

        let result = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_status, CaptureStatus::InProgress);
        assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:3000"));
        let claim = ckpt.capture_claim.as_ref().expect("capture claim");
        assert_eq!(claim.capture_request_id, "request-1");
        assert_eq!(claim.client_id, "client-1");
        assert_eq!(
            claim.observed_capture_url.as_deref(),
            Some("http://localhost:4173")
        );
    }

    #[test]
    fn capture_claim_rejects_non_pending_checkpoint() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");

        let first = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(first.ok, "{}", first.message);

        let second = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-2");
        assert!(!second.ok);
        assert!(second.message.contains("not pending"));
    }

    #[test]
    fn capture_claim_rejects_mismatched_checkpoint_id() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");

        let result = claim_capture(&mut runs, "run-001", "wrong-checkpoint", "request-1");
        assert!(!result.ok);
        assert!(result.message.contains("does not match active checkpoint"));
    }

    #[test]
    fn capture_claim_rejects_terminal_or_non_paused_run() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
        let key = run_key("/test/project", "run-001");

        runs.get_mut(&key).expect("run").status = RunStatus::Active;
        let active_result = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(!active_result.ok);
        assert!(active_result.message.contains("not paused"));

        runs.get_mut(&key).expect("run").status = RunStatus::Completed;
        let terminal_result = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(!terminal_result.ok);
        assert!(terminal_result.message.contains("not paused"));
    }

    #[test]
    fn capture_complete_rejects_mismatched_capture_request_id() {
        use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
        let claim = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(claim.ok, "{}", claim.message);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(checkpoint_id);
        cmd.capture_request_id = Some("request-2".to_string());
        cmd.completed_media_artifacts = vec![MediaArtifact {
            artifact_type: MediaArtifactType::Screenshot,
            path: "/tmp/capture.png".to_string(),
            label: "screenshot".to_string(),
            width: Some(1280),
            height: Some(800),
            duration_secs: None,
        }];
        let result = mutate(&mut runs, cmd, RunMutationKind::CaptureComplete);
        assert!(!result.ok);
        assert!(result.message.contains("does not match active claim"));

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_status, CaptureStatus::InProgress);
    }

    #[test]
    fn capture_failed_sets_reason_on_checkpoint() {
        use crate::domain::CaptureStatus;

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
        let claim = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
        assert!(claim.ok, "{}", claim.message);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_id = Some(checkpoint_id);
        cmd.capture_request_id = Some("request-1".to_string());
        cmd.capture_failure_reason = Some(" browser crashed ".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::CaptureFailed);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        match &ckpt.capture_status {
            CaptureStatus::Failed { reason } => assert_eq!(reason, "browser crashed"),
            other => panic!("expected failed capture status, got {other:?}"),
        }
        let claim = ckpt.capture_claim.as_ref().expect("capture claim");
        assert_eq!(claim.capture_request_id, "request-1");
    }

    #[test]
    fn stale_capture_completion_is_rejected_after_checkpoint_turnover() {
        use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
        attach_session(&mut runs, "run-001");
        let checkpoint_a_id =
            emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
        let claim = claim_capture(&mut runs, "run-001", &checkpoint_a_id, "request-a");
        assert!(claim.ok, "{}", claim.message);

        let mut decision = base_cmd("run-001");
        decision.checkpoint_id = Some(checkpoint_a_id.clone());
        decision.decision_action = Some("approve".to_string());
        let decision_result = mutate(&mut runs, decision, RunMutationKind::SubmitDecision);
        assert!(decision_result.ok, "{}", decision_result.message);

        let checkpoint_b_id =
            emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:4000");

        let mut stale_complete = base_cmd("run-001");
        stale_complete.checkpoint_id = Some(checkpoint_a_id);
        stale_complete.capture_request_id = Some("request-a".to_string());
        stale_complete.completed_media_artifacts = vec![MediaArtifact {
            artifact_type: MediaArtifactType::Screenshot,
            path: "/tmp/capture.png".to_string(),
            label: "screenshot".to_string(),
            width: Some(1280),
            height: Some(800),
            duration_secs: None,
        }];
        let result = mutate(&mut runs, stale_complete, RunMutationKind::CaptureComplete);
        assert!(!result.ok);
        assert!(result.message.contains("does not match active checkpoint"));

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.id, checkpoint_b_id);
        assert_eq!(ckpt.capture_status, CaptureStatus::Pending);
    }

    #[test]
    fn emit_checkpoint_capture_url_persists_to_active() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        attach_session(&mut runs, "run-001");

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_url = Some(" http://localhost:5173 ".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:5173"));
    }
}
