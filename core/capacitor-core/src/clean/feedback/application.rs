use std::sync::Arc;

use super::domain::{FeedbackReceipt, FeedbackSubmission, TelemetryEvent};
use super::ports::{FeedbackPortError, FeedbackSinkPort, TelemetrySinkPort};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum FeedbackServiceError {
    #[error(transparent)]
    Port(#[from] FeedbackPortError),
    #[error("feedback shell is not implemented")]
    Unimplemented,
}

pub(crate) struct FeedbackService {
    feedback_sink: Arc<dyn FeedbackSinkPort>,
    telemetry_sink: Arc<dyn TelemetrySinkPort>,
}

impl FeedbackService {
    pub(crate) fn new(
        feedback_sink: Arc<dyn FeedbackSinkPort>,
        telemetry_sink: Arc<dyn TelemetrySinkPort>,
    ) -> Self {
        Self {
            feedback_sink,
            telemetry_sink,
        }
    }

    pub(crate) fn submit_quick_feedback(
        &self,
        submission: &FeedbackSubmission,
    ) -> Result<FeedbackReceipt, FeedbackServiceError> {
        let _ = (&self.feedback_sink, &self.telemetry_sink, submission);
        todo!("Shell scaffold only")
    }

    pub(crate) fn record_telemetry_event(
        &self,
        event: &TelemetryEvent,
    ) -> Result<(), FeedbackServiceError> {
        let _ = (&self.feedback_sink, &self.telemetry_sink, event);
        todo!("Shell scaffold only")
    }
}
