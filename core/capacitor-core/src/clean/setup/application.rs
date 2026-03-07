use std::sync::Arc;

use super::domain::{SetupPlan, SetupReadiness};
use super::ports::{SetupInspectorPort, SetupMutatorPort, SetupPortError};
use crate::runtime_setup::{DependencyStatus, HookStatus, SetupStatus};
use crate::runtime_types::{HookDiagnosticReport, HookHealthReport};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum SetupServiceError {
    #[error(transparent)]
    Port(#[from] SetupPortError),
    #[error("setup shell is not implemented")]
    Unimplemented,
}

pub(crate) struct SetupService {
    inspector: Arc<dyn SetupInspectorPort>,
    mutator: Arc<dyn SetupMutatorPort>,
}

impl SetupService {
    pub(crate) fn new(
        inspector: Arc<dyn SetupInspectorPort>,
        mutator: Arc<dyn SetupMutatorPort>,
    ) -> Self {
        Self { inspector, mutator }
    }

    pub(crate) fn check_setup_readiness(&self) -> Result<SetupReadiness, SetupServiceError> {
        self.inspector.check_readiness().map_err(Into::into)
    }

    pub(crate) fn load_setup_status(&self) -> SetupStatus {
        self.inspector.check_setup_status()
    }

    pub(crate) fn check_dependency(&self, name: &str) -> DependencyStatus {
        self.inspector.check_dependency(name)
    }

    pub(crate) fn load_hook_status(&self) -> HookStatus {
        self.inspector.get_hook_status()
    }

    pub(crate) fn load_hook_health(&self) -> HookHealthReport {
        self.inspector.check_hook_health()
    }

    pub(crate) fn load_hook_diagnostic(&self) -> HookDiagnosticReport {
        self.inspector.get_hook_diagnostic()
    }

    pub(crate) fn build_setup_plan(&self) -> Result<SetupPlan, SetupServiceError> {
        let _ = (&self.inspector, &self.mutator);
        todo!("Shell scaffold only")
    }

    pub(crate) fn install_hook_bundle(&self, plan: &SetupPlan) -> Result<(), SetupServiceError> {
        let _ = (&self.inspector, &self.mutator, plan);
        todo!("Shell scaffold only")
    }
}
