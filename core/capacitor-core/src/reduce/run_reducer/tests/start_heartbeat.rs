use super::*;

fn start_run(runs: &mut BTreeMap<String, RunState>, run_id: &str) {
    let result = mutate(runs, base_cmd(run_id), RunMutationKind::Start);
    assert!(result.ok, "start failed: {}", result.message);
}

fn start_run_with_message(
    runs: &mut BTreeMap<String, RunState>,
    run_id: &str,
    msg: &str,
) -> MutationOutcome {
    let mut cmd = base_cmd(run_id);
    cmd.status_message = Some(msg.to_string());
    mutate(runs, cmd, RunMutationKind::Start)
}

#[test]
fn start_transitions_created_to_active() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

    let result = start_run_with_message(&mut runs, "run-001", "Initializing");
    assert!(result.ok, "{}", result.message);
    assert_eq!(result.message, "run started");

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.phases[0].status, PhaseStatus::Active);
    assert!(run.phases[0].started_at.is_some());
    assert_eq!(run.status_message.as_deref(), Some("Initializing"));
}

#[test]
fn start_is_idempotent_on_active_run() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run(&mut runs, "run-001");

    // Second start should succeed (idempotent)
    let result = start_run_with_message(&mut runs, "run-001", "Re-initializing");
    assert!(result.ok, "{}", result.message);
    assert_eq!(result.message, "run already started");

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.status_message.as_deref(), Some("Re-initializing"));
}

#[test]
fn start_rejected_on_terminal_run() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run(&mut runs, "run-001");
    mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Complete);

    let result = mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Start);
    assert!(!result.ok);
    assert!(result.message.contains("terminal"));
}

#[test]
fn start_without_message_leaves_none() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

    let result = mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Start);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.status_message.is_none());
}

#[test]
fn heartbeat_updates_message_and_timestamp() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run(&mut runs, "run-001");

    let ts_before = runs.values().next().unwrap().updated_at.clone();

    let mut cmd = base_cmd("run-001");
    cmd.status_message = Some("Composing prompt".to_string());
    let result = mutate(&mut runs, cmd, RunMutationKind::Heartbeat);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status_message.as_deref(), Some("Composing prompt"));
    assert!(run.updated_at >= ts_before);
}

#[test]
fn heartbeat_without_message_preserves_existing() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run_with_message(&mut runs, "run-001", "Starting");

    // Heartbeat with no message
    let result = mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Heartbeat);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status_message.as_deref(), Some("Starting"));
}

#[test]
fn heartbeat_rejected_on_terminal_run() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run(&mut runs, "run-001");
    mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Fail);

    let result = mutate(&mut runs, base_cmd("run-001"), RunMutationKind::Heartbeat);
    assert!(!result.ok);
    assert!(result.message.contains("terminal"));
}

#[test]
fn heartbeat_on_created_run_succeeds() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));

    // Heartbeat before Start is allowed — liveness signal on a not-yet-started run
    let mut cmd = base_cmd("run-001");
    cmd.status_message = Some("Preparing".to_string());
    let result = mutate(&mut runs, cmd, RunMutationKind::Heartbeat);
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Created);
    assert_eq!(run.status_message.as_deref(), Some("Preparing"));
}

#[test]
fn pause_updates_status_message() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "execution_only"));
    start_run(&mut runs, "run-001");

    let mut cmd = base_cmd("run-001");
    cmd.status_message = Some("Run blocked: gate rejected".to_string());
    let result = mutate(&mut runs, cmd, RunMutationKind::Pause);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(
        run.status_message.as_deref(),
        Some("Run blocked: gate rejected")
    );
}

#[test]
fn full_lifecycle_create_start_heartbeat_advance() {
    let mut runs = empty_runs();
    apply_run_mutation(&mut runs, create_command("run-001", "shape_and_execute"));

    // Start
    start_run_with_message(&mut runs, "run-001", "Phase 1 starting");
    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.phases[0].status, PhaseStatus::Active);

    // Heartbeat
    let mut cmd = base_cmd("run-001");
    cmd.status_message = Some("Dispatching Codex".to_string());
    mutate(&mut runs, cmd, RunMutationKind::Heartbeat);

    // Advance to phase 2
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

    // Heartbeat on phase 2
    let mut cmd = base_cmd("run-001");
    cmd.status_message = Some("Phase 2 in progress".to_string());
    mutate(&mut runs, cmd, RunMutationKind::Heartbeat);

    // Complete final phase
    let result = mutate(
        &mut runs,
        base_cmd("run-001"),
        RunMutationKind::AdvancePhase,
    );
    assert!(result.ok);

    let run = runs.values().next().unwrap();
    assert_eq!(run.status, RunStatus::Completed);
}
