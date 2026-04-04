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

fn attach_session(runs: &mut BTreeMap<String, RunState>, run_id: &str) {
    let mut cmd = base_cmd(run_id);
    cmd.session_id = Some("s1".to_string());
    let result = mutate(runs, cmd, RunMutationKind::AttachSession);
    assert!(result.ok, "{}", result.message);
}

fn emit_pending_checkpoint(
    runs: &mut BTreeMap<String, RunState>,
    run_id: &str,
    capture_url: &str,
) -> String {
    let mut cmd = base_cmd(run_id);
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.capture_url = Some(capture_url.to_string());
    let result = mutate(runs, cmd, RunMutationKind::EmitCheckpoint);
    assert!(result.ok, "{}", result.message);

    runs.values()
        .next()
        .expect("run exists")
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists")
        .id
        .clone()
}

fn claim_capture(
    runs: &mut BTreeMap<String, RunState>,
    run_id: &str,
    checkpoint_id: &str,
    capture_request_id: &str,
) -> MutationOutcome {
    let mut cmd = base_cmd(run_id);
    cmd.checkpoint_id = Some(checkpoint_id.to_string());
    cmd.capture_request_id = Some(capture_request_id.to_string());
    cmd.client_id = Some("client-1".to_string());
    cmd.observed_capture_url = Some(" http://localhost:4173 ".to_string());
    mutate(runs, cmd, RunMutationKind::CaptureClaim)
}

fn active_checkpoint_id(runs: &BTreeMap<String, RunState>, run_id: &str) -> String {
    runs.values()
        .find(|run| run.id == run_id)
        .expect("run exists")
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists")
        .id
        .clone()
}

mod capture;
mod lifecycle;
mod start_heartbeat;
