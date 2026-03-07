use crate::clean::feedback::domain::{FeedbackReceipt, FeedbackSubmission, TelemetryEvent};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum FeedbackPortError {
    #[error("feedback shell is not implemented")]
    Unimplemented,
}

pub(crate) trait FeedbackSinkPort: Send + Sync {
    fn submit_feedback(
        &self,
        submission: &FeedbackSubmission,
    ) -> Result<FeedbackReceipt, FeedbackPortError>;
}

pub(crate) trait TelemetrySinkPort: Send + Sync {
    fn record_event(&self, event: &TelemetryEvent) -> Result<(), FeedbackPortError>;
}
