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

fn review_ready_command(milestone_id: &str) -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::ReviewReady,
        session_id: Some("session-123".to_string()),
        milestone_id: Some(milestone_id.to_string()),
        brief_path: Some(format!(
            "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/{milestone_id}/brief.md"
        )),
        manifest_path: Some(format!(
            "/tmp/runtime-delegation-project/.capacitor/delegations/worker-1/milestones/{milestone_id}/manifest.json"
        )),
        ..start_command()
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
        .mutate_delegation(review_ready_command("01"))
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
    assert_eq!(delegation.status, DelegationStatus::ReviewNeeded);
    assert_eq!(
        delegation.submitted_milestone_id.as_deref(),
        None,
        "no submission has been accepted yet",
    );

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("submit review");

    let submitted_snapshot = runtime.app_snapshot().expect("submitted snapshot");
    assert_eq!(submitted_snapshot.delegations.len(), 1);
    let submitted = &submitted_snapshot.delegations[0];
    assert_eq!(submitted.status, DelegationStatus::ResumePending);
    assert!(submitted.current_review.is_some());
    assert_eq!(
        submitted.submitted_milestone_id.as_deref(),
        Some("01"),
        "accepted submissions should remember the milestone that was reviewed",
    );

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Resume,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("resume after review");

    let resumed_snapshot = runtime.app_snapshot().expect("resumed snapshot");
    assert_eq!(resumed_snapshot.delegations.len(), 1);
    let resumed = &resumed_snapshot.delegations[0];
    assert_eq!(resumed.status, DelegationStatus::Working);
    assert!(resumed.current_review.is_none());
    assert_eq!(resumed.submitted_milestone_id.as_deref(), Some("01"));

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
fn delegation_multi_round_review_iteration() {
    let runtime = CoreRuntime::new().expect("runtime");

    // Start delegation
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

    // Round 1: ReviewReady("01")
    runtime
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready 01");

    let snap1 = runtime
        .app_snapshot()
        .expect("snapshot after review_ready 01");
    assert_eq!(snap1.delegations[0].status, DelegationStatus::ReviewNeeded);
    assert_eq!(
        snap1.delegations[0]
            .current_review
            .as_ref()
            .map(|r| r.milestone_id.as_str()),
        Some("01"),
    );

    // Round 1: Submit the review, then let the worker resume in the background.
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::RequestChanges),
            note: Some("Fix the error handling".to_string()),
            ..start_command()
        })
        .expect("submit request_changes");

    let snap2 = runtime
        .app_snapshot()
        .expect("snapshot after submit request_changes");
    assert_eq!(snap2.delegations[0].status, DelegationStatus::ResumePending);
    assert!(
        snap2.delegations[0].current_review.is_some(),
        "current_review should stay available while the submission is pending resume",
    );
    assert_eq!(
        snap2.delegations[0].submitted_milestone_id.as_deref(),
        Some("01"),
    );

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Resume,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("resume after request_changes");

    let snap2b = runtime
        .app_snapshot()
        .expect("snapshot after resume request_changes");
    assert_eq!(snap2b.delegations[0].status, DelegationStatus::Working);
    assert!(
        snap2b.delegations[0].current_review.is_none(),
        "current_review should clear on Resume",
    );
    assert_eq!(
        snap2b.delegations[0].submitted_milestone_id.as_deref(),
        Some("01"),
        "the submitted milestone must survive the background resume phase",
    );

    // Round 2: ReviewReady("02")
    runtime
        .mutate_delegation(review_ready_command("02"))
        .expect("review ready 02");

    let snap3 = runtime
        .app_snapshot()
        .expect("snapshot after review_ready 02");
    assert_eq!(snap3.delegations[0].status, DelegationStatus::ReviewNeeded);
    assert_eq!(
        snap3.delegations[0]
            .current_review
            .as_ref()
            .map(|r| r.milestone_id.as_str()),
        Some("02"),
    );

    // Round 2: Submit the approval and resume again.
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Looks good".to_string()),
            ..start_command()
        })
        .expect("submit approve");

    let snap4 = runtime.app_snapshot().expect("snapshot after approve");
    assert_eq!(snap4.delegations[0].status, DelegationStatus::ResumePending);
    assert!(snap4.delegations[0].current_review.is_some());
    assert_eq!(
        snap4.delegations[0].submitted_milestone_id.as_deref(),
        Some("02")
    );

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Resume,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("resume with approve");

    let snap4b = runtime
        .app_snapshot()
        .expect("snapshot after approve resume");
    assert_eq!(snap4b.delegations[0].status, DelegationStatus::Working);
    assert!(snap4b.delegations[0].current_review.is_none());
    assert_eq!(
        snap4b.delegations[0].submitted_milestone_id.as_deref(),
        Some("02")
    );

    // Complete
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Complete,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("complete delegation");

    let snap5 = runtime.app_snapshot().expect("snapshot after complete");
    assert!(snap5.delegations.is_empty());
}

