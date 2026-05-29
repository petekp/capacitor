use super::*;

#[test]
fn create_run_with_valid_method() {
    let mut runs = empty_runs();
    let result = apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    let result = apply_run_mutation(
        &mut runs,
        create_command("run-001", "nonexistent").into_command(Kind::Create),
    );
    assert!(!result.ok);
    assert!(result.message.contains("unknown method"));
    assert!(runs.is_empty());
}

#[test]
fn create_duplicate_run_rejected() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    let result = apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    assert!(!result.ok);
    assert!(result.message.contains("already exists"));
}

#[test]
fn create_multi_phase_method() {
    let mut runs = empty_runs();
    let result = apply_run_mutation(
        &mut runs,
        create_command("run-002", "shape_and_execute").into_command(Kind::Create),
    );
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.phases.len(), 2);
    assert_eq!(run.phases[0].name, "Shape");
    assert_eq!(run.phases[1].name, "Execute");
}

#[test]
fn attach_session_activates_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("session-abc".to_string());
    let result = mutate(&mut runs, cmd, Kind::AttachSession);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.session_id.as_deref(), Some("session-abc"));
    assert_eq!(run.phases[0].status, PhaseStatus::Active);
}

#[test]
fn emit_checkpoint_pauses_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("First milestone".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Paused);
    assert!(run.active_checkpoint.is_some());
    let ckpt = run.active_checkpoint.as_ref().unwrap();
    assert_eq!(ckpt.title, "First milestone");
    assert_eq!(ckpt.status, CheckpointStatus::Active);
}

#[test]
fn emit_checkpoint_assigns_durable_history_ordinals() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-history-ordinal", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-history-ordinal");

    let mut cmd = base_cmd("run-history-ordinal");
    cmd.checkpoint_id = Some("gate-repeat".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("First repeated gate".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    {
        let run = runs.values().next().unwrap();
        let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
        assert_eq!(checkpoint.history_ordinal, Some(0));
        assert_eq!(run.next_checkpoint_history_ordinal, 1);
    }

    let mut cmd = base_cmd("run-history-ordinal");
    cmd.checkpoint_id = Some("gate-repeat".to_string());
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    {
        let run = runs.values().next().unwrap();
        assert_eq!(run.past_checkpoints.len(), 1);
        assert_eq!(run.past_checkpoints[0].history_ordinal, Some(0));
        assert_eq!(run.next_checkpoint_history_ordinal, 1);
    }

    let mut cmd = base_cmd("run-history-ordinal");
    cmd.checkpoint_id = Some("gate-repeat".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Second repeated gate".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(checkpoint.history_ordinal, Some(1));
    assert_eq!(run.next_checkpoint_history_ordinal, 2);
}

#[test]
fn emit_checkpoint_continues_after_legacy_history_without_ordinals() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-legacy-history-ordinal", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-legacy-history-ordinal");

    let mut cmd = base_cmd("run-legacy-history-ordinal");
    cmd.checkpoint_id = Some("legacy-gate".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    let mut cmd = base_cmd("run-legacy-history-ordinal");
    cmd.checkpoint_id = Some("legacy-gate".to_string());
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    {
        let run = runs.values_mut().next().unwrap();
        run.past_checkpoints[0].history_ordinal = None;
        run.next_checkpoint_history_ordinal = 0;
    }

    let mut cmd = base_cmd("run-legacy-history-ordinal");
    cmd.checkpoint_id = Some("new-gate".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(checkpoint.history_ordinal, Some(1));
    assert_eq!(run.next_checkpoint_history_ordinal, 2);
}

#[test]
fn submit_decision_resumes_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("M1".to_string());
    mutate(&mut runs, cmd, Kind::EmitCheckpoint);

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
    cmd.decision_action = Some("approve".to_string());
    cmd.decision_note = Some("Looks good".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    let decided = &run.past_checkpoints[0];
    assert_eq!(decided.status, CheckpointStatus::Decided);
    assert_eq!(
        decided
            .decision
            .as_ref()
            .map(|decision| decision.action.as_str()),
        Some("approve")
    );
    assert!(decided.decided_at.is_some());
}

#[test]
fn submit_request_changes_archives_checkpoint_and_keeps_run_paused() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-request-changes", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-request-changes");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let mut cmd = base_cmd("run-request-changes");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("M1".to_string());
    mutate(&mut runs, cmd, Kind::EmitCheckpoint);

    let mut cmd = base_cmd("run-request-changes");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-request-changes"));
    cmd.decision_action = Some("request_changes".to_string());
    cmd.decision_note = Some("Fix the failing checks".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Paused);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    let decided = &run.past_checkpoints[0];
    assert_eq!(
        decided
            .decision
            .as_ref()
            .map(|decision| decision.action.as_str()),
        Some("request_changes")
    );
    assert_eq!(
        decided
            .decision
            .as_ref()
            .and_then(|decision| decision.note.as_deref()),
        Some("Fix the failing checks")
    );
}

