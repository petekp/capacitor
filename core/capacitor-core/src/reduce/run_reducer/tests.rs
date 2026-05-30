use super::*;
use crate::domain::{
    CheckpointDecisionRelay, CheckpointKind, InvolvementLevel, MediaArtifact, MermaidSource,
};

fn empty_runs() -> BTreeMap<String, RunState> {
    BTreeMap::new()
}

/// Test-only discriminant mirroring the pre-refactor `RunMutationKind` unit
/// variants. The reducer's [`RunMutationKind`] now carries per-kind payloads;
/// [`CommandBuilder`] projects the flat builder fields into the matching real
/// variant at `mutate(...)` time so these tests keep their flat ergonomics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // full discriminant set; not every variant is exercised here
enum Kind {
    Create,
    Start,
    Heartbeat,
    AdvancePhase,
    EmitCheckpoint,
    SubmitDecision,
    AttachSession,
    DetachSession,
    CaptureClaim,
    CaptureFailed,
    CaptureComplete,
    Pause,
    Resume,
    Complete,
    Fail,
    Cancel,
}

/// Flat builder mirroring the pre-refactor `MutateRunCommand` field set so the
/// reducer unit tests keep mutating individual fields before picking a kind.
#[derive(Debug, Clone, Default)]
struct CommandBuilder {
    project_path: String,
    run_id: String,
    method_id: Option<String>,
    involvement: Option<InvolvementLevel>,
    checkpoint_kind: Option<CheckpointKind>,
    checkpoint_title: Option<String>,
    checkpoint_summary: Option<String>,
    checkpoint_brief_path: Option<String>,
    checkpoint_manifest_path: Option<String>,
    checkpoint_media_artifacts: Vec<MediaArtifact>,
    checkpoint_mermaid_sources: Vec<MermaidSource>,
    checkpoint_decision_relay: Option<CheckpointDecisionRelay>,
    capture_url: Option<String>,
    checkpoint_id: Option<String>,
    capture_request_id: Option<String>,
    client_id: Option<String>,
    observed_capture_url: Option<String>,
    capture_failure_reason: Option<String>,
    decision_action: Option<String>,
    decision_note: Option<String>,
    session_id: Option<String>,
    delegation_worker_id: Option<String>,
    status_message: Option<String>,
    idea_id: Option<String>,
    idea_title: Option<String>,
    idea_description: Option<String>,
    completed_media_artifacts: Vec<MediaArtifact>,
}

impl CommandBuilder {
    fn into_command(self, kind: Kind) -> MutateRunCommand {
        let payload = match kind {
            Kind::Create => RunMutationKind::Create {
                method_id: self.method_id,
                involvement: self.involvement,
                delegation_worker_id: self.delegation_worker_id,
                idea_id: self.idea_id,
                idea_title: self.idea_title,
                idea_description: self.idea_description,
            },
            Kind::Start => RunMutationKind::Start {
                status_message: self.status_message,
            },
            Kind::Heartbeat => RunMutationKind::Heartbeat {
                status_message: self.status_message,
            },
            Kind::AdvancePhase => RunMutationKind::AdvancePhase,
            Kind::EmitCheckpoint => RunMutationKind::EmitCheckpoint {
                checkpoint_kind: self.checkpoint_kind,
                checkpoint_title: self.checkpoint_title,
                checkpoint_summary: self.checkpoint_summary,
                checkpoint_brief_path: self.checkpoint_brief_path,
                checkpoint_manifest_path: self.checkpoint_manifest_path,
                checkpoint_media_artifacts: self.checkpoint_media_artifacts,
                checkpoint_mermaid_sources: self.checkpoint_mermaid_sources,
                checkpoint_decision_relay: self.checkpoint_decision_relay,
                capture_url: self.capture_url,
                checkpoint_id: self.checkpoint_id,
            },
            Kind::SubmitDecision => RunMutationKind::SubmitDecision {
                checkpoint_id: self.checkpoint_id,
                decision_action: self.decision_action,
                decision_note: self.decision_note,
            },
            Kind::AttachSession => RunMutationKind::AttachSession {
                session_id: self.session_id,
                delegation_worker_id: self.delegation_worker_id,
            },
            Kind::DetachSession => RunMutationKind::DetachSession,
            Kind::CaptureClaim => RunMutationKind::CaptureClaim {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                client_id: self.client_id,
                observed_capture_url: self.observed_capture_url,
            },
            Kind::CaptureFailed => RunMutationKind::CaptureFailed {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                capture_failure_reason: self.capture_failure_reason,
            },
            Kind::CaptureComplete => RunMutationKind::CaptureComplete {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                completed_media_artifacts: self.completed_media_artifacts,
            },
            Kind::Pause => RunMutationKind::Pause {
                status_message: self.status_message,
            },
            Kind::Resume => RunMutationKind::Resume {
                status_message: self.status_message,
            },
            Kind::Complete => RunMutationKind::Complete {
                status_message: self.status_message,
            },
            Kind::Fail => RunMutationKind::Fail {
                status_message: self.status_message,
            },
            Kind::Cancel => RunMutationKind::Cancel {
                status_message: self.status_message,
            },
        };
        MutateRunCommand {
            project_path: self.project_path,
            run_id: self.run_id,
            kind: payload,
        }
    }
}

fn create_command(run_id: &str, method_id: &str) -> CommandBuilder {
    CommandBuilder {
        project_path: "/test/project".to_string(),
        run_id: run_id.to_string(),
        method_id: Some(method_id.to_string()),
        ..CommandBuilder::default()
    }
}

fn mutate(
    runs: &mut BTreeMap<String, RunState>,
    cmd: CommandBuilder,
    kind: Kind,
) -> MutationOutcome {
    apply_run_mutation(runs, cmd.into_command(kind))
}

fn base_cmd(run_id: &str) -> CommandBuilder {
    CommandBuilder {
        project_path: "/test/project".to_string(),
        run_id: run_id.to_string(),
        ..CommandBuilder::default()
    }
}

fn attach_session(runs: &mut BTreeMap<String, RunState>, run_id: &str) {
    let mut cmd = base_cmd(run_id);
    cmd.session_id = Some("s1".to_string());
    let result = mutate(runs, cmd, Kind::AttachSession);
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
    let result = mutate(runs, cmd, Kind::EmitCheckpoint);
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
    mutate(runs, cmd, Kind::CaptureClaim)
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
