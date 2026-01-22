//! Setup validation and hook installation for Claude HUD.
//!
//! This module handles:
//! - Checking dependencies (jq, tmux, claude CLI)
//! - Validating and installing session tracking hooks
//! - Checking for policy flags that might block hooks
//!
//! ## Design
//!
//! The setup module follows the sidecar principle - it reads Claude Code's settings
//! but only modifies them to add our hooks, never removing or changing other settings.
//! Installer writes are atomic (temp + rename) to avoid corrupting settings.

use crate::error::HudFfiError;
use crate::storage::StorageConfig;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::NamedTempFile;

const HOOK_SCRIPT_VERSION: &str = "3.0.2";
const HOOK_COMMAND: &str = "$HOME/.claude/scripts/hud-state-tracker.sh";
const HOOK_SCRIPT: &str = include_str!("../../../scripts/hud-state-tracker.sh");

const HUD_HOOK_EVENTS: [(&str, bool); 10] = [
    ("SessionStart", false),
    ("SessionEnd", false),
    ("UserPromptSubmit", false),
    ("PreToolUse", true),
    ("PostToolUse", true),
    ("PermissionRequest", true),
    ("Stop", false),
    ("SubagentStop", false),
    ("PreCompact", false),
    ("Notification", false),
];

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
    Outdated { current: String, latest: String },
    Installed { version: String },
    PolicyBlocked { reason: String },
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

pub struct SetupChecker {
    storage: StorageConfig,
}

impl SetupChecker {
    pub fn new(storage: StorageConfig) -> Self {
        Self { storage }
    }

