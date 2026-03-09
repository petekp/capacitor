use crate::contexts::kernel::{
    CorrelationId, ProjectRef, SessionId, TerminalCoordinate, Timestamp,
};
use crate::domain::{AppSnapshot, DiagnosticsSummary};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct RuntimeObservation {
    pub(crate) correlation_id: Option<CorrelationId>,
    pub(crate) session_id: SessionId,
    pub(crate) project: Option<ProjectRef>,
    pub(crate) terminal: Option<TerminalCoordinate>,
    pub(crate) observed_at: Timestamp,
    pub(crate) event_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct RuntimeSessionState {
    pub(crate) session_id: SessionId,
    pub(crate) project: Option<ProjectRef>,
    pub(crate) state: String,
    pub(crate) last_event: Option<String>,
    pub(crate) updated_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RuntimeProjection {
    pub(crate) correlation_id: Option<CorrelationId>,
    pub(crate) projects: Vec<ProjectRef>,
    pub(crate) sessions: Vec<RuntimeSessionState>,
    pub(crate) terminals: Vec<TerminalCoordinate>,
    pub(crate) diagnostics: DiagnosticsSummary,
    pub(crate) generated_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct RuntimeHealth {
    pub(crate) snapshot_authoritative: bool,
    pub(crate) hook_ingress_available: bool,
    pub(crate) diagnostics: Vec<String>,
    pub(crate) checked_at: Timestamp,
}

impl From<AppSnapshot> for RuntimeProjection {
    fn from(snapshot: AppSnapshot) -> Self {
        let projects = snapshot
            .projects
            .iter()
            .map(|project| ProjectRef {
                id: crate::contexts::kernel::ProjectId(project.project_id.clone()),
                workspace_id: crate::contexts::kernel::WorkspaceId(project.workspace_id.clone()),
                path: project.project_path.clone(),
                display_name: project.display_name.clone(),
            })
            .collect();

        let sessions = snapshot
            .sessions
            .iter()
            .map(|session| RuntimeSessionState {
                session_id: SessionId(session.session_id.clone()),
                project: Some(ProjectRef {
                    id: crate::contexts::kernel::ProjectId(session.project_id.clone()),
                    workspace_id: crate::contexts::kernel::WorkspaceId(
                        session.workspace_id.clone(),
                    ),
                    path: session.project_path.clone(),
                    display_name: session.project_path.clone(),
                }),
                state: match session.state {
                    crate::domain::SessionState::Working => "working",
                    crate::domain::SessionState::Ready => "ready",
                    crate::domain::SessionState::Idle => "idle",
                    crate::domain::SessionState::Compacting => "compacting",
                    crate::domain::SessionState::Waiting => "waiting",
                }
                .to_string(),
                last_event: session.last_event.clone(),
                updated_at: Timestamp(session.updated_at.clone()),
            })
            .collect();

        let terminals = snapshot
            .shells
            .iter()
            .map(|shell| TerminalCoordinate {
                application: shell.parent_app.clone(),
                tty: Some(crate::contexts::kernel::TtyHandle(shell.tty.clone())),
                tmux_session: shell.tmux_session.clone(),
            })
            .collect();

        Self {
            correlation_id: None,
            projects,
            sessions,
            terminals,
            diagnostics: snapshot.diagnostics.clone(),
            generated_at: Timestamp(snapshot.generated_at),
        }
    }
}
