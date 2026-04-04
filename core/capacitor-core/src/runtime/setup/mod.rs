//! Setup validation and hook installation for Capacitor.
//!
//! This module handles:
//! - Checking dependencies (tmux, claude CLI)
//! - Validating and installing session tracking hooks
//! - Checking for policy flags that might block hooks
//!
//! ## Design
//!
//! The setup module follows the sidecar principle - it reads Claude Code's settings
//! and only mutates Capacitor-managed hook entries while preserving unrelated user settings.
//! Installer writes are atomic (temp + rename) to avoid corrupting settings.

mod deps;
mod env;
mod init;
mod paths;
mod settings;

#[cfg(test)]
mod settings_tests;

#[cfg(test)]
mod test_support;

use crate::runtime::storage::StorageConfig;

#[derive(Debug, Clone, uniffi::Record)]
pub struct DependencyStatus {
    pub name: String,
    pub required: bool,
    pub found: bool,
    pub path: Option<String>,
    pub install_hint: Option<String>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum HookStatus {
    NotInstalled,
    PartiallyConfigured {
        missing_events: Vec<String>,
        reason: String,
    },
    SettingsUnreadable {
        reason: String,
    },
    Installed {
        version: String,
    },
    PolicyBlocked {
        reason: String,
    },
    BinaryBroken {
        reason: String,
    },
    /// Symlink exists but target is missing (e.g., app moved or repo cleaned)
    SymlinkBroken {
        target: String,
        reason: String,
    },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SetupStatus {
    pub dependencies: Vec<DependencyStatus>,
    pub hooks: HookStatus,
    pub storage_ready: bool,
    pub all_ready: bool,
    pub blocking_reason: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct InstallResult {
    pub success: bool,
    pub message: String,
    pub script_path: Option<String>,
}

pub(crate) struct SetupChecker {
    storage: StorageConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum HookSettingsStatus {
    NotInstalled,
    PartiallyConfigured {
        missing_events: Vec<String>,
        reason: String,
    },
    SettingsUnreadable {
        reason: String,
    },
    Installed,
}

impl SetupChecker {
    pub(crate) fn new(storage: StorageConfig) -> Self {
        Self { storage }
    }

    pub(crate) fn check_setup_status(&self) -> SetupStatus {
        let dependencies = self.check_all_dependencies();
        let hooks = self.check_hooks_status();
        let storage_ready = self.check_storage();

        let all_required_deps_found = dependencies.iter().filter(|d| d.required).all(|d| d.found);
        let missing_required_dep = dependencies.iter().find(|d| d.required && !d.found);
        let hooks_ok = matches!(hooks, HookStatus::Installed { .. });

        let all_ready = all_required_deps_found && hooks_ok && storage_ready;

        let blocking_reason = if let Some(dep) = missing_required_dep {
            Some(format!("{} is required but not installed", dep.name))
        } else if let HookStatus::PolicyBlocked { ref reason } = hooks {
            Some(reason.clone())
        } else if let HookStatus::SymlinkBroken {
            ref target,
            ref reason,
        } = hooks
        {
            Some(format!(
                "Hook symlink broken (target: {}): {}",
                target, reason
            ))
        } else if let HookStatus::BinaryBroken { ref reason } = hooks {
            Some(format!("Hook binary broken: {}", reason))
        } else if let HookStatus::SettingsUnreadable { ref reason } = hooks {
            Some(format!("Claude settings unreadable: {}", reason))
        } else if let HookStatus::PartiallyConfigured { ref reason, .. } = hooks {
            Some(format!("Hooks partially configured: {}", reason))
        } else if !hooks_ok {
            Some("Hooks not installed".to_string())
        } else if !storage_ready {
            Some("Storage directory not accessible".to_string())
        } else {
            None
        };

        SetupStatus {
            dependencies,
            hooks,
            storage_ready,
            all_ready,
            blocking_reason,
        }
    }

    pub(crate) fn check_dependency(&self, name: &str) -> DependencyStatus {
        match name {
            "tmux" => self.check_tmux(),
            "claude" => self.check_claude(),
            _ => DependencyStatus {
                name: name.to_string(),
                required: false,
                found: false,
                path: None,
                install_hint: Some("Unknown dependency".to_string()),
            },
        }
    }
}