    pub fn check_setup_status(&self) -> SetupStatus {
        let dependencies = self.check_all_dependencies();
        let hooks = self.check_hooks_status();
        let storage_ready = self.check_storage();

        // Check all required dependencies are found
        let all_required_deps_found = dependencies.iter().filter(|d| d.required).all(|d| d.found);

        // Find first missing required dependency for error message
        let missing_required_dep = dependencies.iter().find(|d| d.required && !d.found);

        let hooks_ok = matches!(hooks, HookStatus::Installed { .. });

        let all_ready = all_required_deps_found && hooks_ok && storage_ready;

        let blocking_reason = if let Some(dep) = missing_required_dep {
            Some(format!("{} is required but not installed", dep.name))
        } else if matches!(hooks, HookStatus::PolicyBlocked { .. }) {
            if let HookStatus::PolicyBlocked { ref reason } = hooks {
                Some(reason.clone())
            } else {
                None
            }
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

    pub fn check_dependency(&self, name: &str) -> DependencyStatus {
        match name {
            "jq" => self.check_jq(),
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

    fn check_all_dependencies(&self) -> Vec<DependencyStatus> {
        vec![self.check_jq(), self.check_tmux(), self.check_claude()]
    }

    fn check_jq(&self) -> DependencyStatus {
        let path = which("jq");
        let has_python = which("python3").is_some();
        DependencyStatus {
            name: "jq".to_string(),
            required: !has_python,
            found: path.is_some(),
            path,
            install_hint: Some("brew install jq (or ensure python3 is available)".to_string()),
        }
    }

    fn check_tmux(&self) -> DependencyStatus {
        let path = which("tmux");
        DependencyStatus {
            name: "tmux".to_string(),
            required: false,
            found: path.is_some(),
            path,
            install_hint: Some("brew install tmux".to_string()),
        }
    }

    fn check_claude(&self) -> DependencyStatus {
        let path = which("claude");
        DependencyStatus {
            name: "claude".to_string(),
            required: true,
            found: path.is_some(),
            path,
            install_hint: Some("Install from claude.ai/download".to_string()),
        }
    }

    fn check_storage(&self) -> bool {
        let root = self.storage.root();
        if !root.exists() && fs::create_dir_all(root).is_err() {
            return false;
        }
        root.exists() && root.is_dir()
    }

    fn check_hooks_status(&self) -> HookStatus {
        if let Some(reason) = self.check_policy_blocks() {
            return HookStatus::PolicyBlocked { reason };
        }

        let script_path = self.get_hook_script_path();
        if !script_path.exists() {
            return HookStatus::NotInstalled;
        }
        if !self.is_script_executable(&script_path) {
            return HookStatus::NotInstalled;
        }

        let current_version = self.get_installed_hook_version(&script_path);
        match current_version {
            Some(version) if version == HOOK_SCRIPT_VERSION => {
                if self.hooks_registered_in_settings() {
                    HookStatus::Installed { version }
                } else {
                    HookStatus::NotInstalled
                }
            }
            Some(version) => HookStatus::Outdated {
                current: version,
                latest: HOOK_SCRIPT_VERSION.to_string(),
            },
            None => HookStatus::NotInstalled,
        }
    }

    fn is_script_executable(&self, script_path: &Path) -> bool {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::metadata(script_path)
                .map(|meta| meta.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        }
        #[cfg(not(unix))]
        {
            script_path.exists()
        }
    }

    fn check_policy_blocks(&self) -> Option<String> {
        let settings_path = self.storage.claude_settings_file();
        let local_settings_path = self.storage.claude_root().join("settings.local.json");

        for path in [&settings_path, &local_settings_path] {
            if let Ok(content) = fs::read_to_string(path) {
                if let Ok(settings) = serde_json::from_str::<serde_json::Value>(&content) {
                    if settings.get("disableAllHooks") == Some(&serde_json::Value::Bool(true)) {
                        return Some("Hooks disabled by disableAllHooks setting".to_string());
                    }
                    if settings.get("allowManagedHooksOnly") == Some(&serde_json::Value::Bool(true))
                    {
                        return Some(
                            "Only managed hooks allowed by allowManagedHooksOnly setting"
                                .to_string(),
                        );
                    }
                }
            }
        }
        None
    }

    fn get_hook_script_path(&self) -> PathBuf {
        self.storage
            .claude_root()
            .join("scripts/hud-state-tracker.sh")
    }

    fn get_installed_hook_version(&self, script_path: &Path) -> Option<String> {
        let content = fs::read_to_string(script_path).ok()?;
        for line in content.lines().take(5) {
            if line.starts_with("# Claude HUD State Tracker Hook v") {
                let version = line
                    .strip_prefix("# Claude HUD State Tracker Hook v")?
                    .trim();
                return Some(version.to_string());
            }
        }
        None
    }

    fn hooks_registered_in_settings(&self) -> bool {
        let settings_path = self.storage.claude_settings_file();
        if !settings_path.exists() {
            return false;
        }

        let content = match fs::read_to_string(&settings_path) {
            Ok(c) => c,
            Err(_) => return false,
        };

        let settings: SettingsFile = match serde_json::from_str(&content) {
            Ok(s) => s,
            Err(_) => return false,
        };

        let hooks = match settings.hooks {
            Some(h) => h,
            None => return false,
        };

        for (event, needs_matcher) in HUD_HOOK_EVENTS {
            let has_hook = hooks
                .get(event)
                .map(|h| self.has_hud_hook_with_matcher(h, needs_matcher))
                .unwrap_or(false);

            if !has_hook {
                return false;
            }
        }

        true
    }

    fn has_hud_hook_with_matcher(&self, hooks: &[HookConfig], needs_matcher: bool) -> bool {
        for hook_config in hooks {
            // Check if this config has our hook
            let has_hud_hook = hook_config
                .hooks
                .as_ref()
                .map(|inner| {
                    inner.iter().any(|h| {
                        h.command
                            .as_ref()
                            .map(|cmd| cmd.contains("hud-state-tracker.sh"))
                            .unwrap_or(false)
                    })
                })
                .unwrap_or(false);

            if has_hud_hook {
                // If this event needs a matcher, verify it has one
                if needs_matcher {
                    let matcher_ok = hook_config
                        .matcher
                        .as_deref()
                        .map(|m| m.trim() == "*")
                        .unwrap_or(false);
                    if matcher_ok {
                        return true;
                    }
                    // Has hook but missing required matcher - keep looking
                } else {
                    return true;
                }
            }
        }
        false
    }

    fn normalize_hud_hook_config(&self, hook_config: &mut HookConfig, needs_matcher: bool) -> bool {
        let mut has_hud_hook = false;

        if let Some(inner_hooks) = hook_config.hooks.as_mut() {
            for hook in inner_hooks.iter_mut() {
                if let Some(command) = hook.command.as_ref() {
                    if command.contains("hud-state-tracker.sh") {
                        // Normalize the command to the canonical path
                        hook.command = Some(HOOK_COMMAND.to_string());
                        if hook.hook_type.is_none() {
                            hook.hook_type = Some("command".to_string());
                        }
                        has_hud_hook = true;
                    }
                }
            }
        }

        if has_hud_hook && needs_matcher {
            let matcher_ok = hook_config
                .matcher
                .as_deref()
                .map(|m| m.trim() == "*")
                .unwrap_or(false);
            if !matcher_ok {
                hook_config.matcher = Some("*".to_string());
            }
        }

        has_hud_hook
    }

    pub fn install_hooks(&self) -> Result<InstallResult, HudFfiError> {
        if let Some(reason) = self.check_policy_blocks() {
            return Ok(InstallResult {
                success: false,
                message: format!("Cannot install hooks: {}", reason),
                script_path: None,
            });
        }

        let scripts_dir = self.storage.claude_root().join("scripts");
        fs::create_dir_all(&scripts_dir).map_err(|e| HudFfiError::General {
            message: format!("Failed to create scripts directory: {}", e),
        })?;

        let script_path = scripts_dir.join("hud-state-tracker.sh");
        let mut temp_script =
            NamedTempFile::new_in(&scripts_dir).map_err(|e| HudFfiError::General {
                message: format!("Failed to create temp script file: {}", e),
            })?;
        temp_script
            .write_all(HOOK_SCRIPT.as_bytes())
            .map_err(|e| HudFfiError::General {
                message: format!("Failed to write hook script: {}", e),
            })?;
        temp_script.flush().map_err(|e| HudFfiError::General {
            message: format!("Failed to flush hook script: {}", e),
        })?;
        temp_script
            .persist(&script_path)
            .map_err(|e| HudFfiError::General {
                message: format!("Failed to persist hook script: {}", e.error),
            })?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&script_path)
                .map_err(|e| HudFfiError::General {
                    message: format!("Failed to get script permissions: {}", e),
                })?
                .permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms).map_err(|e| HudFfiError::General {
                message: format!("Failed to set script permissions: {}", e),
            })?;
        }

        self.register_hooks_in_settings()?;

        Ok(InstallResult {
            success: true,
            message: format!("Hooks installed successfully (v{})", HOOK_SCRIPT_VERSION),
            script_path: Some(script_path.to_string_lossy().to_string()),
        })
    }

    fn register_hooks_in_settings(&self) -> Result<(), HudFfiError> {
        let settings_path = self.storage.claude_settings_file();

        let mut settings: SettingsFile = if settings_path.exists() {
            let content = fs::read_to_string(&settings_path).map_err(|e| HudFfiError::General {
                message: format!("Failed to read settings: {}", e),
            })?;
            serde_json::from_str(&content).map_err(|e| HudFfiError::General {
                message: format!(
                    "Failed to parse settings.json (file may be corrupted): {}. \
                     Please fix the JSON syntax or delete the file to start fresh.",
                    e
                ),
            })?
        } else {
            SettingsFile::default()
        };

        let hooks = settings.hooks.get_or_insert_with(HashMap::new);

        for (event, needs_matcher) in HUD_HOOK_EVENTS {
            let event_hooks = hooks.entry(event.to_string()).or_default();

            // Normalize any existing HUD hook entries, then check if we already have one
            let mut already_has_hud_hook = false;
            for hook_config in event_hooks.iter_mut() {
                if self.normalize_hud_hook_config(hook_config, needs_matcher) {
                    already_has_hud_hook = true;
                }
            }

            if !already_has_hud_hook {
                let hook_config = HookConfig {
                    matcher: if needs_matcher {
                        Some("*".to_string())
                    } else {
                        None
                    },
                    hooks: Some(vec![InnerHook {
                        hook_type: Some("command".to_string()),
                        command: Some(HOOK_COMMAND.to_string()),
                        other: HashMap::new(),
                    }]),
                    other: HashMap::new(),
                };

                event_hooks.push(hook_config);
            }
        }

        let content =
            serde_json::to_string_pretty(&settings).map_err(|e| HudFfiError::General {
                message: format!("Failed to serialize settings: {}", e),
            })?;

        let settings_dir = settings_path.parent().ok_or_else(|| HudFfiError::General {
            message: "Settings path has no parent directory".to_string(),
        })?;
        let mut temp_settings =
            NamedTempFile::new_in(settings_dir).map_err(|e| HudFfiError::General {
                message: format!("Failed to create temp settings file: {}", e),
            })?;
        temp_settings
            .write_all(content.as_bytes())
            .map_err(|e| HudFfiError::General {
                message: format!("Failed to write settings: {}", e),
            })?;
        temp_settings.flush().map_err(|e| HudFfiError::General {
            message: format!("Failed to flush settings: {}", e),
        })?;
        temp_settings
            .persist(&settings_path)
            .map_err(|e| HudFfiError::General {
                message: format!("Failed to persist settings: {}", e.error),
            })?;

        Ok(())
    }
}

fn which(binary: &str) -> Option<String> {
    let output = Command::new("which").arg(binary).output().ok()?;

    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() {
            return Some(path);
        }
    }
    None
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SettingsFile {
    #[serde(skip_serializing_if = "Option::is_none")]
    hooks: Option<HashMap<String, Vec<HookConfig>>>,
    #[serde(flatten)]
    other: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HookConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    matcher: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hooks: Option<Vec<InnerHook>>,
    #[serde(flatten)]
    other: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InnerHook {
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    hook_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    command: Option<String>,
    #[serde(flatten)]
    other: HashMap<String, serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_test_env() -> (TempDir, StorageConfig) {
        let temp = TempDir::new().unwrap();
        let capacitor_root = temp.path().join(".capacitor");
        let claude_root = temp.path().join(".claude");
        fs::create_dir_all(&capacitor_root).unwrap();
        fs::create_dir_all(&claude_root).unwrap();
        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        (temp, storage)
    }

    #[test]
    fn test_check_hooks_not_installed() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();
        assert!(matches!(status, HookStatus::NotInstalled));
    }

    #[test]
    fn test_install_hooks_creates_script() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let result = checker.install_hooks().unwrap();
        assert!(result.success);

        let script_path = storage.claude_root().join("scripts/hud-state-tracker.sh");
        assert!(script_path.exists());

        let content = fs::read_to_string(&script_path).unwrap();
        assert!(content.contains(&format!(
            "Claude HUD State Tracker Hook v{}",
            HOOK_SCRIPT_VERSION
        )));
    }

