use super::*;

#[test]
fn emit_checkpoint_with_media_artifacts() {
    use crate::domain::{CaptureStatus, MediaArtifact, MediaArtifactType, MermaidSource};

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
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    let result = mutate(&mut runs, cmd, Kind::CaptureComplete);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    let result = mutate(&mut runs, cmd, Kind::CaptureComplete);
    assert!(!result.ok);
    assert!(result.message.contains("not in progress"));
}

#[test]
fn emit_checkpoint_with_capture_url_auto_sets_pending() {
    use crate::domain::CaptureStatus;

    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    attach_session(&mut runs, "run-001");

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("URL capture".to_string());
    cmd.capture_url = Some("http://localhost:3000".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-001");

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.capture_url = Some("   ".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-001");
    let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", " http://localhost:3000 ");

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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-001");
    emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");

    let result = claim_capture(&mut runs, "run-001", "wrong-checkpoint", "request-1");
    assert!(!result.ok);
    assert!(result.message.contains("does not match active checkpoint"));
}

#[test]
fn capture_claim_rejects_terminal_or_non_paused_run() {
    let mut runs = empty_runs();
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
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
    let result = mutate(&mut runs, cmd, Kind::CaptureComplete);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-001");
    let checkpoint_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
    let claim = claim_capture(&mut runs, "run-001", &checkpoint_id, "request-1");
    assert!(claim.ok, "{}", claim.message);

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_id = Some(checkpoint_id);
    cmd.capture_request_id = Some("request-1".to_string());
    cmd.capture_failure_reason = Some(" browser crashed ".to_string());
    let result = mutate(&mut runs, cmd, Kind::CaptureFailed);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );
    attach_session(&mut runs, "run-001");
    let checkpoint_a_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:3000");
    let claim = claim_capture(&mut runs, "run-001", &checkpoint_a_id, "request-a");
    assert!(claim.ok, "{}", claim.message);

    let mut decision = base_cmd("run-001");
    decision.checkpoint_id = Some(checkpoint_a_id.clone());
    decision.decision_action = Some("approve".to_string());
    let decision_result = mutate(&mut runs, decision, Kind::SubmitDecision);
    assert!(decision_result.ok, "{}", decision_result.message);

    let checkpoint_b_id = emit_pending_checkpoint(&mut runs, "run-001", "http://localhost:4000");

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
    let result = mutate(&mut runs, stale_complete, Kind::CaptureComplete);
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
    apply_run_mutation(
        &mut runs,
        create_command("run-001", "execution_only").into_command(Kind::Create),
    );

    attach_session(&mut runs, "run-001");

    let mut cmd = base_cmd("run-001");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.capture_url = Some(" http://localhost:5173 ".to_string());
    let result = mutate(&mut runs, cmd, Kind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    let run = runs.values().next().unwrap();
    let ckpt = run.active_checkpoint.as_ref().unwrap();
    assert_eq!(ckpt.capture_url.as_deref(), Some("http://localhost:5173"));
}
