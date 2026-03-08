use std::sync::Arc;

use crate::domain::AppSnapshot;
use crate::runtime_setup::{DependencyStatus, HookStatus, SetupStatus};
use crate::runtime_storage::StorageConfig;
use crate::runtime_types::{
    HookDiagnosticReport, HookHealthReport, HookHealthStatus, HookTestResult,
};
use crate::storage::SnapshotStorage;

use super::ideas::{
    application::IdeaService,
    infrastructure::{LiveIdeaRepository, LiveWorktreePort},
};
use super::projects::{
    application::ProjectCatalogService,
    infrastructure::{LiveProjectCatalogStore, LiveWorkspaceInspector},
};
use super::runtime::{
    application::RuntimeService,
    infrastructure::{LiveRuntimeIngressPort, LiveRuntimeSnapshotStore},
};
use super::setup::{
    application::SetupService,
    infrastructure::{LiveSetupInspector, LiveSetupMutator},
};

pub(crate) struct CleanArchitectureShell {
    pub(crate) runtime: RuntimeService,
    pub(crate) setup: SetupService,
    pub(crate) projects: ProjectCatalogService,
    pub(crate) ideas: IdeaService,
}

impl CleanArchitectureShell {
    pub(crate) fn bootstrap(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Self {
        let runtime_snapshot_store =
            Arc::new(LiveRuntimeSnapshotStore::new(Arc::clone(&snapshot_storage)));
        let runtime_ingress = Arc::new(LiveRuntimeIngressPort::new(
            Arc::clone(&snapshot_storage),
            app_storage.clone(),
        ));
        let setup_inspector = Arc::new(LiveSetupInspector::new(app_storage.clone()));
        let setup_mutator = Arc::new(LiveSetupMutator::new(app_storage.clone()));
        let project_catalog_store = Arc::new(LiveProjectCatalogStore::new(app_storage.clone()));
        let workspace_inspector = Arc::new(LiveWorkspaceInspector::new(app_storage.clone()));
        let idea_repository = Arc::new(LiveIdeaRepository::new(app_storage.clone()));
        let worktree_port = Arc::new(LiveWorktreePort::new(app_storage.clone()));

        Self {
            runtime: RuntimeService::new(runtime_snapshot_store, runtime_ingress),
            setup: SetupService::new(setup_inspector, setup_mutator),
            projects: ProjectCatalogService::new(project_catalog_store, workspace_inspector),
            ideas: IdeaService::new(idea_repository, worktree_port),
        }
    }

    pub(crate) fn app_snapshot(
        &self,
    ) -> Result<AppSnapshot, super::runtime::application::RuntimeServiceError> {
        self.runtime.load_app_snapshot()
    }

    pub(crate) fn check_setup_status(&self) -> SetupStatus {
        self.setup.load_setup_status()
    }

    pub(crate) fn check_dependency(&self, name: &str) -> DependencyStatus {
        self.setup.check_dependency(name)
    }

    pub(crate) fn get_hook_status(&self) -> HookStatus {
        self.setup.load_hook_status()
    }

    pub(crate) fn check_hook_health(&self) -> HookHealthReport {
        self.setup.load_hook_health()
    }

    pub(crate) fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
        self.setup.load_hook_diagnostic()
    }

    pub(crate) fn run_hook_test(&self) -> HookTestResult {
        let health = self.setup.load_hook_health();
        let heartbeat_ok = matches!(health.status, HookHealthStatus::Healthy);
        let heartbeat_age = health.last_heartbeat_age_secs;
        let state_file_ok = self
            .runtime
            .read_runtime_health()
            .map(|health| health.snapshot_authoritative)
            .unwrap_or(false);
        let success = heartbeat_ok && state_file_ok;
        let message = if success {
            "Hooks are working correctly".to_string()
        } else if !heartbeat_ok {
            match heartbeat_age {
                Some(age) => format!(
                    "Heartbeat stale ({}s ago). Start a Claude session to test.",
                    age
                ),
                None => "No heartbeat detected. Start a Claude session to test hooks.".to_string(),
            }
        } else {
            "Runtime health check failed. Ensure the runtime snapshot is available.".to_string()
        };

        HookTestResult {
            success,
            heartbeat_ok,
            heartbeat_age_secs: heartbeat_age,
            state_file_ok,
            message,
        }
    }
}
