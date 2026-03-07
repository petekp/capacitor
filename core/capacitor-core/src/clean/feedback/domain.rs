use crate::clean::kernel::{CorrelationId, ProjectRef, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FeedbackKind {
    Bug,
    Idea,
    Friction,
    Praise,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct FeedbackSubmission {
    pub(crate) correlation_id: CorrelationId,
    pub(crate) project: Option<ProjectRef>,
    pub(crate) kind: Option<FeedbackKind>,
    pub(crate) summary: String,
    pub(crate) submitted_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TelemetryField {
    pub(crate) key: String,
    pub(crate) value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TelemetryEvent {
    pub(crate) correlation_id: CorrelationId,
    pub(crate) name: String,
    pub(crate) fields: Vec<TelemetryField>,
    pub(crate) recorded_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct FeedbackReceipt {
    pub(crate) correlation_id: CorrelationId,
    pub(crate) accepted_at: Timestamp,
}
