//! Run Kernel reducer.
//!
//! Handles `MutateRunCommand` mutations against run state.
//! Coexists with the delegation reducer during the strangler-pattern migration.

use std::collections::BTreeMap;

use crate::domain::{
    method_registry, now_rfc3339, ActiveCheckpoint, CaptureStatus, CheckpointDecision,
    CheckpointStatus, MutateRunCommand, MutationOutcome, PhaseInstance, PhaseStatus,
    RunMutationKind, RunState, RunStatus,
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

    if run.active_checkpoint.is_some() {
        return reject("checkpoint already active");
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

    let phase_id = run
        .current_phase()
        .map(|p| p.id.clone())
        .unwrap_or_default();

    let now = now_rfc3339();
    let checkpoint_id = format!("{}:{}:ckpt-{}", run.id, phase_id, now.replace(':', "-"));

    // capture_url implies capture is requested, even if capture_requested is false
    let capture_status = if command.capture_requested || command.capture_url.is_some() {
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
        capture_url: command.capture_url.clone(),
        decision: None,
        created_at: now.clone(),
        decided_at: None,
    });

    run.status = RunStatus::Paused;
    run.updated_at = now;
    ok("checkpoint emitted, run paused")
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

    let checkpoint = match &mut run.active_checkpoint {
        Some(c) if c.status == CheckpointStatus::Active => c,
        Some(_) => return reject("checkpoint is not active"),
        None => return reject("no active checkpoint"),
    };

    let action = match &command.decision_action {
        Some(a) if !a.trim().is_empty() => a.trim().to_string(),
        _ => return reject("missing decision_action"),
    };

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
    let run = match runs.get_mut(key) {
        Some(r) => r,
        None => return reject("run not found"),
    };

    let checkpoint = match &mut run.active_checkpoint {
        Some(c) => c,
        None => return reject("no active checkpoint"),
    };

    if !matches!(checkpoint.capture_status, CaptureStatus::Pending) {
        return reject("capture is not pending");
    }

    // Append completed media artifacts to the checkpoint
    checkpoint
        .media_artifacts
        .extend(command.completed_media_artifacts.clone());
    checkpoint.capture_status = CaptureStatus::Completed;

    run.updated_at = now_rfc3339();
    ok("capture completed")
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
            capture_requested: false,
            capture_url: None,
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
            capture_requested: false,
            capture_url: None,
            decision_action: None,
            decision_note: None,
            session_id: None,
            delegation_worker_id: None,
            completed_media_artifacts: vec![],
        }
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
        cmd.decision_action = Some("approve".to_string());
        mutate(&mut runs, cmd, RunMutationKind::SubmitDecision);

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
        cmd.decision_action = Some("approve".to_string());
        mutate(&mut runs, cmd, RunMutationKind::SubmitDecision);

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
        cmd.capture_requested = true;
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.media_artifacts.len(), 1);
        assert_eq!(ckpt.media_artifacts[0].label, "Terminal");
        assert_eq!(ckpt.mermaid_sources.len(), 1);
        assert_eq!(ckpt.mermaid_sources[0].label, "Architecture");
        assert!(matches!(ckpt.capture_status, CaptureStatus::Pending));
    }

    #[test]
    fn capture_complete_updates_checkpoint() {
        use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType};

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        // Emit checkpoint with capture requested
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_requested = true;
        mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);

        // Complete capture with artifacts
        let mut cmd = base_cmd("run-001");
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
        assert!(matches!(ckpt.capture_status, CaptureStatus::Completed));
    }

    #[test]
    fn capture_complete_rejects_without_pending() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        // Emit checkpoint WITHOUT capture requested
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_requested = false;
        mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);

        // Try to complete capture — should be rejected
        let result = mutate(
            &mut runs,
            base_cmd("run-001"),
            RunMutationKind::CaptureComplete,
        );
        assert!(!result.ok);
        assert!(result.message.contains("not pending"));
    }

    #[test]
    fn emit_checkpoint_with_capture_url_auto_sets_pending() {
        use crate::domain::CaptureStatus;

        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        // Emit checkpoint with capture_url but capture_requested=false
        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("URL capture".to_string());
        cmd.capture_requested = false;
        cmd.capture_url = Some("http://localhost:3000".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        // capture_url should auto-set status to Pending
        assert!(matches!(ckpt.capture_status, CaptureStatus::Pending));
        assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:3000"));
    }

    #[test]
    fn emit_checkpoint_capture_url_persists_to_active() {
        let mut runs = empty_runs();
        apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

        let mut cmd = base_cmd("run-001");
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, RunMutationKind::AttachSession);

        let mut cmd = base_cmd("run-001");
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.capture_requested = true;
        cmd.capture_url = Some("http://localhost:5173".to_string());
        let result = mutate(&mut runs, cmd, RunMutationKind::EmitCheckpoint);
        assert!(result.ok, "{}", result.message);

        let run = runs.values().next().unwrap();
        let ckpt = run.active_checkpoint.as_ref().unwrap();
        assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:5173"));
    }
}
