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

mod common;

use capacitor_core::domain::{
    CaptureStatus, CheckpointKind, CheckpointStatus, InvolvementLevel, MediaArtifact,
    MediaArtifactType, MermaidSource, RunState, RunStatus,
};
use capacitor_core::CoreRuntime;
use common::{active_checkpoint_id, mutate_run as mutate, RunCommandBuilder, RunMutationKind};
use tempfile::TempDir;

const PROJECT: &str = "/test/run-kernel-project";

fn create_cmd(run_id: &str, method_id: &str) -> RunCommandBuilder {
    common::run_kernel_create_cmd(PROJECT, run_id, method_id)
}

fn base_cmd(run_id: &str) -> RunCommandBuilder {
    common::run_kernel_base_cmd(PROJECT, run_id)
}

// ===========================================================================
// Scenario 1: Simple execution-only method
// ===========================================================================

#[test]
fn scenario_execution_only_full_lifecycle() {
    let runtime = CoreRuntime::new().expect("runtime");

    // Create run with execution_only method
    let outcome = runtime
        .mutate_run(
            create_cmd("run-exec-01", "execution_only").into_command(RunMutationKind::Create),
        )
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
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-exec-01"));
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
// Scenario 2: Capture lifecycle on a checkpoint
// ===========================================================================

#[test]
fn scenario_capture_checkpoint_lifecycle() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-capture-01", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-capture-01")
        .expect("created run");
    assert_eq!(run.status, RunStatus::Created);
    assert!(run.active_checkpoint.is_none());

    let mut cmd = base_cmd("run-capture-01");
    cmd.session_id = Some("session-capture-01".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-capture-01")
        .expect("attached run");
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.session_id.as_deref(), Some("session-capture-01"));
    assert_eq!(run.current_phase_index, 0);
    assert_eq!(
        run.phases[0].status,
        capacitor_core::domain::PhaseStatus::Active
    );

    let mut cmd = base_cmd("run-capture-01");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Capture milestone".to_string());
    cmd.capture_url = Some("http://localhost:3000".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-capture-01")
        .expect("checkpoint run");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(
        checkpoint.capture_url.as_deref(),
        Some("http://localhost:3000")
    );
    assert_eq!(checkpoint.capture_status, CaptureStatus::Pending);
    assert!(checkpoint.capture_claim.is_none());

    let capture_request_id = "capture-request-01".to_string();
    let mut cmd = base_cmd("run-capture-01");
    cmd.checkpoint_id = Some(checkpoint.id.clone());
    cmd.capture_request_id = Some(capture_request_id.clone());
    cmd.client_id = Some("client-01".to_string());
    cmd.observed_capture_url = Some("http://localhost:3000".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::CaptureClaim);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-capture-01")
        .expect("claimed run");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(checkpoint.capture_status, CaptureStatus::InProgress);
    let claim = checkpoint.capture_claim.as_ref().expect("claim");
    assert_eq!(claim.capture_request_id, capture_request_id);
    assert_eq!(claim.client_id, "client-01");
    assert_eq!(
        claim.observed_capture_url.as_deref(),
        Some("http://localhost:3000")
    );

    let mut cmd = base_cmd("run-capture-01");
    cmd.checkpoint_id = Some(checkpoint.id.clone());
    cmd.capture_request_id = Some(capture_request_id.clone());
    cmd.completed_media_artifacts = vec![MediaArtifact {
        artifact_type: MediaArtifactType::Screenshot,
        path: "/tmp/capture.png".to_string(),
        label: "Capture screenshot".to_string(),
        width: Some(1280),
        height: Some(800),
        duration_secs: None,
    }];
    let outcome = mutate(&runtime, cmd, RunMutationKind::CaptureComplete);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-capture-01")
        .expect("completed run");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(checkpoint.capture_status, CaptureStatus::Completed);
    assert_eq!(checkpoint.media_artifacts.len(), 1);
    assert_eq!(checkpoint.media_artifacts[0].path, "/tmp/capture.png");
}

// ===========================================================================
// Scenario 2: Shape & Execute with multi-phase + multi-checkpoint
// ===========================================================================

