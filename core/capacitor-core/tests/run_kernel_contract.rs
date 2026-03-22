//! Run Kernel integration tests.
//!
//! Tests the full Run lifecycle through CoreRuntime, validating:
//! - Method selection and phase instantiation
//! - Checkpoint emit/decide cycles
//! - Multi-phase method workflows
//! - Strangler bridge to delegation worker IDs
//! - Terminal state enforcement
//! - Snapshot persistence and recovery
//! - Multiple concurrent runs per project
//! - Method archetypes and involvement levels

use capacitor_core::domain::{
    CheckpointKind, InvolvementLevel, MutateRunCommand, RunMutationKind, RunStatus,
};
use capacitor_core::CoreRuntime;
use tempfile::TempDir;

const PROJECT: &str = "/test/run-kernel-project";

fn create_cmd(run_id: &str, method_id: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create,
        project_path: PROJECT.to_string(),
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

fn base_cmd(run_id: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create,
        project_path: PROJECT.to_string(),
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

fn mutate(
    runtime: &CoreRuntime,
    mut cmd: MutateRunCommand,
    kind: RunMutationKind,
) -> capacitor_core::domain::MutationOutcome {
    cmd.kind = kind;
    runtime.mutate_run(cmd).expect("mutation should not error")
}

// ===========================================================================
// Scenario 1: Simple execution-only method
// ===========================================================================

#[test]
fn scenario_execution_only_full_lifecycle() {
    let runtime = CoreRuntime::new().expect("runtime");

    // Create run with execution_only method
    let outcome = runtime
        .mutate_run(create_cmd("run-exec-01", "execution_only"))
        .expect("create");
    assert!(outcome.ok, "create failed: {}", outcome.message);

    // Verify initial state in snapshot
    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs.len(), 1);
    assert_eq!(snap.runs[0].id, "run-exec-01");
    assert_eq!(snap.runs[0].method_id, "execution_only");
    assert_eq!(snap.runs[0].status, RunStatus::Created);
    assert_eq!(snap.runs[0].phases.len(), 1);
    assert_eq!(snap.runs[0].phases[0].name, "Execute");

    // Attach session → activates run
    let mut cmd = base_cmd("run-exec-01");
    cmd.session_id = Some("session-aaa".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);
    assert_eq!(snap.runs[0].session_id.as_deref(), Some("session-aaa"));

    // Emit implementation milestone
    let mut cmd = base_cmd("run-exec-01");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Settings page complete".to_string());
    cmd.checkpoint_summary = Some("Implemented all CRUD operations".to_string());
    cmd.checkpoint_brief_path = Some("/path/to/brief.md".to_string());
    cmd.checkpoint_manifest_path = Some("/path/to/manifest.json".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    let ckpt = snap.runs[0].active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(ckpt.title, "Settings page complete");
    assert_eq!(ckpt.kind, CheckpointKind::ImplementationMilestone);

    // Submit approve decision
    let mut cmd = base_cmd("run-exec-01");
    cmd.decision_action = Some("approve".to_string());
    cmd.decision_note = Some("Looks great, ship it".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);
    assert!(snap.runs[0].active_checkpoint.is_none());

    // Advance past last phase → completes
    let outcome = mutate(
        &runtime,
        base_cmd("run-exec-01"),
        RunMutationKind::AdvancePhase,
    );
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Completed);
}

// ===========================================================================
// Scenario 2: Shape & Execute with multi-phase + multi-checkpoint
// ===========================================================================

#[test]
fn scenario_shape_and_execute_multi_phase() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(create_cmd("run-se-01", "shape_and_execute"))
        .expect("create");

    // Attach → starts Shape phase
    let mut cmd = base_cmd("run-se-01");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    // Emit proposal checkpoint in Shape phase
    let mut cmd = base_cmd("run-se-01");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("API design proposal".to_string());
    cmd.checkpoint_summary = Some("REST endpoints for user management".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    assert_eq!(
        snap.runs[0].active_checkpoint.as_ref().unwrap().kind,
        CheckpointKind::Proposal
    );

    // Request changes on proposal
    let mut cmd = base_cmd("run-se-01");
    cmd.decision_action = Some("request_changes".to_string());
    cmd.decision_note = Some("Add pagination support".to_string());
    mutate(&runtime, cmd, RunMutationKind::SubmitDecision);

    // Second proposal checkpoint
    let mut cmd = base_cmd("run-se-01");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Revised API design".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    // Approve revised proposal
    let mut cmd = base_cmd("run-se-01");
    cmd.decision_action = Some("approve".to_string());
    mutate(&runtime, cmd, RunMutationKind::SubmitDecision);

    // Advance to Execute phase
    mutate(
        &runtime,
        base_cmd("run-se-01"),
        RunMutationKind::AdvancePhase,
    );

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].current_phase_index, 1);
    assert_eq!(snap.runs[0].phases[0].name, "Shape");
    assert_eq!(snap.runs[0].phases[1].name, "Execute");

    // Implementation milestone in Execute phase
    let mut cmd = base_cmd("run-se-01");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("API implementation complete".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    // Approve milestone
    let mut cmd = base_cmd("run-se-01");
    cmd.decision_action = Some("approve".to_string());
    mutate(&runtime, cmd, RunMutationKind::SubmitDecision);

    // Advance past Execute → completes run
    mutate(
        &runtime,
        base_cmd("run-se-01"),
        RunMutationKind::AdvancePhase,
    );

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].status, RunStatus::Completed);
}

