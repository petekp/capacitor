//! Realistic run kernel checkpoint scenario: idea-to-ship.
//!
//! Verifies: Create → AttachSession → AdvancePhase →
//! EmitCheckpoint (with mermaid) → SubmitDecision →
//! AdvancePhase → EmitCheckpoint → SubmitDecision → Complete

use capacitor_core::domain::{
    CheckpointKind, MermaidSource, MutateRunCommand, RunMutationKind, RunStatus,
};
use capacitor_core::CoreRuntime;

const PROJECT: &str = "/test/idea-to-ship";

fn base_cmd(run_id: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create, // overridden by mutate()
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
        status_message: None,
        idea_id: None,
        idea_title: None,
        idea_description: None,
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

fn active_checkpoint_id(runtime: &CoreRuntime, run_id: &str) -> String {
    runtime
        .app_snapshot()
        .expect("snapshot")
        .runs
        .iter()
        .find(|run| run.id == run_id)
        .expect("run exists")
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists")
        .id
        .clone()
}

#[test]
fn idea_to_ship_checkpoint_flow() {
    let runtime = CoreRuntime::new().expect("runtime");

    // 1. Create run with "shape_and_execute" method (has Shape + Execute phases)
    let mut cmd = base_cmd("run-its-01");
    cmd.method_id = Some("shape_and_execute".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::Create);
    assert!(result.ok, "create failed: {}", result.message);

    // 2. Attach session → activates run
    let mut cmd = base_cmd("run-its-01");
    cmd.session_id = Some("session-its".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);

    // 3. Emit proposal checkpoint in Shape phase (active after AttachSession)
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Requirements Analysis".to_string());
    cmd.checkpoint_summary = Some("Analyzed idea, 3 risks identified".to_string());
    cmd.checkpoint_manifest_path = Some("/path/to/manifest.json".to_string());
    cmd.checkpoint_mermaid_sources = vec![MermaidSource {
        label: "Architecture".to_string(),
        source: "graph TD; A[Idea] --> B[Shape]; B --> C[Build]; C --> D[Ship]".to_string(),
    }];
    let result = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(result.ok, "emit checkpoint failed: {}", result.message);

    // Verify: run paused with active checkpoint
    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    let ckpt = snap.runs[0].active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(ckpt.kind, CheckpointKind::Proposal);
    assert_eq!(ckpt.title, "Requirements Analysis");
    assert_eq!(ckpt.mermaid_sources.len(), 1);
    assert!(ckpt.manifest_path.is_some());

    // 4. Submit approval decision
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-its-01"));
    cmd.decision_action = Some("approve".to_string());
    cmd.decision_note = Some("Shape approved, proceed to build".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(result.ok, "submit decision failed: {}", result.message);

    // Verify: run active again, checkpoint cleared
    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);
    assert!(snap.runs[0].active_checkpoint.is_none());

    // 5. Advance past Shape → Execute phase
    let result = mutate(
        &runtime,
        base_cmd("run-its-01"),
        RunMutationKind::AdvancePhase,
    );
    assert!(result.ok);

    // 6. Emit implementation milestone in Execute phase
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Feature implementation complete".to_string());
    cmd.checkpoint_summary = Some("All tests pass, 5 files changed".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    let ckpt = snap.runs[0].active_checkpoint.as_ref().unwrap();
    assert_eq!(ckpt.kind, CheckpointKind::ImplementationMilestone);

    // 7. Approve → advance past last phase → run completes
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_id = Some(active_checkpoint_id(&runtime, "run-its-01"));
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(result.ok);

    let result = mutate(
        &runtime,
        base_cmd("run-its-01"),
        RunMutationKind::AdvancePhase,
    );
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Completed);
}
