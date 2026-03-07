use crate::clean::kernel::{CorrelationId, ProjectRef, TerminalCoordinate, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ActivationRequest {
    pub(crate) correlation_id: CorrelationId,
    pub(crate) project: ProjectRef,
    pub(crate) preferred_terminal: Option<String>,
    pub(crate) requested_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ActivationStatus {
    Routed,
    Deferred,
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ActivationDecision {
    pub(crate) request: ActivationRequest,
    pub(crate) status: Option<ActivationStatus>,
    pub(crate) route: Option<TerminalCoordinate>,
    pub(crate) reason: String,
    pub(crate) decided_at: Timestamp,
}