// ===========================================================================
// Scenario 3: Deep Debug method
// ===========================================================================

#[test]
fn scenario_deep_debug_three_phase() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(create_cmd("run-debug-01", "deep_debug"))
        .expect("create");

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].phases.len(), 3);
    assert_eq!(snap.runs[0].phases[0].name, "Investigate");
    assert_eq!(snap.runs[0].phases[1].name, "Hypothesize");
    assert_eq!(snap.runs[0].phases[2].name, "Validate");
    assert_eq!(snap.runs[0].involvement, InvolvementLevel::Collaborative);

    // Attach session
    let mut cmd = base_cmd("run-debug-01");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    // Walk through all three phases
    for (phase_idx, phase_name) in ["Investigate", "Hypothesize", "Validate"]
        .iter()
        .enumerate()
    {
        let snap = runtime.app_snapshot().expect("snap");
        assert_eq!(
            snap.runs[0].current_phase_index, phase_idx as u32,
            "expected phase index {} for {}",
            phase_idx, phase_name
        );

        // Emit checkpoint
        let mut cmd = base_cmd("run-debug-01");
        cmd.checkpoint_kind = Some(if phase_idx < 2 {
            CheckpointKind::Proposal
        } else {
            CheckpointKind::ImplementationMilestone
        });
        cmd.checkpoint_title = Some(format!("{} checkpoint", phase_name));
        mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

        // Decide
        let mut cmd = base_cmd("run-debug-01");
        cmd.decision_action = Some("approve".to_string());
        mutate(&runtime, cmd, RunMutationKind::SubmitDecision);

        // Advance
        mutate(
            &runtime,
            base_cmd("run-debug-01"),
            RunMutationKind::AdvancePhase,
        );
    }

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].status, RunStatus::Completed);
}

// ===========================================================================
// Scenario 4: Greenfield build method (4 phases)
// ===========================================================================

#[test]
fn scenario_greenfield_build_four_phases() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(create_cmd("run-gf-01", "greenfield_build"))
        .expect("create");

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].phases.len(), 4);
    assert_eq!(snap.runs[0].phases[0].name, "Scope");
    assert_eq!(snap.runs[0].phases[1].name, "Design");
    assert_eq!(snap.runs[0].phases[2].name, "Implement");
    assert_eq!(snap.runs[0].phases[3].name, "Verify");
}

// ===========================================================================
// Scenario 5: Strangler bridge — delegation worker ID
// ===========================================================================

#[test]
fn scenario_strangler_bridge_delegation_worker() {
    let runtime = CoreRuntime::new().expect("runtime");

    let mut cmd = create_cmd("run-bridge-01", "execution_only");
    cmd.delegation_worker_id = Some("worker-legacy-123".to_string());
    let outcome = runtime.mutate_run(cmd).expect("create");
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(
        snap.runs[0].delegation_worker_id.as_deref(),
        Some("worker-legacy-123")
    );

    // Can update delegation worker on attach
    let mut cmd = base_cmd("run-bridge-01");
    cmd.session_id = Some("s1".to_string());
    cmd.delegation_worker_id = Some("worker-new-456".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(
        snap.runs[0].delegation_worker_id.as_deref(),
        Some("worker-new-456")
    );
}

// ===========================================================================
// Scenario 6: Multiple concurrent runs on the same project
// ===========================================================================

#[test]
fn scenario_concurrent_runs_same_project() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(create_cmd("run-a", "execution_only"))
        .expect("create run-a");
    runtime
        .mutate_run(create_cmd("run-b", "shape_and_execute"))
        .expect("create run-b");

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs.len(), 2);

    // Both runs are independent
    let mut cmd = base_cmd("run-a");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let snap = runtime.app_snapshot().expect("snap");
    let run_a = snap.runs.iter().find(|r| r.id == "run-a").unwrap();
    let run_b = snap.runs.iter().find(|r| r.id == "run-b").unwrap();
    assert_eq!(run_a.status, RunStatus::Active);
    assert_eq!(run_b.status, RunStatus::Created);
}

// ===========================================================================
// Scenario 7: Involvement level override
// ===========================================================================

#[test]
fn scenario_involvement_level_override() {
    let runtime = CoreRuntime::new().expect("runtime");

    // Default involvement for execution_only is Supervised
    let outcome = runtime
        .mutate_run(create_cmd("run-default", "execution_only"))
        .expect("create");
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snap");
    let default_run = snap.runs.iter().find(|r| r.id == "run-default").unwrap();
    assert_eq!(default_run.involvement, InvolvementLevel::Supervised);

    // Override to Autonomous
    let mut cmd = create_cmd("run-auto", "execution_only");
    cmd.involvement = Some(InvolvementLevel::Autonomous);
    runtime.mutate_run(cmd).expect("create");

    let snap = runtime.app_snapshot().expect("snap");
    let auto_run = snap.runs.iter().find(|r| r.id == "run-auto").unwrap();
    assert_eq!(auto_run.involvement, InvolvementLevel::Autonomous);
}

