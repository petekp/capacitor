//! Run status reporting seam for bridging executor lifecycle into the runtime service.
//!
//! This adapter is intentionally best-effort. Reporting failures must never abort
//! a method run, because the event log on disk remains the source of truth.

use std::path::PathBuf;
use std::time::Duration;

use crate::domain::{MutateRunCommand, MutationOutcome, RunMutationKind};
use crate::runtime::service::RuntimeServiceEndpoint;

const RUNTIME_REPORT_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatusEventKind {
    Start,
    Heartbeat,
    AdvancePhase,
    Complete,
    Fail,
}

impl From<RunStatusEventKind> for RunMutationKind {
    fn from(value: RunStatusEventKind) -> Self {
        match value {
            RunStatusEventKind::Start => Self::Start,
            RunStatusEventKind::Heartbeat => Self::Heartbeat,
            RunStatusEventKind::AdvancePhase => Self::AdvancePhase,
            RunStatusEventKind::Complete => Self::Complete,
            RunStatusEventKind::Fail => Self::Fail,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunStatusEvent {
    pub kind: RunStatusEventKind,
    pub status_message: Option<String>,
}

impl RunStatusEvent {
    #[must_use]
    pub fn new(kind: RunStatusEventKind, status_message: Option<String>) -> Self {
        Self {
            kind,
            status_message,
        }
    }
}

pub trait RunStatusReporter {
    fn report(&self, event: RunStatusEvent);
}

#[derive(Debug, Default, Clone, Copy)]
pub struct NoopRunStatusReporter;

impl RunStatusReporter for NoopRunStatusReporter {
    fn report(&self, _event: RunStatusEvent) {}
}

#[derive(Debug, Clone)]
pub struct RuntimeRunStatusReporter {
    endpoint: RuntimeServiceEndpoint,
    project_path: PathBuf,
    run_id: String,
}

impl RuntimeRunStatusReporter {
    #[must_use]
    pub fn new(
        endpoint: RuntimeServiceEndpoint,
        project_path: PathBuf,
        run_id: impl Into<String>,
    ) -> Self {
        Self {
            endpoint,
            project_path,
            run_id: run_id.into(),
        }
    }

    fn command_for(&self, event: RunStatusEvent) -> MutateRunCommand {
        MutateRunCommand {
            kind: event.kind.into(),
            project_path: self.project_path.to_string_lossy().into_owned(),
            run_id: self.run_id.clone(),
            method_id: None,
            involvement: None,
            checkpoint_kind: None,
            checkpoint_title: None,
            checkpoint_summary: None,
            checkpoint_brief_path: None,
            checkpoint_manifest_path: None,
            checkpoint_media_artifacts: Vec::new(),
            checkpoint_mermaid_sources: Vec::new(),
            checkpoint_decision_relay: None,
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
            status_message: event.status_message,
            idea_id: None,
            idea_title: None,
            idea_description: None,
            completed_media_artifacts: Vec::new(),
        }
    }
}

impl RunStatusReporter for RuntimeRunStatusReporter {
    fn report(&self, event: RunStatusEvent) {
        let command = self.command_for(event.clone());
        let url = self.endpoint.run_mutate_url();
        let authorization = format!("Bearer {}", self.endpoint.auth_token());

        let agent = ureq::AgentBuilder::new()
            .timeout(RUNTIME_REPORT_TIMEOUT)
            .build();

        let response = agent
            .post(&url)
            .set("Authorization", &authorization)
            .send_json(&command);

        match response {
            Ok(response) => match response.into_json::<MutationOutcome>() {
                Ok(MutationOutcome { ok: true, .. }) => {}
                Ok(outcome) => {
                    eprintln!(
                        "warning: runtime service rejected run status {:?} for run '{}': {}",
                        event.kind, self.run_id, outcome.message
                    );
                }
                Err(error) => {
                    eprintln!(
                        "warning: failed to parse run status response {:?} for run '{}': {}",
                        event.kind, self.run_id, error
                    );
                }
            },
            Err(error) => {
                eprintln!(
                    "warning: failed to post run status {:?} for run '{}': {}",
                    event.kind, self.run_id, error
                );
            }
        }
    }
}

pub(crate) fn report_status_event(reporter: &dyn RunStatusReporter, event: RunStatusEvent) {
    let kind = event.kind;
    let message = event.status_message.clone();
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| reporter.report(event))).is_err() {
        eprintln!(
            "warning: run status reporter panicked while reporting {:?}{}",
            kind,
            message
                .as_deref()
                .map(|value| format!(" ({value})"))
                .unwrap_or_default()
        );
    }
}

pub(crate) fn report_status_message(
    reporter: &dyn RunStatusReporter,
    kind: RunStatusEventKind,
    status_message: impl Into<String>,
) {
    report_status_event(
        reporter,
        RunStatusEvent::new(kind, Some(status_message.into())),
    );
}

pub(crate) fn report_status_kind(reporter: &dyn RunStatusReporter, kind: RunStatusEventKind) {
    report_status_event(reporter, RunStatusEvent::new(kind, None));
}

#[must_use]
pub(crate) fn phase_started_message(phase_name: &str) -> String {
    format!("Phase '{phase_name}' started")
}
