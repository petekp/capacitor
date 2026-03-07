use std::sync::Arc;

use super::domain::{ActivationDecision, ActivationRequest};
use super::ports::{ActivationPortError, ActivationRoutingPort, TerminalActivationPort};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ActivationServiceError {
    #[error(transparent)]
    Port(#[from] ActivationPortError),
    #[error("activation shell is not implemented")]
    Unimplemented,
}

pub(crate) struct ActivationService {
    router: Arc<dyn ActivationRoutingPort>,
    activator: Arc<dyn TerminalActivationPort>,
}

impl ActivationService {
    pub(crate) fn new(
        router: Arc<dyn ActivationRoutingPort>,
        activator: Arc<dyn TerminalActivationPort>,
    ) -> Self {
        Self { router, activator }
    }

    pub(crate) fn resolve_activation(
        &self,
        request: &ActivationRequest,
    ) -> Result<ActivationDecision, ActivationServiceError> {
        let _ = (&self.router, &self.activator, request);
        todo!("Shell scaffold only")
    }

    pub(crate) fn activate_project_terminal(
        &self,
        request: &ActivationRequest,
    ) -> Result<ActivationDecision, ActivationServiceError> {
        let _ = (&self.router, &self.activator, request);
        todo!("Shell scaffold only")
    }
}
