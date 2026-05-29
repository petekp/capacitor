#![allow(dead_code)]

use std::io::Read;
use std::time::{Duration, Instant};

use capacitor_core::domain::{
    CheckpointDecisionRelay, CheckpointKind, HookEventType, IngestHookEventCommand,
    InvolvementLevel, MediaArtifact, MermaidSource, MutateRunCommand,
    RunMutationKind as RealRunMutationKind,
};
use capacitor_core::CoreRuntime;

pub mod fixtures;

/// Test-only discriminant for run mutations.
///
/// Production code carries the per-kind payload inside
/// [`capacitor_core::domain::RunMutationKind`] (a sum type). The run-kernel
/// integration tests historically build a flat [`RunCommandBuilder`], set
/// individual fields, then pick the kind at `mutate(...)` time. This bare
/// discriminant preserves that ergonomic without re-spelling the payload at
/// every call site; `RunCommandBuilder::into_command` projects the flat fields
/// into the matching real variant.
///
/// Re-exported as `RunMutationKind` so existing `RunMutationKind::Create` call
/// sites keep compiling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunMutationKind {
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

/// Flat run-mutation builder used by the run-kernel integration tests.
///
/// Mirrors the pre-refactor flat `MutateRunCommand` field set so existing test
/// bodies (`cmd.checkpoint_kind = Some(..)`, `cmd.session_id = Some(..)`, …)
/// keep working. [`RunCommandBuilder::into_command`] projects these flat fields
/// into the real sum-type variant selected by [`RunMutationKind`].
#[derive(Debug, Clone, Default)]
pub struct RunCommandBuilder {
    pub project_path: String,
    pub run_id: String,
    pub method_id: Option<String>,
    pub involvement: Option<InvolvementLevel>,
    pub checkpoint_kind: Option<CheckpointKind>,
    pub checkpoint_title: Option<String>,
    pub checkpoint_summary: Option<String>,
    pub checkpoint_brief_path: Option<String>,
    pub checkpoint_manifest_path: Option<String>,
    pub checkpoint_media_artifacts: Vec<MediaArtifact>,
    pub checkpoint_mermaid_sources: Vec<MermaidSource>,
    pub checkpoint_decision_relay: Option<CheckpointDecisionRelay>,
    pub capture_url: Option<String>,
    pub checkpoint_id: Option<String>,
    pub capture_request_id: Option<String>,
    pub client_id: Option<String>,
    pub observed_capture_url: Option<String>,
    pub capture_failure_reason: Option<String>,
    pub decision_action: Option<String>,
    pub decision_note: Option<String>,
    pub session_id: Option<String>,
    pub delegation_worker_id: Option<String>,
    pub status_message: Option<String>,
    pub idea_id: Option<String>,
    pub idea_title: Option<String>,
    pub idea_description: Option<String>,
    pub completed_media_artifacts: Vec<MediaArtifact>,
}

