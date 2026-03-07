use crate::runtime_storage::StorageConfig;

use super::domain::{ActivationDecision, ActivationRequest};
use super::ports::{ActivationPortError, ActivationRoutingPort, TerminalActivationPort};

pub(crate) struct LiveActivationAdapter {
    app_storage: StorageConfig,
}

impl LiveActivationAdapter {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl ActivationRoutingPort for LiveActivationAdapter {
    fn resolve_route(
        &self,
        request: &ActivationRequest,
    ) -> Result<ActivationDecision, ActivationPortError> {
        let _ = (&self.app_storage, request);
        Err(ActivationPortError::Unimplemented)
    }
}

impl TerminalActivationPort for LiveActivationAdapter {
    fn activate(&self, decision: &ActivationDecision) -> Result<(), ActivationPortError> {
        let _ = (&self.app_storage, decision);
        Err(ActivationPortError::Unimplemented)
    }
}
