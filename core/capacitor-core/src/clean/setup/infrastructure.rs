use crate::clean::setup::domain::{
    SetupAction, SetupPlan, SetupReadiness, SetupRequirement, SetupRequirementKind,
};
use crate::runtime_setup::{
    DependencyStatus, HookStatus, InstallResult, SetupChecker, SetupStatus,
};
use crate::runtime_storage::StorageConfig;
use crate::runtime_types::{HookDiagnosticReport, HookHealthReport, HookHealthStatus, HookIssue};

use super::ports::{SetupInspectorPort, SetupMutatorPort, SetupPortError};

pub(crate) struct LiveSetupInspector {
    app_storage: StorageConfig,
}

impl LiveSetupInspector {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl SetupInspectorPort for LiveSetupInspector {
    fn check_readiness(&self) -> Result<SetupReadiness, SetupPortError> {
        let status = self.check_setup_status();

        Ok(SetupReadiness {
            ready: status.all_ready,
            requirements: status
                .dependencies
                .iter()
                .map(|dependency| SetupRequirement {
                    kind: match dependency.name.as_str() {
                        "claude" => Some(SetupRequirementKind::ClaudeCli),
                        "hud-hook" => Some(SetupRequirementKind::HookBinary),
                        _ => None,
                    },
                    satisfied: dependency.found || !dependency.required,
                    detail: dependency.install_hint.clone(),
                })
                .collect(),
            checked_at: crate::clean::kernel::Timestamp(crate::domain::now_rfc3339()),
        })
    }

    fn check_setup_status(&self) -> SetupStatus {
        self.setup_checker().check_setup_status()
    }

    fn check_dependency(&self, name: &str) -> DependencyStatus {
        self.setup_checker().check_dependency(name)
    }

    fn get_hook_status(&self) -> HookStatus {
        self.check_setup_status().hooks
    }

    fn check_hook_health(&self) -> HookHealthReport {
        const HOOK_HEALTH_THRESHOLD_SECS: u64 = 60;
        const HOOK_HEALTH_GRACE_SECS: u64 = 300;

        let heartbeat_path = self.app_storage.root().join("hud-hook-heartbeat");
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;

        let (status, age) = match std::fs::metadata(&heartbeat_path) {
            Ok(meta) => match meta.modified() {
                Ok(mtime) => {
                    let age_secs = mtime
                        .elapsed()
                        .map(|duration| duration.as_secs())
                        .unwrap_or(0);
                    let has_active_session = if age_secs > threshold_secs {
                        crate::has_active_runtime_session(
                            crate::runtime_state::snapshot::sessions_snapshot().as_ref(),
                            HOOK_HEALTH_GRACE_SECS,
                        )
                    } else {
                        false
                    };

                    let status = crate::heartbeat_status(
                        age_secs,
                        threshold_secs,
                        HOOK_HEALTH_GRACE_SECS,
                        has_active_session,
                    );
                    (status, Some(age_secs))
                }
                Err(error) => (
                    HookHealthStatus::Unreadable {
                        reason: error.to_string(),
                    },
                    None,
                ),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                (HookHealthStatus::Unknown, None)
            }
            Err(error) => (
                HookHealthStatus::Unreadable {
                    reason: error.to_string(),
                },
                None,
            ),
        };

        HookHealthReport {
            status,
            heartbeat_path: heartbeat_path.display().to_string(),
            threshold_secs,
            last_heartbeat_age_secs: age,
        }
    }

    fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
        let setup_status = self.check_setup_status();
        let health = self.check_hook_health();

        let binary_ok = setup_status
            .dependencies
            .iter()
            .find(|dependency| dependency.name == "hud-hook")
            .map(|dependency| dependency.found)
            .unwrap_or(false);

        let config_ok = matches!(setup_status.hooks, HookStatus::Installed { .. });
        let firing_ok = matches!(health.status, HookHealthStatus::Healthy);
        let is_first_run = matches!(health.status, HookHealthStatus::Unknown);

        let primary_issue = match &setup_status.hooks {
            HookStatus::PolicyBlocked { reason } => Some(HookIssue::PolicyBlocked {
                reason: reason.clone(),
            }),
            HookStatus::SymlinkBroken { target, reason } => Some(HookIssue::SymlinkBroken {
                target: target.clone(),
                reason: reason.clone(),
            }),
            HookStatus::BinaryBroken { reason } => Some(HookIssue::BinaryBroken {
                reason: reason.clone(),
            }),
            _ if !binary_ok => Some(HookIssue::BinaryMissing),
            HookStatus::NotInstalled => Some(HookIssue::ConfigMissing),
            HookStatus::Installed { .. } => match &health.status {
                HookHealthStatus::Healthy => None,
                HookHealthStatus::Unknown => Some(HookIssue::NotFiring {
                    last_seen_secs: None,
                }),
                HookHealthStatus::Stale { last_seen_secs } => Some(HookIssue::NotFiring {
                    last_seen_secs: Some(*last_seen_secs),
                }),
                HookHealthStatus::Unreadable { .. } => None,
            },
        };