#[test]
fn delegation_review_ready_is_suppressed_while_resume_pending_for_same_milestone() {
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
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready 01");
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("submit review 01");

    let outcome = runtime
        .mutate_delegation(review_ready_command("01"))
        .expect("mutation outcome");

    assert!(!outcome.ok, "same milestone should be suppressed");
    assert_eq!(outcome.message, "review suppressed during resume_pending");
}

#[test]
fn delegation_review_ready_accepts_newer_milestone_while_resume_pending() {
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
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready 01");
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::RequestChanges),
            note: Some("Fix the error handling".to_string()),
            ..start_command()
        })
        .expect("submit review 01");

    runtime
        .mutate_delegation(review_ready_command("02"))
        .expect("review ready 02 while pending");

    let snapshot = runtime.app_snapshot().expect("snapshot");
    let delegation = &snapshot.delegations[0];
    assert_eq!(delegation.status, DelegationStatus::ReviewNeeded);
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|r| r.milestone_id.as_str()),
        Some("02")
    );
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
}

#[test]
fn delegation_submit_review_without_current_review_is_rejected() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_delegation(start_command())
        .expect("start delegation");

    let outcome = runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("mutation outcome");

    assert!(!outcome.ok, "submit should require an active review");
    assert_eq!(
        outcome.message,
        "delegation status must be review_needed or resume_failed"
    );
}

#[test]
fn delegation_resume_requires_resume_pending_status() {
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
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready 01");

    let outcome = runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::Resume,
            session_id: Some("session-123".to_string()),
            ..start_command()
        })
        .expect("mutation outcome");

    assert!(!outcome.ok, "resume should require ResumePending");
    assert_eq!(outcome.message, "delegation resume is not pending");
}

#[test]
fn delegation_resume_failed_preserves_review_context_for_retry() {
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
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready 01");
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("submit review 01");

    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::ResumeFailed,
            session_id: Some("session-123".to_string()),
            note: Some("launcher exited non-zero".to_string()),
            ..start_command()
        })
        .expect("mark resume failed");

    let snapshot = runtime.app_snapshot().expect("snapshot after failure");
    let delegation = &snapshot.delegations[0];
    assert_eq!(delegation.status, DelegationStatus::ResumeFailed);
    assert!(
        delegation.current_review.is_some(),
        "resume failures should keep the user-facing review receipt available",
    );
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
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
        .mutate_delegation(review_ready_command("01"))
        .expect("review ready");
    runtime
        .mutate_delegation(MutateDelegationCommand {
            kind: DelegationMutationKind::SubmitReview,
            session_id: Some("session-123".to_string()),
            review_decision: Some(DelegationReviewDecision::Approve),
            note: Some("Ship it".to_string()),
            ..start_command()
        })
        .expect("submit review");

    drop(runtime);

    let recovered =
        CoreRuntime::new_with_snapshot_file(snapshot_path.to_string_lossy().to_string())
            .expect("recovered runtime");
    let snapshot = recovered.app_snapshot().expect("snapshot");

    assert_eq!(snapshot.delegations.len(), 1);
    assert_eq!(
        snapshot.delegations[0].status,
        DelegationStatus::ResumePending
    );
    assert_eq!(
        snapshot.delegations[0]
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01"),
    );
    assert_eq!(
        snapshot.delegations[0].submitted_milestone_id.as_deref(),
        Some("01"),
    );
}