    #[test]
    fn test_install_hooks_registers_in_settings() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        checker.install_hooks().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert!(settings["hooks"]["SessionStart"].is_array());
        assert!(settings["hooks"]["PostToolUse"].is_array());

        let post_tool_use = &settings["hooks"]["PostToolUse"][0];
        assert_eq!(post_tool_use["matcher"], "*");
    }

    #[test]
    fn test_policy_blocks_disable_all_hooks() {
        let (_temp, storage) = setup_test_env();

        let settings = r#"{"disableAllHooks": true}"#;
        fs::write(storage.claude_settings_file(), settings).unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(matches!(status, HookStatus::PolicyBlocked { .. }));
    }

    #[test]
    fn test_policy_blocks_managed_hooks_only() {
        let (_temp, storage) = setup_test_env();

        let settings = r#"{"allowManagedHooksOnly": true}"#;
        fs::write(storage.claude_root().join("settings.local.json"), settings).unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(matches!(status, HookStatus::PolicyBlocked { .. }));
    }

    #[test]
    fn test_hooks_outdated_detection() {
        let (_temp, storage) = setup_test_env();

        let scripts_dir = storage.claude_root().join("scripts");
        fs::create_dir_all(&scripts_dir).unwrap();

        let old_script = "#!/bin/bash\n# Claude HUD State Tracker Hook v1.0.0\n";
        let script_path = scripts_dir.join("hud-state-tracker.sh");
        fs::write(&script_path, old_script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&script_path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms).unwrap();
        }

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        match status {
            HookStatus::Outdated { current, latest } => {
                assert_eq!(current, "1.0.0");
                assert_eq!(latest, HOOK_SCRIPT_VERSION);
            }
            _ => panic!("Expected Outdated status"),
        }
    }

    #[test]
    fn test_does_not_clobber_existing_settings() {
        let (_temp, storage) = setup_test_env();

        let existing = r#"{
            "someOtherSetting": "value",
            "hooks": {
                "CustomEvent": [{"hooks": [{"type": "command", "command": "custom.sh"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), existing).unwrap();

        let checker = SetupChecker::new(storage.clone());
        checker.install_hooks().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(settings["someOtherSetting"], "value");
        assert!(settings["hooks"]["CustomEvent"].is_array());
        assert!(settings["hooks"]["SessionStart"].is_array());
    }

    #[test]
    fn test_install_hooks_fails_on_corrupt_json() {
        let (_temp, storage) = setup_test_env();

        // Write corrupt JSON
        let corrupt = r#"{ invalid json }"#;
        fs::write(storage.claude_settings_file(), corrupt).unwrap();

        let checker = SetupChecker::new(storage.clone());
        let result = checker.install_hooks();

        // Should return an error, not silently clobber
        assert!(result.is_err());

        // Original content should be preserved
        let content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        assert_eq!(content, corrupt);
    }

    #[test]
    fn test_hooks_registered_checks_all_critical_events() {
        let (_temp, storage) = setup_test_env();

        // Write settings with only SessionStart (missing others)
        let partial = r#"{
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "hud-state-tracker.sh"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), partial).unwrap();

        // Also need the script to exist
        let scripts_dir = storage.claude_root().join("scripts");
        fs::create_dir_all(&scripts_dir).unwrap();
        fs::write(
            scripts_dir.join("hud-state-tracker.sh"),
            "#!/bin/bash\n# Claude HUD State Tracker Hook v2.1.0\n",
        )
        .unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        // Should NOT be marked as installed since PostToolUse is missing
        assert!(matches!(status, HookStatus::NotInstalled));
    }

    #[test]
    fn test_hooks_registered_checks_matchers() {
        let (_temp, storage) = setup_test_env();

        // Write settings with PostToolUse but missing matcher
        let missing_matcher = r#"{
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "hud-state-tracker.sh"}]}],
                "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "hud-state-tracker.sh"}]}],
                "PostToolUse": [{"hooks": [{"type": "command", "command": "hud-state-tracker.sh"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "hud-state-tracker.sh"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), missing_matcher).unwrap();

        // Also need the script to exist
        let scripts_dir = storage.claude_root().join("scripts");
        fs::create_dir_all(&scripts_dir).unwrap();
        fs::write(
            scripts_dir.join("hud-state-tracker.sh"),
            "#!/bin/bash\n# Claude HUD State Tracker Hook v2.1.0\n",
        )
        .unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        // Should NOT be marked as installed since PostToolUse is missing matcher
        assert!(matches!(status, HookStatus::NotInstalled));
    }
}
