use capacitor_core::domain::{
    DelegationMutationKind, DelegationReviewDecision, DelegationStatus, MutateDelegationCommand,
};
use capacitor_core::CoreRuntime;
use tempfile::TempDir;

fn start_command() -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::Start,
        project_path: "/tmp/runtime-delegation-project".to_string(),
        worker_id: "worker-1".to_string(),
        idea_id: Some("idea-1".to_string()),
        worktree_name: Some("delegation-worker-1".to_string()),
        worktree_path: Some(
            "/tmp/runtime-delegation-project/.capacitor/worktrees/delegation-worker-1".to_string(),
        ),
        session_id: None,
        milestone_id: None,
        brief_path: None,
        manifest_path: None,
        review_decision: None,
        note: None,
    }
}

#[test]
fn delegation_mutations_drive_review_loop_snapshot_contract() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_delegation(start_command())
        .expect("start delegation");

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::AttachSession,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("attach session");

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::ReviewReady,
            session_id: Some("session-123".to_string()),
            milestone_id: Some("01".to_string()),
            brief_path: Some(
                "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/01/brief.md"
                    .to_string(),
            ),
            manifest_path: Some(
                "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/01/manifest.json"
                    .to_string(),
            ),
            ..start_command()
        })
        .expect("mark review ready");

    let snapshot = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snapshot.delegations.len(), 1);

    let delegation = &snapshot.delegations[0];
    assert_eq!(delegation.project_path, "/tmp/runtime-delegation-project");
    assert_eq!(delegation.worker_id, "worker-1");
    assert_eq!(delegation.idea_id.as_deref(), Some("idea-1"));
    assert_eq!(delegation.session_id.as_deref(), Some("session-123"));
    assert_eq!(delegation.status, DelegationStatus::ReviewNeeded);
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01")
    );
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.manifest_path.as_str()),
        Some(
            "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
        ),
    );

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Resume,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("resume after review");

    let resumed_snapshot = runtime.app_snapshot().expect("resumed snapshot");
    assert_eq!(resumed_snapshot.delegations.len(), 1);
    let resumed = &resumed_snapshot.delegations[0];
    assert_eq!(resumed.status, DelegationStatus::Working);
    assert!(resumed.current_review.is_none());

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Complete,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("complete delegation");

    let completed_snapshot = runtime.app_snapshot().expect("completed snapshot");
    assert!(
        completed_snapshot.delegations.is_empty(),
        "complete should clear the active delegation from the snapshot",
    );
}

#[test]
fn delegation_snapshot_recovers_after_runtime_restart() {
    let temp = TempDir::new().expect("tempdir");
    let snapshot_path = temp.path().join("app_snapshot.json");
    let runtime = CoreRuntime::new_with_snapshot_file(snapshot_path.to_string_lossy().to_string())
        .expect("runtime");

    runtime
        .mutate_delegation(start_command())
        .expect("start delegation");
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::ReviewReady,
            session_id: Some("session-123".to_string()),
            milestone_id: Some("01".to_string()),
            brief_path: Some(
                "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/01/brief.md"
                    .to_string(),
            ),
            manifest_path: Some(
                "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/01/manifest.json"
                    .to_string(),
            ),
            ..start_command()
        })
        .expect("review ready");

    drop(runtime);

    let recovered =
        CoreRuntime::new_with_snapshot_file(snapshot_path.to_string_lossy().to_string())
            .expect("recovered runtime");
    let snapshot = recovered.app_snapshot().expect("snapshot");

    assert_eq!(snapshot.delegations.len(), 1);
    assert_eq!(
        snapshot.delegations[0].status,
        DelegationStatus::ReviewNeeded
    );
    assert_eq!(
        snapshot.delegations[0]
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01"),
    );
}