// ===========================================================================
// Scenario 8: Error handling — invalid mutations
// ===========================================================================

#[test]
fn scenario_error_invalid_method() {
    let runtime = CoreRuntime::new().expect("runtime");
    let outcome = runtime
        .mutate_run(create_cmd("run-bad", "nonexistent_method"))
        .expect("outcome");
    assert!(!outcome.ok);
    assert!(outcome.message.contains("unknown method"));
}

#[test]
fn scenario_error_duplicate_checkpoint() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-dup", "execution_only"))
        .expect("create");

    let mut cmd = base_cmd("run-dup");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let mut cmd = base_cmd("run-dup");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("First".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    // Second checkpoint while first is active → rejected
    let mut cmd = base_cmd("run-dup");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Second".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(!outcome.ok);
    assert!(outcome.message.contains("checkpoint already active"));
}

#[test]
fn scenario_error_advance_with_active_checkpoint() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-block", "shape_and_execute"))
        .expect("create");

    let mut cmd = base_cmd("run-block");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let mut cmd = base_cmd("run-block");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Blocked".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    // Try to advance with undecided checkpoint → rejected
    let outcome = mutate(
        &runtime,
        base_cmd("run-block"),
        RunMutationKind::AdvancePhase,
    );
    assert!(!outcome.ok);
    assert!(outcome.message.contains("checkpoint must be decided"));
}

#[test]
fn scenario_error_decision_without_checkpoint() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-nocp", "execution_only"))
        .expect("create");

    let mut cmd = base_cmd("run-nocp");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let mut cmd = base_cmd("run-nocp");
    cmd.decision_action = Some("approve".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(!outcome.ok);
    assert!(outcome.message.contains("no active checkpoint"));
}

// ===========================================================================
// Scenario 9: Snapshot persistence and recovery
// ===========================================================================

#[test]
fn scenario_snapshot_recovery() {
    let temp = TempDir::new().expect("tempdir");
    let snap_path = temp.path().join("app_snapshot.json");

    // Create runtime, create a run, emit checkpoint
    let runtime = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("runtime");

    runtime
        .mutate_run(create_cmd("run-persist", "shape_and_execute"))
        .expect("create");

    let mut cmd = base_cmd("run-persist");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let mut cmd = base_cmd("run-persist");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Design doc".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    drop(runtime);

    // Recover from snapshot
    let recovered = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("recovered runtime");
    let snap = recovered.app_snapshot().expect("snapshot");

    assert_eq!(snap.runs.len(), 1);
    assert_eq!(snap.runs[0].id, "run-persist");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    assert!(snap.runs[0].active_checkpoint.is_some());
    assert_eq!(
        snap.runs[0].active_checkpoint.as_ref().unwrap().title,
        "Design doc"
    );
}

// ===========================================================================
// Scenario 10: Cancel and fail states
// ===========================================================================

#[test]
fn scenario_cancel_active_run() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-cancel", "execution_only"))
        .expect("create");

    let mut cmd = base_cmd("run-cancel");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let outcome = mutate(&runtime, base_cmd("run-cancel"), RunMutationKind::Cancel);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].status, RunStatus::Cancelled);

    // No further mutations accepted
    let mut cmd = base_cmd("run-cancel");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Shouldn't work".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(!outcome.ok);
}

#[test]
fn scenario_fail_run() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-fail", "execution_only"))
        .expect("create");

    let outcome = mutate(&runtime, base_cmd("run-fail"), RunMutationKind::Fail);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.runs[0].status, RunStatus::Failed);
}

// ===========================================================================
// Scenario 11: Runs coexist with delegations (strangler validation)
// ===========================================================================

#[test]
fn scenario_runs_and_delegations_coexist() {
    use capacitor_core::domain::{DelegationMutationKind, MutateDelegationCommand};

    let runtime = CoreRuntime::new().expect("runtime");

    // Create a delegation
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Start,
            project_path: PROJECT.to_string(),
            worker_id: "worker-1".to_string(),
            idea_id: Some("idea-1".to_string()),
            worktree_name: Some("wt-1".to_string()),
            worktree_path: Some("/tmp/wt-1".to_string()),
            session_id: None,
            milestone_id: None,
            brief_path: None,
            manifest_path: None,
            review_decision: None,
            note: None,
        })
        .expect("start delegation");

    // Create a run
    runtime
        .mutate_run(create_cmd("run-coexist", "execution_only"))
        .expect("create run");

    // Both appear in snapshot
    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.delegations.len(), 1);
    assert_eq!(snap.runs.len(), 1);
    assert_eq!(snap.delegations[0].worker_id, "worker-1");
    assert_eq!(snap.runs[0].id, "run-coexist");
}
