use crate::clean::activation::domain::{ActivationDecision, ActivationRequest};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ActivationPortError {
    #[error("activation shell is not implemented")]
    Unimplemented,
}

pub(crate) trait ActivationRoutingPort: Send + Sync {
    fn resolve_route(
        &self,
        request: &ActivationRequest,
    ) -> Result<ActivationDecision, ActivationPortError>;
}

pub(crate) trait TerminalActivationPort: Send + Sync {
    fn activate(&self, decision: &ActivationDecision) -> Result<(), ActivationPortError>;
}