impl RunCommandBuilder {
    /// Project the flat builder into the real [`MutateRunCommand`] sum type using
    /// `kind` to select the variant and which flat fields to carry.
    pub fn into_command(self, kind: RunMutationKind) -> MutateRunCommand {
        let payload = match kind {
            RunMutationKind::Create => RealRunMutationKind::Create {
                method_id: self.method_id,
                involvement: self.involvement,
                delegation_worker_id: self.delegation_worker_id,
                idea_id: self.idea_id,
                idea_title: self.idea_title,
                idea_description: self.idea_description,
            },
            RunMutationKind::Start => RealRunMutationKind::Start {
                status_message: self.status_message,
            },
            RunMutationKind::Heartbeat => RealRunMutationKind::Heartbeat {
                status_message: self.status_message,
            },
            RunMutationKind::AdvancePhase => RealRunMutationKind::AdvancePhase,
            RunMutationKind::EmitCheckpoint => RealRunMutationKind::EmitCheckpoint {
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
            RunMutationKind::SubmitDecision => RealRunMutationKind::SubmitDecision {
                checkpoint_id: self.checkpoint_id,
                decision_action: self.decision_action,
                decision_note: self.decision_note,
            },
            RunMutationKind::AttachSession => RealRunMutationKind::AttachSession {
                session_id: self.session_id,
                delegation_worker_id: self.delegation_worker_id,
            },
            RunMutationKind::DetachSession => RealRunMutationKind::DetachSession,
            RunMutationKind::CaptureClaim => RealRunMutationKind::CaptureClaim {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                client_id: self.client_id,
                observed_capture_url: self.observed_capture_url,
            },
            RunMutationKind::CaptureFailed => RealRunMutationKind::CaptureFailed {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                capture_failure_reason: self.capture_failure_reason,
            },
            RunMutationKind::CaptureComplete => RealRunMutationKind::CaptureComplete {
                checkpoint_id: self.checkpoint_id,
                capture_request_id: self.capture_request_id,
                completed_media_artifacts: self.completed_media_artifacts,
            },
            RunMutationKind::Pause => RealRunMutationKind::Pause {
                status_message: self.status_message,
            },
            RunMutationKind::Resume => RealRunMutationKind::Resume {
                status_message: self.status_message,
            },
            RunMutationKind::Complete => RealRunMutationKind::Complete {
                status_message: self.status_message,
            },
            RunMutationKind::Fail => RealRunMutationKind::Fail {
                status_message: self.status_message,
            },
            RunMutationKind::Cancel => RealRunMutationKind::Cancel {
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

pub fn valid_hook_event_command(event_type: HookEventType) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2099-02-28T19:00:00Z".to_string(),
        event_type,
        session_id: "session-1".to_string(),
        pid: Some(4242),
        project_path: "/tmp/core-project".to_string(),
        cwd: Some("/tmp/core-project".to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    }
}

pub fn read_http_request(stream: &mut std::net::TcpStream) -> String {
    let mut request = Vec::new();
    let mut headers_end = None;
    let mut content_length = 0usize;
    let deadline = Instant::now() + Duration::from_secs(2);

    loop {
        let mut buf = [0u8; 4096];
        let read = match stream.read(&mut buf) {
            Ok(read) => read,
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::TimedOut =>
            {
                if Instant::now() >= deadline {
                    panic!("timed out reading request: {error}");
                }
                std::thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => panic!("read request: {error}"),
        };
        if read == 0 {
            break;
        }
        request.extend_from_slice(&buf[..read]);

        if headers_end.is_none() {
            if let Some(end) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                let end = end + 4;
                headers_end = Some(end);
                let headers = String::from_utf8_lossy(&request[..end]);
                content_length = headers
                    .lines()
                    .find_map(|line| {
                        let line = line.trim_end_matches('\r');
                        let (name, value) = line.split_once(':')?;
                        if name.eq_ignore_ascii_case("Content-Length") {
                            value.trim().parse::<usize>().ok()
                        } else {
                            None
                        }
                    })
                    .unwrap_or(0);
            }
        }

        if let Some(headers_end) = headers_end {
            let body_len = request.len().saturating_sub(headers_end);
            if body_len >= content_length {
                break;
            }
        }
    }

    String::from_utf8(request).expect("request should be valid utf-8")
}

pub fn run_kernel_base_cmd(project_path: &str, run_id: &str) -> RunCommandBuilder {
    RunCommandBuilder {
        project_path: project_path.to_string(),
        run_id: run_id.to_string(),
        ..RunCommandBuilder::default()
    }
}

pub fn run_kernel_create_cmd(
    project_path: &str,
    run_id: &str,
    method_id: &str,
) -> RunCommandBuilder {
    let mut command = run_kernel_base_cmd(project_path, run_id);
    command.method_id = Some(method_id.to_string());
    command
}

pub fn mutate_run(
    runtime: &CoreRuntime,
    command: RunCommandBuilder,
    kind: RunMutationKind,
) -> capacitor_core::domain::MutationOutcome {
    runtime
        .mutate_run(command.into_command(kind))
        .expect("mutation should not error")
}

pub fn active_checkpoint_id(runtime: &CoreRuntime, run_id: &str) -> String {
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