#[test]
fn scenario_shape_and_execute_multi_phase() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-se-01", "shape_and_execute").into_command(RunMutationKind::Create),
        )
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
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-se-01"));
    cmd.decision_action = Some("request_changes".to_string());
    cmd.decision_note = Some("Add pagination support".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "{}", outcome.message);

    // Second proposal checkpoint
    let mut cmd = base_cmd("run-se-01");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Revised API design".to_string());
    mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);

    // Approve revised proposal
    let mut cmd = base_cmd("run-se-01");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-se-01"));
    cmd.decision_action = Some("approve".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "{}", outcome.message);

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
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-se-01"));
    cmd.decision_action = Some("approve".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "{}", outcome.message);

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
        .mutate_run(create_cmd("run-debug-01", "deep_debug").into_command(RunMutationKind::Create))
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
        cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-debug-01"));
        cmd.decision_action = Some("approve".to_string());
        let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
        assert!(outcome.ok, "{}", outcome.message);

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
        .mutate_run(
            create_cmd("run-gf-01", "greenfield_build").into_command(RunMutationKind::Create),
        )
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
    let outcome = runtime
        .mutate_run(cmd.into_command(RunMutationKind::Create))
        .expect("create");
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
        .mutate_run(create_cmd("run-a", "execution_only").into_command(RunMutationKind::Create))
        .expect("create run-a");
    runtime
        .mutate_run(create_cmd("run-b", "shape_and_execute").into_command(RunMutationKind::Create))
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
        .mutate_run(
            create_cmd("run-default", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snap");
    let default_run = snap.runs.iter().find(|r| r.id == "run-default").unwrap();
    assert_eq!(default_run.involvement, InvolvementLevel::Supervised);

    // Override to Autonomous
    let mut cmd = create_cmd("run-auto", "execution_only");
    cmd.involvement = Some(InvolvementLevel::Autonomous);
    runtime
        .mutate_run(cmd.into_command(RunMutationKind::Create))
        .expect("create");

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
        .mutate_run(
            create_cmd("run-bad", "nonexistent_method").into_command(RunMutationKind::Create),
        )
        .expect("outcome");
    assert!(!outcome.ok);
    assert!(outcome.message.contains("unknown method"));
}

#[test]
fn scenario_error_duplicate_checkpoint() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(create_cmd("run-dup", "execution_only").into_command(RunMutationKind::Create))
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
fn scenario_emit_checkpoint_preserves_caller_supplied_checkpoint_id() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(
            create_cmd("run-gate-id", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-gate-id");
    cmd.session_id = Some("session-gate-id".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-gate-id");
    cmd.checkpoint_id = Some("gate-build".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Build approval".to_string());
    cmd.checkpoint_manifest_path = Some("/tmp/gate-build.json".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok, "emit failed: {}", outcome.message);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-gate-id")
        .expect("run exists");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint exists");
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(checkpoint.id, "gate-build");
}

#[test]
fn scenario_reemitting_same_checkpoint_is_idempotent() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(
            create_cmd("run-gate-reemit", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-gate-reemit");
    cmd.session_id = Some("session-gate-reemit".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut emit_cmd = base_cmd("run-gate-reemit");
    emit_cmd.checkpoint_id = Some("gate-build".to_string());
    emit_cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    emit_cmd.checkpoint_title = Some("Build approval".to_string());
    emit_cmd.checkpoint_manifest_path = Some("/tmp/gate-build.json".to_string());
    let first = mutate(&runtime, emit_cmd.clone(), RunMutationKind::EmitCheckpoint);
    assert!(first.ok, "first emit failed: {}", first.message);

    let first_snap = runtime.app_snapshot().expect("snapshot");
    let first_run = first_snap
        .runs
        .iter()
        .find(|run| run.id == "run-gate-reemit")
        .expect("run exists");
    let first_checkpoint = first_run
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists");
    let first_created_at = first_checkpoint.created_at.clone();
    let first_history_ordinal = first_checkpoint.history_ordinal;
    assert_eq!(first_history_ordinal, Some(0));
    assert_eq!(first_run.next_checkpoint_history_ordinal, 1);

    let second = mutate(&runtime, emit_cmd, RunMutationKind::EmitCheckpoint);
    assert!(second.ok, "second emit failed: {}", second.message);

    let second_snap = runtime.app_snapshot().expect("snapshot");
    let second_run = second_snap
        .runs
        .iter()
        .find(|run| run.id == "run-gate-reemit")
        .expect("run exists");
    let second_checkpoint = second_run
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists");
    assert_eq!(second_run.status, RunStatus::Paused);
    assert_eq!(second_checkpoint.id, "gate-build");
    assert_eq!(second_checkpoint.created_at, first_created_at);
    assert_eq!(second_checkpoint.history_ordinal, first_history_ordinal);
    assert_eq!(second_run.next_checkpoint_history_ordinal, 1);
}

#[test]
fn scenario_submit_decision_validates_checkpoint_id() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(
            create_cmd("run-gate-decision", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-gate-decision");
    cmd.session_id = Some("session-gate-decision".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-gate-decision");
    cmd.checkpoint_id = Some("gate-build".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Build approval".to_string());
    cmd.checkpoint_manifest_path = Some("/tmp/gate-build.json".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok, "emit failed: {}", outcome.message);

    let mut missing_id = base_cmd("run-gate-decision");
    missing_id.decision_action = Some("approve".to_string());
    let missing_result = mutate(&runtime, missing_id, RunMutationKind::SubmitDecision);
    assert!(!missing_result.ok);
    assert!(missing_result.message.contains("missing checkpoint_id"));

    let mut wrong_id = base_cmd("run-gate-decision");
    wrong_id.checkpoint_id = Some("wrong-id".to_string());
    wrong_id.decision_action = Some("approve".to_string());
    let wrong_result = mutate(&runtime, wrong_id, RunMutationKind::SubmitDecision);
    assert!(!wrong_result.ok);
    assert!(wrong_result
        .message
        .contains("checkpoint_id does not match active checkpoint"));

    let mut correct_id = base_cmd("run-gate-decision");
    correct_id.checkpoint_id = Some("gate-build".to_string());
    correct_id.decision_action = Some("approve".to_string());
    let correct_result = mutate(&runtime, correct_id, RunMutationKind::SubmitDecision);
    assert!(
        correct_result.ok,
        "decision failed: {}",
        correct_result.message
    );

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-gate-decision")
        .expect("run exists");
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.active_checkpoint.is_none());
}

#[test]
fn scenario_submit_decision_archives_decided_checkpoint_history() {
    let temp = TempDir::new().expect("tempdir");
    let snap_path = temp.path().join("app_snapshot.json");
    let runtime = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-checkpoint-history", "execution_only")
                .into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-checkpoint-history");
    cmd.session_id = Some("session-checkpoint-history".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-checkpoint-history");
    cmd.checkpoint_id = Some("gate-review".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Review gate".to_string());
    cmd.checkpoint_summary = Some("Confirm the implementation checkpoint".to_string());
    cmd.checkpoint_manifest_path = Some("/tmp/gate-review.json".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok, "emit failed: {}", outcome.message);

    let mut cmd = base_cmd("run-checkpoint-history");
    cmd.checkpoint_id = Some("gate-review".to_string());
    cmd.decision_action = Some("rejected".to_string());
    cmd.decision_note = Some("Needs another pass".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "decision failed: {}", outcome.message);
    assert_eq!(outcome.message, "decision recorded: request_changes");

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-checkpoint-history")
        .expect("run exists");
    assert_eq!(run.status, RunStatus::Paused);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    let decided = &run.past_checkpoints[0];
    assert_eq!(decided.id, "gate-review");
    assert_eq!(
        decided.status,
        capacitor_core::domain::CheckpointStatus::Decided
    );
    assert!(decided.decided_at.is_some());
    let decision = decided.decision.as_ref().expect("decision archived");
    assert_eq!(decision.action, "request_changes");
    assert_eq!(decision.note.as_deref(), Some("Needs another pass"));

    drop(runtime);

    let recovered = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("recovered runtime");
    let snap = recovered.app_snapshot().expect("recovered snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-checkpoint-history")
        .expect("recovered run exists");
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    assert_eq!(
        run.past_checkpoints[0]
            .decision
            .as_ref()
            .map(|decision| decision.action.as_str()),
        Some("request_changes")
    );
}

#[test]
fn scenario_approve_archives_full_checkpoint_payload() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-checkpoint-payload", "execution_only")
                .into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-checkpoint-payload");
    cmd.session_id = Some("session-checkpoint-payload".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-checkpoint-payload");
    cmd.checkpoint_id = Some("gate-full-payload".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Full payload gate".to_string());
    cmd.checkpoint_summary = Some("Every checkpoint field should survive archive".to_string());
    cmd.checkpoint_brief_path = Some("/tmp/full-payload-brief.md".to_string());
    cmd.checkpoint_manifest_path = Some("/tmp/full-payload-manifest.json".to_string());
    cmd.capture_url = Some("http://localhost:3000/full-payload".to_string());
    cmd.checkpoint_media_artifacts = vec![MediaArtifact {
        artifact_type: MediaArtifactType::Screenshot,
        path: "/tmp/full-payload.png".to_string(),
        label: "Full payload screenshot".to_string(),
        width: Some(1440),
        height: Some(900),
        duration_secs: None,
    }];
    cmd.checkpoint_mermaid_sources = vec![MermaidSource {
        label: "Review flow".to_string(),
        source: "flowchart TD; A-->B".to_string(),
    }];
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok, "emit failed: {}", outcome.message);

    let mut cmd = base_cmd("run-checkpoint-payload");
    cmd.checkpoint_id = Some("gate-full-payload".to_string());
    cmd.decision_action = Some("approve".to_string());
    cmd.decision_note = Some("Approved with all payload fields intact".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "decision failed: {}", outcome.message);
    assert_eq!(outcome.message, "decision recorded: approve");

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-checkpoint-payload")
        .expect("run exists");
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);

    let archived = &run.past_checkpoints[0];
    assert_eq!(archived.id, "gate-full-payload");
    assert_eq!(archived.history_ordinal, Some(0));
    assert_eq!(archived.phase_id, "phase-001");
    assert_eq!(archived.kind, CheckpointKind::ImplementationMilestone);
    assert_eq!(archived.status, CheckpointStatus::Decided);
    assert_eq!(archived.title, "Full payload gate");
    assert_eq!(
        archived.summary.as_deref(),
        Some("Every checkpoint field should survive archive")
    );
    assert_eq!(
        archived.brief_path.as_deref(),
        Some("/tmp/full-payload-brief.md")
    );
    assert_eq!(
        archived.manifest_path.as_deref(),
        Some("/tmp/full-payload-manifest.json")
    );
    assert_eq!(
        archived.capture_url.as_deref(),
        Some("http://localhost:3000/full-payload")
    );
    assert_eq!(archived.capture_status, CaptureStatus::Pending);
    assert_eq!(archived.media_artifacts.len(), 1);
    assert_eq!(
        archived.media_artifacts[0].artifact_type,
        MediaArtifactType::Screenshot
    );
    assert_eq!(archived.media_artifacts[0].path, "/tmp/full-payload.png");
    assert_eq!(archived.media_artifacts[0].label, "Full payload screenshot");
    assert_eq!(archived.media_artifacts[0].width, Some(1440));
    assert_eq!(archived.media_artifacts[0].height, Some(900));
    assert_eq!(archived.mermaid_sources.len(), 1);
    assert_eq!(archived.mermaid_sources[0].label, "Review flow");
    assert_eq!(archived.mermaid_sources[0].source, "flowchart TD; A-->B");
    assert!(archived.decided_at.is_some());
    let decision = archived.decision.as_ref().expect("decision archived");
    assert_eq!(decision.action, "approve");
    assert_eq!(
        decision.note.as_deref(),
        Some("Approved with all payload fields intact")
    );
}

#[test]
fn scenario_completed_run_preserves_checkpoint_history_after_restart() {
    let temp = TempDir::new().expect("tempdir");
    let snap_path = temp.path().join("app_snapshot.json");
    let runtime = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-completed-history", "execution_only")
                .into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-completed-history");
    cmd.session_id = Some("session-completed-history".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-completed-history");
    cmd.checkpoint_id = Some("gate-before-complete".to_string());
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Before completion".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok, "emit failed: {}", outcome.message);

    let mut cmd = base_cmd("run-completed-history");
    cmd.checkpoint_id = Some("gate-before-complete".to_string());
    cmd.decision_action = Some("approve".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(outcome.ok, "decision failed: {}", outcome.message);

    let outcome = mutate(
        &runtime,
        base_cmd("run-completed-history"),
        RunMutationKind::AdvancePhase,
    );
    assert!(outcome.ok, "complete failed: {}", outcome.message);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-completed-history")
        .expect("run exists before restart");
    assert_eq!(run.status, RunStatus::Completed);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    assert_eq!(run.past_checkpoints[0].id, "gate-before-complete");
    assert_eq!(run.past_checkpoints[0].history_ordinal, Some(0));
    assert_eq!(run.next_checkpoint_history_ordinal, 1);

    drop(runtime);

    let recovered = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("recovered runtime");
    let snap = recovered.app_snapshot().expect("recovered snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-completed-history")
        .expect("recovered run exists");
    assert_eq!(run.status, RunStatus::Completed);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 1);
    assert_eq!(run.past_checkpoints[0].id, "gate-before-complete");
    assert_eq!(run.past_checkpoints[0].history_ordinal, Some(0));
    assert_eq!(run.next_checkpoint_history_ordinal, 1);
}

#[test]
fn scenario_checkpoint_history_truncates_oldest_records_deterministically() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-checkpoint-retention", "execution_only")
                .into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-checkpoint-retention");
    cmd.session_id = Some("session-checkpoint-retention".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    for index in 0..55 {
        let checkpoint_id = format!("gate-{index:02}");

        let mut cmd = base_cmd("run-checkpoint-retention");
        cmd.checkpoint_id = Some(checkpoint_id.clone());
        cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
        cmd.checkpoint_title = Some(format!("Retention gate {index:02}"));
        let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
        assert!(
            outcome.ok,
            "emit {checkpoint_id} failed: {}",
            outcome.message
        );

        let mut cmd = base_cmd("run-checkpoint-retention");
        cmd.checkpoint_id = Some(checkpoint_id.clone());
        cmd.decision_action = Some("approve".to_string());
        let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
        assert!(
            outcome.ok,
            "decision {checkpoint_id} failed: {}",
            outcome.message
        );
    }

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-checkpoint-retention")
        .expect("run exists");
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.active_checkpoint.is_none());
    assert_eq!(run.past_checkpoints.len(), 50);
    assert_eq!(run.past_checkpoints.first().unwrap().id, "gate-05");
    assert_eq!(run.past_checkpoints.last().unwrap().id, "gate-54");
    assert_eq!(
        run.past_checkpoints
            .iter()
            .map(|checkpoint| checkpoint.history_ordinal)
            .collect::<Vec<_>>(),
        (5..55).map(Some).collect::<Vec<_>>()
    );
    assert_eq!(run.next_checkpoint_history_ordinal, 55);
    assert!(run
        .past_checkpoints
        .iter()
        .all(|checkpoint| checkpoint.status == CheckpointStatus::Decided));
}

#[test]
fn scenario_error_advance_with_active_checkpoint() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(
            create_cmd("run-block", "shape_and_execute").into_command(RunMutationKind::Create),
        )
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
        .mutate_run(create_cmd("run-nocp", "execution_only").into_command(RunMutationKind::Create))
        .expect("create");

    let mut cmd = base_cmd("run-nocp");
    cmd.session_id = Some("s1".to_string());
    mutate(&runtime, cmd, RunMutationKind::AttachSession);

    let mut cmd = base_cmd("run-nocp");
    cmd.decision_action = Some("approve".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(!outcome.ok);
    assert!(outcome.message.contains("missing checkpoint_id"));
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
        .mutate_run(
            create_cmd("run-persist", "shape_and_execute").into_command(RunMutationKind::Create),
        )
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

#[test]
fn scenario_idea_fields_survive_create_snapshot_roundtrip() {
    let temp = TempDir::new().expect("tempdir");
    let snap_path = temp.path().join("app_snapshot.json");

    let runtime = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("runtime");

    let mut cmd = create_cmd("run-idea-roundtrip", "execution_only");
    cmd.idea_id = Some("test-idea-1".to_string());
    cmd.idea_title = Some("Fix input width".to_string());
    cmd.idea_description = Some("The input field is too narrow on mobile".to_string());
    let outcome = runtime
        .mutate_run(cmd.into_command(RunMutationKind::Create))
        .expect("create");
    assert!(outcome.ok, "create failed: {}", outcome.message);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-idea-roundtrip")
        .expect("created run");
    assert_eq!(run.idea_id.as_deref(), Some("test-idea-1"));
    assert_eq!(run.idea_title.as_deref(), Some("Fix input width"));
    assert_eq!(
        run.idea_description.as_deref(),
        Some("The input field is too narrow on mobile")
    );

    drop(runtime);

    let recovered = CoreRuntime::new_with_snapshot_file(snap_path.to_string_lossy().to_string())
        .expect("recovered runtime");
    let snap = recovered.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-idea-roundtrip")
        .expect("recovered run");
    assert_eq!(run.idea_id.as_deref(), Some("test-idea-1"));
    assert_eq!(run.idea_title.as_deref(), Some("Fix input width"));
    assert_eq!(
        run.idea_description.as_deref(),
        Some("The input field is too narrow on mobile")
    );
}

#[test]
fn run_state_deserializes_without_idea_fields() {
    let payload = serde_json::json!({
        "id": "run-legacy-idea-fields",
        "project_path": PROJECT,
        "method_id": "execution_only",
        "method_name": "Execution Only",
        "involvement": "supervised",
        "status": "active",
        "phases": [
            {
                "id": "phase-001",
                "template_id": "execute",
                "name": "Execute",
                "status": "active",
                "checkpoint_policy": "manual",
                "skill_hint": null,
                "started_at": "2026-03-26T10:00:00Z",
                "completed_at": null
            }
        ],
        "current_phase_index": 0,
        "active_checkpoint": null,
        "session_id": "session-legacy",
        "delegation_worker_id": null,
        "status_message": "Drafting the implementation plan",
        "created_at": "2026-03-26T10:00:00Z",
        "updated_at": "2026-03-26T10:05:00Z"
    });

    let json = payload.to_string();
    let run_state = serde_json::from_str::<RunState>(&json).expect("deserialize legacy run state");

    assert_eq!(run_state.idea_id, None);
    assert_eq!(run_state.idea_title, None);
    assert_eq!(run_state.idea_description, None);
    assert!(run_state.past_checkpoints.is_empty());
    assert_eq!(run_state.next_checkpoint_history_ordinal, 0);
}

#[test]
fn run_state_deserializes_checkpoint_history_without_ordinals() {
    let payload = serde_json::json!({
        "id": "run-legacy-checkpoint-ordinals",
        "project_path": PROJECT,
        "method_id": "execution_only",
        "method_name": "Execution Only",
        "involvement": "supervised",
        "status": "paused",
        "phases": [
            {
                "id": "phase-001",
                "template_id": "execute",
                "name": "Execute",
                "status": "active",
                "checkpoint_policy": "manual",
                "skill_hint": null,
                "started_at": "2026-03-26T10:00:00Z",
                "completed_at": null
            }
        ],
        "current_phase_index": 0,
        "active_checkpoint": {
            "id": "gate-active",
            "phase_id": "phase-001",
            "kind": "implementation_milestone",
            "status": "active",
            "title": "Legacy active gate",
            "summary": null,
            "brief_path": null,
            "manifest_path": null,
            "media_artifacts": [],
            "mermaid_sources": [],
            "capture_status": "not_requested",
            "capture_url": null,
            "capture_claim": null,
            "decision_relay": null,
            "decision": null,
            "created_at": "2026-03-26T10:01:00Z",
            "decided_at": null
        },
        "past_checkpoints": [
            {
                "id": "gate-archived",
                "phase_id": "phase-001",
                "kind": "implementation_milestone",
                "status": "decided",
                "title": "Legacy archived gate",
                "summary": null,
                "brief_path": null,
                "manifest_path": null,
                "media_artifacts": [],
                "mermaid_sources": [],
                "capture_status": "not_requested",
                "capture_url": null,
                "capture_claim": null,
                "decision_relay": null,
                "decision": {"action": "approve", "note": null},
                "created_at": "2026-03-26T10:00:00Z",
                "decided_at": "2026-03-26T10:02:00Z"
            }
        ],
        "session_id": "session-legacy",
        "delegation_worker_id": null,
        "status_message": null,
        "created_at": "2026-03-26T10:00:00Z",
        "updated_at": "2026-03-26T10:05:00Z"
    });

    let json = payload.to_string();
    let run_state =
        serde_json::from_str::<RunState>(&json).expect("deserialize legacy checkpoint history");

    assert_eq!(
        run_state
            .active_checkpoint
            .as_ref()
            .and_then(|checkpoint| checkpoint.history_ordinal),
        None
    );
    assert_eq!(run_state.past_checkpoints[0].history_ordinal, None);
    assert_eq!(run_state.next_checkpoint_history_ordinal, 0);
}

#[test]
fn scenario_idea_fields_default_to_none_when_omitted() {
    let runtime = CoreRuntime::new().expect("runtime");

    let outcome = runtime
        .mutate_run(
            create_cmd("run-idea-none", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");
    assert!(outcome.ok, "create failed: {}", outcome.message);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-idea-none")
        .expect("created run");
    assert_eq!(run.idea_id, None);
    assert_eq!(run.idea_title, None);
    assert_eq!(run.idea_description, None);
}

// ===========================================================================
// Scenario 10: Cancel and fail states
// ===========================================================================

#[test]
fn scenario_cancel_active_run() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .mutate_run(
            create_cmd("run-cancel", "execution_only").into_command(RunMutationKind::Create),
        )
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
        .mutate_run(create_cmd("run-fail", "execution_only").into_command(RunMutationKind::Create))
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
        .mutate_run(
            create_cmd("run-coexist", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create run");

    // Both appear in snapshot
    let snap = runtime.app_snapshot().expect("snap");
    assert_eq!(snap.delegations.len(), 1);
    assert_eq!(snap.runs.len(), 1);
    assert_eq!(snap.delegations[0].worker_id, "worker-1");
    assert_eq!(snap.runs[0].id, "run-coexist");
}

// ===========================================================================
// Scenario 8: capture_complete rejects empty artifacts
// ===========================================================================

#[test]
fn scenario_capture_complete_rejects_empty_artifacts() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_run(
            create_cmd("run-empty-cap", "execution_only").into_command(RunMutationKind::Create),
        )
        .expect("create");

    let mut cmd = base_cmd("run-empty-cap");
    cmd.session_id = Some("session-empty-cap".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(outcome.ok);

    let mut cmd = base_cmd("run-empty-cap");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Empty capture test".to_string());
    cmd.capture_url = Some("http://localhost:3000".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(outcome.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-empty-cap")
        .expect("run");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");

    let mut cmd = base_cmd("run-empty-cap");
    cmd.checkpoint_id = Some(checkpoint.id.clone());
    cmd.capture_request_id = Some("cap-req-empty".to_string());
    cmd.client_id = Some("client-01".to_string());
    cmd.observed_capture_url = Some("http://localhost:3000".to_string());
    let outcome = mutate(&runtime, cmd, RunMutationKind::CaptureClaim);
    assert!(outcome.ok);

    // Attempt capture_complete with empty artifacts — should be rejected
    let mut cmd = base_cmd("run-empty-cap");
    cmd.checkpoint_id = Some(checkpoint.id.clone());
    cmd.capture_request_id = Some("cap-req-empty".to_string());
    cmd.completed_media_artifacts = vec![];
    let outcome = mutate(&runtime, cmd, RunMutationKind::CaptureComplete);
    assert!(
        !outcome.ok,
        "capture_complete with empty artifacts must be rejected"
    );

    // Checkpoint should still be InProgress
    let snap = runtime.app_snapshot().expect("snapshot");
    let run = snap
        .runs
        .iter()
        .find(|run| run.id == "run-empty-cap")
        .expect("run after rejection");
    let checkpoint = run.active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(checkpoint.capture_status, CaptureStatus::InProgress);
}
