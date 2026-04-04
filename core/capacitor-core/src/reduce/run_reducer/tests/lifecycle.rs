use super::*;

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
