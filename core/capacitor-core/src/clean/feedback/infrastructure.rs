use crate::runtime_storage::StorageConfig;

use super::domain::{FeedbackReceipt, FeedbackSubmission, TelemetryEvent};
use super::ports::{FeedbackPortError, FeedbackSinkPort, TelemetrySinkPort};

pub(crate) struct LiveFeedbackSink {
    app_storage: StorageConfig,
}

impl LiveFeedbackSink {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl FeedbackSinkPort for LiveFeedbackSink {
    fn submit_feedback(
        &self,
        submission: &FeedbackSubmission,
    ) -> Result<FeedbackReceipt, FeedbackPortError> {
        let _ = (&self.app_storage, submission);
        Err(FeedbackPortError::Unimplemented)
    }
}

pub(crate) struct LiveTelemetrySink {
    app_storage: StorageConfig,
}

impl LiveTelemetrySink {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl TelemetrySinkPort for LiveTelemetrySink {
    fn record_event(&self, event: &TelemetryEvent) -> Result<(), FeedbackPortError> {
        let _ = (&self.app_storage, event);
        Err(FeedbackPortError::Unimplemented)
    }
}
