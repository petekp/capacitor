use std::sync::Arc;

use super::domain::{SetupPlan, SetupReadiness};
use super::ports::{SetupInspectorPort, SetupMutatorPort, SetupPortError};
use crate::runtime_setup::{DependencyStatus, HookStatus, InstallResult, SetupStatus};
use crate::runtime_types::{HookDiagnosticReport, HookHealthReport};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum SetupServiceError {
    #[error(transparent)]
    Port(#[from] SetupPortError),
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
        self.mutator.build_plan().map_err(Into::into)
    }

    pub(crate) fn install_hook_bundle(&self, plan: &SetupPlan) -> Result<(), SetupServiceError> {
        self.mutator.install_hook_bundle(plan).map_err(Into::into)
    }

    pub(crate) fn install_binary_from_path(
        &self,
        source_path: &str,
    ) -> Result<InstallResult, SetupServiceError> {
        self.mutator
            .install_binary_from_path(source_path)
            .map_err(Into::into)
    }

    pub(crate) fn install_hooks(&self) -> Result<InstallResult, SetupServiceError> {
        self.mutator.install_hooks().map_err(Into::into)
    }

    pub(crate) fn remove_hooks(&self) -> Result<InstallResult, SetupServiceError> {
        self.mutator.remove_hooks().map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::clean::kernel::Timestamp;
    use crate::clean::setup::domain::{SetupAction, SetupRequirement, SetupRequirementKind};

    #[derive(Default)]
    struct StubSetupInspector;

    impl SetupInspectorPort for StubSetupInspector {
        fn check_readiness(&self) -> Result<SetupReadiness, SetupPortError> {
            Ok(SetupReadiness {
                ready: false,
                requirements: vec![SetupRequirement {
                    kind: Some(SetupRequirementKind::HookBinary),
                    satisfied: false,
                    detail: Some("missing".to_string()),
                }],
                checked_at: Timestamp("2026-03-08T00:00:00Z".to_string()),
            })
        }

        fn check_setup_status(&self) -> SetupStatus {
            SetupStatus {
                dependencies: vec![],
                hooks: HookStatus::NotInstalled,
                storage_ready: true,
                all_ready: false,
                blocking_reason: Some("missing".to_string()),
            }
        }

        fn check_dependency(&self, name: &str) -> DependencyStatus {
            DependencyStatus {
                name: name.to_string(),
                required: true,
                found: false,
                path: None,
                install_hint: Some("install".to_string()),
            }
        }

        fn get_hook_status(&self) -> HookStatus {
            HookStatus::NotInstalled
        }

        fn check_hook_health(&self) -> HookHealthReport {
            HookHealthReport {
                status: crate::runtime_types::HookHealthStatus::Unknown,
                heartbeat_path: "/tmp/heartbeat".to_string(),
                threshold_secs: 60,
                last_heartbeat_age_secs: None,
            }
        }

        fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
            HookDiagnosticReport {
                is_healthy: false,
                primary_issue: Some(crate::runtime_types::HookIssue::BinaryMissing),
                can_auto_fix: true,
                is_first_run: true,
                binary_ok: false,
                config_ok: false,
                firing_ok: false,
                symlink_path: "/tmp/hud-hook".to_string(),
                symlink_target: None,
                last_heartbeat_age_secs: None,
            }
        }
    }

    #[derive(Default)]
    struct StubSetupMutator {
        installed_paths: Mutex<Vec<String>>,
        install_hooks_count: Mutex<u32>,
        remove_hooks_count: Mutex<u32>,
        installed_bundles: Mutex<Vec<Vec<SetupAction>>>,
    }

    impl SetupMutatorPort for StubSetupMutator {
        fn build_plan(&self) -> Result<SetupPlan, SetupPortError> {
            Ok(SetupPlan {
                actions: vec![SetupAction::InstallHookBinary, SetupAction::InstallHooks],
                generated_at: Timestamp("2026-03-08T00:00:00Z".to_string()),
            })
        }

        fn install_hook_bundle(&self, plan: &SetupPlan) -> Result<(), SetupPortError> {
            self.installed_bundles
                .lock()
                .expect("installed bundles")
                .push(plan.actions.clone());
            Ok(())
        }

        fn install_binary_from_path(
            &self,
            source_path: &str,
        ) -> Result<InstallResult, SetupPortError> {
            self.installed_paths
                .lock()
                .expect("installed paths")
                .push(source_path.to_string());
            Ok(InstallResult {
                success: true,
                message: "installed binary".to_string(),
                script_path: Some(source_path.to_string()),
            })
        }

        fn install_hooks(&self) -> Result<InstallResult, SetupPortError> {
            *self
                .install_hooks_count
                .lock()
                .expect("install hooks count") += 1;
            Ok(InstallResult {
                success: true,
                message: "hooks installed".to_string(),
                script_path: Some("/tmp/hud-hook".to_string()),
            })
        }

        fn remove_hooks(&self) -> Result<InstallResult, SetupPortError> {
            *self.remove_hooks_count.lock().expect("remove hooks count") += 1;
            Ok(InstallResult {
                success: true,
                message: "hooks removed".to_string(),
                script_path: Some("/tmp/settings.json".to_string()),
            })
        }
    }

    #[test]
    fn setup_service_routes_mutation_operations_through_mutator_port() {
        let mutator = Arc::new(StubSetupMutator::default());
        let service = SetupService::new(Arc::new(StubSetupInspector), mutator.clone());

        let plan = service.build_setup_plan().expect("build setup plan");
        assert_eq!(plan.actions.len(), 2);

        service
            .install_hook_bundle(&plan)
            .expect("install hook bundle");
        assert_eq!(
            mutator
                .installed_bundles
                .lock()
                .expect("installed bundles")
                .as_slice(),
            [vec![
                SetupAction::InstallHookBinary,
                SetupAction::InstallHooks
            ]],
        );

        let binary_result = service
            .install_binary_from_path("/tmp/hud-hook")
            .expect("install binary from path");
        assert!(binary_result.success);
        assert_eq!(
            mutator
                .installed_paths
                .lock()
                .expect("installed paths")
                .as_slice(),
            ["/tmp/hud-hook"],
        );

        let install_result = service.install_hooks().expect("install hooks");
        assert!(install_result.success);
        assert_eq!(
            *mutator
                .install_hooks_count
                .lock()
                .expect("install hooks count"),
            1,
        );

        let remove_result = service.remove_hooks().expect("remove hooks");
        assert!(remove_result.success);
        assert_eq!(
            *mutator
                .remove_hooks_count
                .lock()
                .expect("remove hooks count"),
            1,
        );
    }
}
