use crate::clean::setup::domain::{SetupPlan, SetupReadiness};
use crate::runtime_setup::{DependencyStatus, HookStatus, InstallResult, SetupStatus};
use crate::runtime_types::{HookDiagnosticReport, HookHealthReport};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum SetupPortError {
    #[error("setup shell is not implemented")]
    Unimplemented,
    #[error("{0}")]
    Message(String),
}

impl From<String> for SetupPortError {
    fn from(value: String) -> Self {
        Self::Message(value)
    }
}

pub(crate) trait SetupInspectorPort: Send + Sync {
    fn check_readiness(&self) -> Result<SetupReadiness, SetupPortError>;
    fn check_setup_status(&self) -> SetupStatus;
    fn check_dependency(&self, name: &str) -> DependencyStatus;
    fn get_hook_status(&self) -> HookStatus;
    fn check_hook_health(&self) -> HookHealthReport;
    fn get_hook_diagnostic(&self) -> HookDiagnosticReport;
}

pub(crate) trait SetupMutatorPort: Send + Sync {
    fn build_plan(&self) -> Result<SetupPlan, SetupPortError>;
    fn install_hook_bundle(&self, plan: &SetupPlan) -> Result<(), SetupPortError>;
    fn install_binary_from_path(&self, source_path: &str) -> Result<InstallResult, SetupPortError>;
    fn install_hooks(&self) -> Result<InstallResult, SetupPortError>;
    fn remove_hooks(&self) -> Result<InstallResult, SetupPortError>;
}