#[test]
fn submit_decision_normalizes_bridge_aliases_to_runtime_actions() {
    for (input, canonical) in [
        ("approved", "approve"),
        ("rejected", "request_changes"),
        (" APPROVED ", "approve"),
        (" ReJeCtEd ", "request_changes"),
    ] {
        let mut runs = empty_runs();
        apply_run_mutation(
            &mut runs,
            create_command(input, "execution_only").into_command(Kind::Create),
        );

        let mut cmd = base_cmd(input);
        cmd.session_id = Some("s1".to_string());
        mutate(&mut runs, cmd, Kind::AttachSession);

        let mut cmd = base_cmd(input);
        cmd.checkpoint_id = Some("checkpoint-1".to_string());
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some("M1".to_string());
        mutate(&mut runs, cmd, Kind::EmitCheckpoint);

        let mut cmd = base_cmd(input);
        cmd.checkpoint_id = Some("checkpoint-1".to_string());
        cmd.decision_action = Some(input.to_string());
        let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.message, format!("decision recorded: {canonical}"));
    }
}

#[test]
fn submit_decision_retains_only_recent_past_checkpoints() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-history-retention", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-history-retention");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    for index in 0..(PAST_CHECKPOINT_RETENTION + 5) {
        let checkpoint_id = format!("checkpoint-{index:03}");

        let mut emit = base_cmd("run-history-retention");
        emit.checkpoint_id = Some(checkpoint_id.clone());
        emit.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        emit.checkpoint_title = Some(format!("M{index}"));
        let emit_result = mutate(&mut runs, emit, Kind::EmitCheckpoint);
        assert!(emit_result.ok, "{}", emit_result.message);

        let mut decide = base_cmd("run-history-retention");
        decide.checkpoint_id = Some(checkpoint_id);
        decide.decision_action = Some("approve".to_string());
        let decide_result = mutate(&mut runs, decide, Kind::SubmitDecision);
        assert!(decide_result.ok, "{}", decide_result.message);
    }

    let run = runs.values().next().unwrap();
    assert_eq!(run.past_checkpoints.len(), PAST_CHECKPOINT_RETENTION);
    assert_eq!(
        run.past_checkpoints
            .first()
            .map(|checkpoint| checkpoint.id.as_str()),
        Some("checkpoint-005")
    );
    assert_eq!(
        run.past_checkpoints
            .last()
            .map(|checkpoint| checkpoint.id.as_str()),
        Some("checkpoint-054")
    );
}

#[test]
fn advance_phase_works() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "shape_and_execute").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let result = mutate(&mut runs, base_cmd("run-001"), Kind::AdvancePhase);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.current_phase_index, 1);
    assert_eq!(run.phases[0].status, PhaseStatus::Completed);
    assert_eq!(run.phases[1].status, PhaseStatus::Active);
}

#[test]
fn advance_phase_rejects_paused_run_without_active_checkpoint() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-paused-advance", "shape_and_execute").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-paused-advance");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let pause_result = mutate(&mut runs, base_cmd("run-paused-advance"), Kind::Pause);
    assert!(pause_result.ok, "{}", pause_result.message);

    let advance_result = mutate(
        &mut runs,
        base_cmd("run-paused-advance"),
        Kind::AdvancePhase,
    );
    assert!(!advance_result.ok);
    assert!(advance_result.message.contains("run is not active"));

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(run.current_phase_index, 0);
}