        let can_auto_fix = !matches!(primary_issue, Some(HookIssue::PolicyBlocked { .. }));
        let is_healthy = primary_issue.is_none();

        let symlink_path = dirs::home_dir()
            .map(|home| home.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| std::path::PathBuf::from("/usr/local/bin/hud-hook"));

        let symlink_target = if symlink_path.is_symlink() {
            std::fs::read_link(&symlink_path)
                .ok()
                .map(|path| path.to_string_lossy().to_string())
        } else {
            None
        };

        HookDiagnosticReport {
            is_healthy,
            primary_issue,
            can_auto_fix,
            is_first_run,
            binary_ok,
            config_ok,
            firing_ok,
            symlink_path: symlink_path.to_string_lossy().to_string(),
            symlink_target,
            last_heartbeat_age_secs: health.last_heartbeat_age_secs,
        }
    }
}

pub(crate) struct LiveSetupMutator {
    app_storage: StorageConfig,
}

impl LiveSetupMutator {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl SetupMutatorPort for LiveSetupMutator {
    fn build_plan(&self) -> Result<SetupPlan, SetupPortError> {
        let status = self.setup_checker().check_setup_status();
        let mut actions = Vec::new();

        if status
            .dependencies
            .iter()
            .any(|dependency| dependency.name == "hud-hook" && !dependency.found)
        {
            actions.push(SetupAction::InstallHookBinary);
        }

        if !matches!(status.hooks, HookStatus::Installed { .. }) {
            actions.push(SetupAction::InstallHooks);
        }

        Ok(SetupPlan {
            actions,
            generated_at: crate::clean::kernel::Timestamp(crate::domain::now_rfc3339()),
        })
    }

    fn install_hook_bundle(&self, plan: &SetupPlan) -> Result<(), SetupPortError> {
        for action in &plan.actions {
            match action {
                SetupAction::InstallHookBinary => {
                    return Err(SetupPortError::Message(
                        "InstallHookBinary requires an explicit source path".to_string(),
                    ));
                }
                SetupAction::InstallHooks => {
                    let result = self.install_hooks()?;
                    if !result.success {
                        return Err(SetupPortError::Message(result.message));
                    }
                }
                SetupAction::InstallShellSnippet => {
                    return Err(SetupPortError::Message(
                        "InstallShellSnippet is not implemented in the Rust setup mutator"
                            .to_string(),
                    ));
                }
                SetupAction::RepairPermissions => {
                    return Err(SetupPortError::Message(
                        "RepairPermissions is not implemented in the Rust setup mutator"
                            .to_string(),
                    ));
                }
            }
        }

        Ok(())
    }

    fn install_binary_from_path(&self, source_path: &str) -> Result<InstallResult, SetupPortError> {
        self.setup_checker()
            .install_binary_from_path(source_path)
            .map_err(|error| SetupPortError::from(error.to_string()))
    }

    fn install_hooks(&self) -> Result<InstallResult, SetupPortError> {
        self.setup_checker()
            .install_hooks()
            .map_err(|error| SetupPortError::from(error.to_string()))
    }

    fn remove_hooks(&self) -> Result<InstallResult, SetupPortError> {
        self.setup_checker()
            .remove_hooks()
            .map_err(|error| SetupPortError::from(error.to_string()))
    }
}

impl LiveSetupInspector {
    fn setup_checker(&self) -> SetupChecker {
        SetupChecker::new(self.app_storage.clone())
    }
}

impl LiveSetupMutator {
    fn setup_checker(&self) -> SetupChecker {
        SetupChecker::new(self.app_storage.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn live_setup_mutator_reports_missing_binary_source_and_empty_remove_as_canonical_results() {
        let temp = tempdir().expect("temp dir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));
        let mutator = LiveSetupMutator::new(storage);

        let binary_result = mutator
            .install_binary_from_path("/definitely/missing/hud-hook")
            .expect("install binary from path");
        assert!(!binary_result.success);
        assert!(binary_result.message.contains("Source binary not found"));

        let remove_result = mutator.remove_hooks().expect("remove hooks");
        assert!(remove_result.success);
        assert!(remove_result.message.contains("nothing to remove"));
    }
}
