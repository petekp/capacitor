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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HookStatus {
    NotInstalled,
    PartiallyConfigured {
        missing_events: Vec<String>,
        reason: String,
    },
    SettingsUnreadable {
        reason: String,
    },
    Installed,
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

/// Why the runtime is holding setup open and requires explicit user action
/// (as opposed to a state the app can silently auto-repair). The payload
/// preserves enough for Swift `DebugLog` to distinguish the two welcome cases:
/// `ClaudeMissing` -> `.claudeMissing`, `PolicyBlocked { reason }` ->
/// `.hooksBlockedByPolicy(reason:)`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SetupBlockReason {
    /// The required `claude` dependency is not installed.
    ClaudeMissing,
    /// Hooks are explicitly blocked by a Claude settings policy flag.
    PolicyBlocked { reason: String },
}

/// The single, Rust-owned setup-readiness decision. Swift switches on this and
/// owns *which* side-effect to run; it no longer re-derives the gate.
///
/// - `Ready`: every requirement is satisfied.
/// - `NeedsUserAction { reason }`: setup is held open pending the user
///   (`ClaudeMissing` or `PolicyBlocked`); maps to the Swift welcome flow.
/// - `AutoRepairable { status }`: a non-blocking hook state the app can repair
///   on its own; carries the originating `HookStatus` so Swift can log it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SetupReadiness {
    Ready,
    NeedsUserAction { reason: SetupBlockReason },
    AutoRepairable { status: HookStatus },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SetupStatus {
    pub dependencies: Vec<DependencyStatus>,
    pub hooks: HookStatus,
    pub storage_ready: bool,
    /// Rust-owned readiness decision. Single source of truth for the startup
    /// gate; Swift consumes this instead of re-deriving it.
    pub readiness: SetupReadiness,
}

impl SetupStatus {
    /// Pure classifier porting the exact 3-way startup gate that used to live
    /// in Swift `SetupReadinessCoordinator.startupDecision`.
    ///
    /// Load-bearing rule: ONLY a missing required `claude` dependency and an
    /// explicitly `PolicyBlocked` hook state hold setup open. Every other hook
    /// state (`NotInstalled`, `PartiallyConfigured`, `SettingsUnreadable`,
    /// `BinaryBroken`, `SymlinkBroken`) is auto-repairable; `Installed` is ready.
    pub(crate) fn classify_readiness(
        dependencies: &[DependencyStatus],
        hooks: &HookStatus,
    ) -> SetupReadiness {
        let claude_missing = dependencies
            .iter()
            .any(|dep| dep.name == "claude" && dep.required && !dep.found);
        if claude_missing {
            return SetupReadiness::NeedsUserAction {
                reason: SetupBlockReason::ClaudeMissing,
            };
        }

        match hooks {
            HookStatus::Installed => SetupReadiness::Ready,
            HookStatus::PolicyBlocked { reason } => SetupReadiness::NeedsUserAction {
                reason: SetupBlockReason::PolicyBlocked {
                    reason: reason.clone(),
                },
            },
            HookStatus::NotInstalled
            | HookStatus::PartiallyConfigured { .. }
            | HookStatus::SettingsUnreadable { .. }
            | HookStatus::BinaryBroken { .. }
            | HookStatus::SymlinkBroken { .. } => SetupReadiness::AutoRepairable {
                status: hooks.clone(),
            },
        }
    }
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

impl SetupChecker {
    pub(crate) fn new(storage: StorageConfig) -> Self {
        Self { storage }
    }

    pub(crate) fn check_setup_status(&self) -> SetupStatus {
        let dependencies = self.check_all_dependencies();
        let hooks = self.check_hooks_status();
        let storage_ready = self.check_storage();

        let readiness = SetupStatus::classify_readiness(&dependencies, &hooks);

        SetupStatus {
            dependencies,
            hooks,
            storage_ready,
            readiness,
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

#[cfg(test)]
mod readiness_tests {
    use super::*;

    fn claude_dependency(found: bool) -> DependencyStatus {
        DependencyStatus {
            name: "claude".to_string(),
            required: true,
            found,
            path: if found {
                Some("/opt/homebrew/bin/claude".to_string())
            } else {
                None
            },
            install_hint: None,
        }
    }

    /// Characterization test mirroring the Swift
    /// `SetupReadinessCoordinatorTests` canonical contract. Crosses every
    /// `HookStatus` variant with claude-present/absent so the ported 3-way gate
    /// is provably the same decision the Swift `startupDecision` used to make.
    #[test]
    fn classify_readiness_matches_canonical_startup_contract() {
        // 1. claude missing -> NeedsUserAction(ClaudeMissing), regardless of hooks.
        assert_eq!(
            SetupStatus::classify_readiness(&[claude_dependency(false)], &HookStatus::Installed,),
            SetupReadiness::NeedsUserAction {
                reason: SetupBlockReason::ClaudeMissing
            },
            "missing required claude must hold setup even when hooks are installed"
        );

        // 2. claude present + hooks policy-blocked -> NeedsUserAction(PolicyBlocked).
        assert_eq!(
            SetupStatus::classify_readiness(
                &[claude_dependency(true)],
                &HookStatus::PolicyBlocked {
                    reason: "disableAllHooks is enabled.".to_string(),
                },
            ),
            SetupReadiness::NeedsUserAction {
                reason: SetupBlockReason::PolicyBlocked {
                    reason: "disableAllHooks is enabled.".to_string(),
                }
            },
            "policy-blocked hooks must hold setup with the reason preserved"
        );

        // 3. claude present + hooks installed -> Ready.
        assert_eq!(
            SetupStatus::classify_readiness(&[claude_dependency(true)], &HookStatus::Installed,),
            SetupReadiness::Ready,
            "installed hooks with claude present is ready"
        );

        // 4-8. claude present + every other hook state -> AutoRepairable(status).
        let auto_repairable_states = [
            HookStatus::NotInstalled,
            HookStatus::PartiallyConfigured {
                missing_events: vec!["TaskCompleted".to_string(), "SessionEnd".to_string()],
                reason: "Missing or invalid managed hook configuration for 2 event(s)".to_string(),
            },
            HookStatus::SettingsUnreadable {
                reason: "Failed to parse settings.json".to_string(),
            },
            HookStatus::BinaryBroken {
                reason: "codesign error".to_string(),
            },
            HookStatus::SymlinkBroken {
                target: "/old/path/hud-hook".to_string(),
                reason: "Symlink target no longer exists.".to_string(),
            },
        ];

        for status in auto_repairable_states {
            assert_eq!(
                SetupStatus::classify_readiness(&[claude_dependency(true)], &status),
                SetupReadiness::AutoRepairable {
                    status: status.clone()
                },
                "{status:?} must be auto-repairable, not hold setup"
            );
        }
    }
}