#[test]
fn request_changes_pause_requires_resume_before_phase_advance() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-request-changes-resume", "shape_and_execute")
            .into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-request-changes-resume");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let mut cmd = base_cmd("run-request-changes-resume");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Proposal".to_string());
    mutate(&mut runs, cmd, Kind::EmitCheckpoint);

    let mut cmd = base_cmd("run-request-changes-resume");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-request-changes-resume"));
    cmd.decision_action = Some("request_changes".to_string());
    let decision_result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(decision_result.ok, "{}", decision_result.message);

    let mut pause = base_cmd("run-request-changes-resume");
    pause.status_message = Some("Run blocked: gate rejected".to_string());
    let pause_result = mutate(&mut runs, pause, Kind::Pause);
    assert!(pause_result.ok, "{}", pause_result.message);

    let advance_while_paused = mutate(
        &mut runs,
        base_cmd("run-request-changes-resume"),
        Kind::AdvancePhase,
    );
    assert!(!advance_while_paused.ok);
    assert!(advance_while_paused.message.contains("run is not active"));

    let mut resume = base_cmd("run-request-changes-resume");
    resume.status_message = Some("Run resumed".to_string());
    let resume_result = mutate(&mut runs, resume, Kind::Resume);
    assert!(resume_result.ok, "{}", resume_result.message);

    let advance_after_resume = mutate(
        &mut runs,
        base_cmd("run-request-changes-resume"),
        Kind::AdvancePhase,
    );
    assert!(advance_after_resume.ok, "{}", advance_after_resume.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.current_phase_index, 1);
    assert_eq!(run.status_message.as_deref(), Some("Run resumed"));
}

#[test]
fn advance_past_last_phase_completes_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    let result = mutate(&mut runs, base_cmd("run-001"), Kind::AdvancePhase);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Completed);
}

#[test]
fn terminal_run_rejects_mutations() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    // Complete it
    mutate(&mut runs, base_cmd("run-001"), Kind::AdvancePhase);

    // Try to emit checkpoint
    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(!result.ok);
    assert!(result.message.contains("terminal"));
}

#[test]
fn cancel_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    let result = mutate(&mut runs, base_cmd("run-001"), Kind::Cancel);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Cancelled);
}

#[test]
fn full_lifecycle_multi_phase() {
    let mut runs = empty_runs();

    // Create with shape_and_execute
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "shape_and_execute").into_command(Kind::Create),
    );

    // Attach session → activates run, starts phase 1 (Shape)
    let mut cmd = base_cmd("run-001");
    cmd.session_id = Some("s1".to_string());
    mutate(&mut runs, cmd, Kind::AttachSession);

    // Emit proposal checkpoint in Shape phase
    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Approach proposal".to_string());
    mutate(&mut runs, cmd, Kind::EmitCheckpoint);

    // Submit decision
    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    // Advance to Execute phase
    mutate(&mut runs, base_cmd("run-001"), Kind::AdvancePhase);

    let run = runs.values().next().unwrap();
    assert_eq!(run.current_phase_index, 1);
    assert_eq!(run.phases[1].name, "Execute");
    assert_eq!(run.status, RunStatus::Active);

    // Emit milestone checkpoint in Execute phase
    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("First milestone".to_string());
    mutate(&mut runs, cmd, Kind::EmitCheckpoint);

    // Approve milestone
    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runs, "run-001"));
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&mut runs, cmd, Kind::SubmitDecision);
    assert!(result.ok, "{}", result.message);

    // Advance past last phase → run completes
    let result = mutate(&mut runs, base_cmd("run-001"), Kind::AdvancePhase);
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
    apply_run_mutation(&mut runs, cmd.into_command(Kind::Create));

    let run = runs.values().next().unwrap();
    assert_eq!(run.involvement, InvolvementLevel::Autonomous);
}

#[test]
fn delegation_worker_id_bridge() {
    let mut runs = empty_runs();
    let mut cmd = create_command("run-001", "execution_only");
    cmd.delegation_worker_id = Some("worker-abc".to_string());
    apply_run_mutation(&mut runs, cmd.into_command(Kind::Create));

    let run = runs.values().next().unwrap();
    assert_eq!(run.delegation_worker_id.as_deref(), Some("worker-abc"));
}
