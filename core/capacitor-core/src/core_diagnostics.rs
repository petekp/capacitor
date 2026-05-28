use super::*;

impl CoreRuntime {
    pub fn wait_for_version_change(
        &self,
        since_version: u64,
        timeout: std::time::Duration,
    ) -> Option<u64> {
        self.notifier
            .wait_for_change(&self.version, since_version, timeout)
    }

    pub fn change_version(&self) -> u64 {
        self.version.load(Ordering::Relaxed)
    }

    pub fn notify_version_waiters(&self) {
        self.notifier.notify();
    }
}

#[uniffi::export]
impl CoreRuntime {
    pub fn check_hook_health(&self) -> runtime::types::HookHealthReport {
        const HOOK_HEALTH_THRESHOLD_SECS: u64 = 60;
        const HOOK_HEALTH_GRACE_SECS: u64 = 300;
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;
        let snapshot = runtime::state::snapshot::hook_health_snapshot();
        let age = snapshot
            .as_ref()
            .and_then(|snapshot| hook_event_age_secs(snapshot.last_hook_event_at.as_deref()));
        let has_active_session = if age.is_some_and(|age_secs| age_secs > threshold_secs) {
            snapshot
                .as_ref()
                .map(|snapshot| {
                    has_active_runtime_session(Some(&snapshot.sessions), HOOK_HEALTH_GRACE_SECS)
                })
                .unwrap_or(false)
        } else {
            false
        };

        let status = match age {
            Some(age_secs) => heartbeat_status(
                age_secs,
                threshold_secs,
                HOOK_HEALTH_GRACE_SECS,
                has_active_session,
            ),
            None => runtime::types::HookHealthStatus::Unknown,
        };

        runtime::types::HookHealthReport {
            status,
            signal_source: "runtime_service_snapshot".to_string(),
            threshold_secs,
            last_hook_event_age_secs: age,
        }
    }

    pub fn get_hook_diagnostic(&self) -> Result<HookDiagnosticReport, CoreRuntimeError> {
        let setup_status = self.check_setup_status()?;
        let health = self.check_hook_health();

        let binary_ok = setup_status
            .dependencies
            .iter()
            .find(|d| d.name == "hud-hook")
            .map(|d| d.found)
            .unwrap_or(false);

        let config_ok = matches!(setup_status.hooks, HookStatus::Installed { .. });
        let firing_ok = matches!(health.status, runtime::types::HookHealthStatus::Healthy);
        let is_first_run = !self.app_storage.setup_marker_path().exists();

        let hook_status = &setup_status.hooks;

        let primary_issue: Option<HookIssue> = match hook_status {
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
            HookStatus::NotInstalled
            | HookStatus::PartiallyConfigured { .. }
            | HookStatus::SettingsUnreadable { .. } => Some(HookIssue::ConfigMissing),
            HookStatus::Installed { .. } => match &health.status {
                runtime::types::HookHealthStatus::Healthy => None,
                runtime::types::HookHealthStatus::Unknown => Some(HookIssue::NotFiring {
                    last_seen_secs: None,
                }),
                runtime::types::HookHealthStatus::Stale { last_seen_secs } => {
                    Some(HookIssue::NotFiring {
                        last_seen_secs: Some(*last_seen_secs),
                    })
                }
            },
        };

        let can_auto_fix = !matches!(primary_issue, Some(HookIssue::PolicyBlocked { .. }))
            && !matches!(hook_status, HookStatus::SettingsUnreadable { .. });
        let is_healthy = primary_issue.is_none();

        let symlink_path = dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| std::path::PathBuf::from("/usr/local/bin/hud-hook"));

        let symlink_target = if symlink_path.is_symlink() {
            std::fs::read_link(&symlink_path)
                .ok()
                .map(|p| p.to_string_lossy().to_string())
        } else {
            None
        };

        Ok(HookDiagnosticReport {
            is_healthy,
            primary_issue,
            can_auto_fix,
            is_first_run,
            binary_ok,
            config_ok,
            firing_ok,
            symlink_path: symlink_path.to_string_lossy().to_string(),
            symlink_target,
            last_hook_event_age_secs: health.last_hook_event_age_secs,
        })
    }

    pub fn run_hook_test(&self) -> Result<HookTestResult, CoreRuntimeError> {
        let health = self.check_hook_health();
        let hook_activity_ok = matches!(health.status, runtime::types::HookHealthStatus::Healthy);
        let hook_activity_age = health.last_hook_event_age_secs;

        let runtime_service_ok = self.test_runtime_service_health();
        let success = hook_activity_ok && runtime_service_ok;
        let message = if success {
            "Hooks are working correctly".to_string()
        } else if !hook_activity_ok {
            match hook_activity_age {
                Some(age) => format!(
                    "Hook activity stale ({}s ago). Start a Claude session to test.",
                    age
                ),
                None => "No recent hook activity detected. Start a Claude session to test hooks."
                    .to_string(),
            }
        } else {
            "Runtime health check failed. Ensure the local runtime service is available."
                .to_string()
        };

        Ok(HookTestResult {
            success,
            hook_activity_ok,
            hook_activity_age_secs: hook_activity_age,
            runtime_service_ok,
            message,
        })
    }
}
