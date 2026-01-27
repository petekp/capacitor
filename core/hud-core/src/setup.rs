//! Setup validation and hook installation for Claude HUD.
//!
//! This module handles:
//! - Checking dependencies (tmux, claude CLI)
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
use fs_err as fs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;
use tempfile::NamedTempFile;

const HOOK_COMMAND: &str = "$HOME/.local/bin/hud-hook handle";

/// Hook event configuration: (event_name, needs_matcher, is_async)
/// - `needs_matcher`: Events like PreToolUse need `matcher: "*"` to fire for all tools
/// - `is_async`: If true, hook runs in background without blocking Claude Code
///   SessionEnd is sync to ensure cleanup completes before session exits
const HUD_HOOK_EVENTS: [(&str, bool, bool); 9] = [
    ("SessionStart", false, true),
    ("SessionEnd", false, false), // Keep sync for guaranteed cleanup
    ("UserPromptSubmit", false, true),
    ("PreToolUse", true, true),
    ("PostToolUse", true, true),
    ("PermissionRequest", true, true),
    ("Stop", false, true),
    ("PreCompact", false, true),
    ("Notification", false, true),
];

const HOOK_TIMEOUT_SECONDS: u32 = 30;

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
    Outdated {
        current: String,
        latest: String,
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
        vec![
            self.check_hud_hook(),
            self.check_tmux(),
            self.check_claude(),
        ]
    }

    fn check_hud_hook(&self) -> DependencyStatus {
        // Check for the Rust hook handler binary
        let path = which("hud-hook").or_else(|| {
            // Also check the standard install location
            dirs::home_dir()
                .map(|h| h.join(".local/bin/hud-hook"))
                .filter(|p| p.exists())
                .map(|p| p.to_string_lossy().to_string())
        });

        DependencyStatus {
            name: "hud-hook".to_string(),
            required: true,
            found: path.is_some(),
            path,
            install_hint: Some("Run: ./scripts/sync-hooks.sh".to_string()),
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
        // GUI apps don't inherit shell PATH, so check common locations directly
        let path = which_with_fallback(
            "claude",
            &[
                "/opt/homebrew/bin/claude", // Homebrew (Apple Silicon)
                "/usr/local/bin/claude",    // Homebrew (Intel) or manual install
            ],
        );
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

        // Check if binary exists (or is a symlink)
        let binary_path = self.get_hook_binary_path();
        let is_symlink = binary_path.is_symlink();

        // For symlinks, check if target exists before checking binary_path.exists()
        // (exists() returns false for broken symlinks)
        if is_symlink {
            if let Ok(target) = fs::read_link(&binary_path) {
                if !target.exists() {
                    return HookStatus::SymlinkBroken {
                        target: target.to_string_lossy().to_string(),
                        reason: "Symlink target no longer exists. The app may have moved or `cargo clean` was run.".to_string(),
                    };
                }
            }
        }

        if !binary_path.exists() && !is_symlink {
            return HookStatus::NotInstalled;
        }

        // Verify binary actually works (catches macOS codesigning issues)
        if let Err(reason) = self.verify_hook_binary() {
            // Check if it's a symlink-specific error
            if reason.starts_with("SYMLINK_BROKEN:") {
                let parts: Vec<&str> = reason.splitn(3, ':').collect();
                if parts.len() >= 3 {
                    return HookStatus::SymlinkBroken {
                        target: parts[1].to_string(),
                        reason: parts[2].to_string(),
                    };
                }
            }
            return HookStatus::BinaryBroken { reason };
        }

        // Check if hooks are registered in settings
        if !self.hooks_registered_in_settings() {
            return HookStatus::NotInstalled;
        }

        HookStatus::Installed {
            version: "binary".to_string(),
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

    fn get_hook_binary_path(&self) -> PathBuf {
        dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| PathBuf::from("/usr/local/bin/hud-hook"))
    }

    /// Verifies the hook binary actually runs (not just exists).
    ///
    /// Returns Ok(()) if the binary works, Err(reason) if broken.
    /// This catches:
    /// - Broken symlinks (target moved/deleted)
    /// - macOS code signing issues (SIGKILL = exit 137)
    fn verify_hook_binary(&self) -> Result<(), String> {
        let binary_path = self.get_hook_binary_path();

        // Check if it's a symlink with a broken target
        if binary_path.is_symlink() {
            match fs::read_link(&binary_path) {
                Ok(target) => {
                    if !target.exists() {
                        return Err(format!(
                            "SYMLINK_BROKEN:{}:Symlink target no longer exists. \
                             The app may have moved or `cargo clean` was run.",
                            target.display()
                        ));
                    }
                }
                Err(e) => {
                    return Err(format!("Cannot read symlink: {}", e));
                }
            }
        }

        if !binary_path.exists() {
            return Err("Binary not found".to_string());
        }

        // Try to run the binary with empty input
        let output = Command::new(&binary_path)
            .arg("handle")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                // Write empty JSON to stdin
                if let Some(stdin) = child.stdin.as_mut() {
                    use std::io::Write;
                    let _ = stdin.write_all(b"{}");
                }
                child.wait_with_output()
            });

        match output {
            Ok(output) => {
                let code = output.status.code().unwrap_or(-1);
                if code == 137 {
                    // SIGKILL - macOS killed unsigned binary
                    // This shouldn't happen with symlinks, but catch it anyway
                    Err("Binary killed by macOS (exit 137). Try reinstalling the app.".to_string())
                } else {
                    // Exit code 0 or other non-fatal codes are OK
                    // (binary may exit non-zero for empty input, that's fine)
                    Ok(())
                }
            }
            Err(e) => Err(format!("Failed to run binary: {}", e)),
        }
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

        for (event, needs_matcher, is_async) in HUD_HOOK_EVENTS {
            let has_hook = hooks
                .get(event)
                .map(|h| self.has_hud_hook_with_correct_config(h, needs_matcher, is_async))
                .unwrap_or(false);

            if !has_hook {
                return false;
            }
        }

        true
    }

    fn has_hud_hook_with_correct_config(
        &self,
        hooks: &[HookConfig],
        needs_matcher: bool,
        expected_async: bool,
    ) -> bool {
        for hook_config in hooks {
            // Check if this config has our hook with correct async setting
            let has_correct_hud_hook = hook_config
                .hooks
                .as_ref()
                .map(|inner| {
                    inner.iter().any(|h| {
                        if !is_hud_hook_command(h.command.as_deref()) {
                            return false;
                        }
                        // Verify async configuration matches expected
                        if expected_async {
                            h.async_hook == Some(true) && h.timeout == Some(HOOK_TIMEOUT_SECONDS)
                        } else {
                            h.async_hook.is_none() && h.timeout.is_none()
                        }
                    })
                })
                .unwrap_or(false);

            if has_correct_hud_hook {
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

    fn normalize_hud_hook_config(
        &self,
        hook_config: &mut HookConfig,
        needs_matcher: bool,
        is_async: bool,
    ) -> bool {
        let mut has_hud_hook = false;

        if let Some(inner_hooks) = hook_config.hooks.as_mut() {
            for hook in inner_hooks.iter_mut() {
                if is_hud_hook_command(hook.command.as_deref()) {
                    // Normalize the command to the canonical path (binary)
                    hook.command = Some(HOOK_COMMAND.to_string());
                    if hook.hook_type.is_none() {
                        hook.hook_type = Some("command".to_string());
                    }
                    // Update async/timeout settings
                    if is_async {
                        hook.async_hook = Some(true);
                        hook.timeout = Some(HOOK_TIMEOUT_SECONDS);
                    } else {
                        hook.async_hook = None;
                        hook.timeout = None;
                    }
                    has_hud_hook = true;
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

    /// Installs the hook binary from a given source path to ~/.local/bin/hud-hook.
    ///
    /// This is the "core" side of binary installation - it handles:
    /// - Creating ~/.local/bin if needed
    /// - Creating a SYMLINK to the source binary (not copying!)
    ///
    /// IMPORTANT: We use symlinks instead of copying because:
    /// - Copied adhoc-signed binaries get SIGKILL'd by macOS Gatekeeper
    /// - Symlinks preserve the original binary's code signature
    /// - If the app moves, the symlink breaks obviously (not silently)
    ///
    /// The client is responsible for finding the source binary (e.g., from app bundle).
    /// Returns success if installed, error if any step fails.
    pub fn install_binary_from_path(
        &self,
        source_path: &str,
    ) -> Result<InstallResult, HudFfiError> {
        use std::os::unix::fs::symlink;

        let source = std::path::Path::new(source_path);
        if !source.exists() {
            return Ok(InstallResult {
                success: false,
                message: format!("Source binary not found at {}", source_path),
                script_path: None,
            });
        }

        // Canonicalize source path to get absolute path for symlink
        let source_abs = source.canonicalize().map_err(|e| HudFfiError::General {
            message: format!("Failed to resolve source path: {}", e),
        })?;

        let dest_dir = dirs::home_dir()
            .ok_or_else(|| HudFfiError::General {
                message: "Could not determine home directory".to_string(),
            })?
            .join(".local/bin");

        let dest_path = dest_dir.join("hud-hook");

        // Check if symlink already points to the correct target
        if dest_path.is_symlink() {
            if let Ok(current_target) = fs::read_link(&dest_path) {
                if current_target == source_abs {
                    return Ok(InstallResult {
                        success: true,
                        message: "Hook binary symlink already correct".to_string(),
                        script_path: Some(dest_path.to_string_lossy().to_string()),
                    });
                }
            }
        }

        // Create ~/.local/bin if needed
        fs::create_dir_all(&dest_dir).map_err(|e| HudFfiError::General {
            message: format!("Failed to create ~/.local/bin: {}", e),
        })?;

        // Remove existing file/symlink before creating new one
        if dest_path.exists() || dest_path.is_symlink() {
            fs::remove_file(&dest_path).map_err(|e| HudFfiError::General {
                message: format!("Failed to remove existing binary/symlink: {}", e),
            })?;
        }

        // Create symlink (not copy!) to preserve code signature
        symlink(&source_abs, &dest_path).map_err(|e| HudFfiError::General {
            message: format!("Failed to create symlink: {}", e),
        })?;

        Ok(InstallResult {
            success: true,
            message: format!(
                "Hook binary symlinked: {} -> {}",
                dest_path.display(),
                source_abs.display()
            ),
            script_path: Some(dest_path.to_string_lossy().to_string()),
        })
    }

    pub fn install_hooks(&self) -> Result<InstallResult, HudFfiError> {
        if let Some(reason) = self.check_policy_blocks() {
            return Ok(InstallResult {
                success: false,
                message: format!("Cannot install hooks: {}", reason),
                script_path: None,
            });
        }

        // Verify binary exists before registering hooks
        let binary_path = self.get_hook_binary_path();
        if !binary_path.exists() {
            return Ok(InstallResult {
                success: false,
                message: format!(
                    "Hook binary not found at {}. Run: ./scripts/sync-hooks.sh",
                    binary_path.display()
                ),
                script_path: None,
            });
        }

        // Verify binary works (catches codesigning issues)
        if let Err(reason) = self.verify_hook_binary() {
            return Ok(InstallResult {
                success: false,
                message: format!("Hook binary broken: {}", reason),
                script_path: None,
            });
        }

        self.register_hooks_in_settings()?;

        Ok(InstallResult {
            success: true,
            message: "Hooks configured successfully".to_string(),
            script_path: Some(binary_path.to_string_lossy().to_string()),
        })
    }

    pub(crate) fn register_hooks_in_settings(&self) -> Result<(), HudFfiError> {
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

        for (event, needs_matcher, is_async) in HUD_HOOK_EVENTS {
            let event_hooks = hooks.entry(event.to_string()).or_default();

            // Normalize any existing HUD hook entries, then check if we already have one
            let mut already_has_hud_hook = false;
            for hook_config in event_hooks.iter_mut() {
                if self.normalize_hud_hook_config(hook_config, needs_matcher, is_async) {
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
                        async_hook: if is_async { Some(true) } else { None },
                        timeout: if is_async {
                            Some(HOOK_TIMEOUT_SECONDS)
                        } else {
                            None
                        },
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

fn which_with_fallback(binary: &str, fallback_paths: &[&str]) -> Option<String> {
    // Try `which` first (works in Terminal, may fail in GUI apps)
    if let Some(path) = which(binary) {
        return Some(path);
    }

    // Check fallback paths directly (GUI apps don't inherit shell PATH)
    for path in fallback_paths {
        let p = std::path::Path::new(path);
        if p.exists() && p.is_file() {
            return Some(path.to_string());
        }
    }

    // Also check ~/.local/bin which is common for npm/pip installs
    if let Some(home) = dirs::home_dir() {
        let local_bin = home.join(".local/bin").join(binary);
        if local_bin.exists() {
            return Some(local_bin.to_string_lossy().to_string());
        }
    }

    None
}

/// Check if a command is the HUD hook binary.
fn is_hud_hook_command(cmd: Option<&str>) -> bool {
    cmd.map(|c| c.contains("hud-hook")).unwrap_or(false)
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
    #[serde(rename = "async", skip_serializing_if = "Option::is_none")]
    async_hook: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout: Option<u32>,
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
    fn test_register_hooks_in_settings() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        // Directly call register_hooks_in_settings (bypasses binary check)
        checker.register_hooks_in_settings().unwrap();

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
    fn test_install_hooks_checks_binary() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage);

        let result = checker.install_hooks().unwrap();

        // Binary check happens before settings registration
        // If binary exists on system, it will succeed; if not, it fails gracefully
        let binary_path = dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| PathBuf::from("/usr/local/bin/hud-hook"));

        if binary_path.exists() {
            // Binary exists, should succeed (or fail on verification)
            // Just verify it doesn't panic and returns a result
            assert!(result.success || result.message.contains("broken"));
        } else {
            // Binary missing, should fail gracefully with helpful message
            assert!(!result.success);
            assert!(result.message.contains("not found"));
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
        checker.register_hooks_in_settings().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(settings["someOtherSetting"], "value");
        assert!(settings["hooks"]["CustomEvent"].is_array());
        assert!(settings["hooks"]["SessionStart"].is_array());
    }

    #[test]
    fn test_register_hooks_fails_on_corrupt_json() {
        let (_temp, storage) = setup_test_env();

        // Write corrupt JSON
        let corrupt = r#"{ invalid json }"#;
        fs::write(storage.claude_settings_file(), corrupt).unwrap();

        let checker = SetupChecker::new(storage.clone());
        let result = checker.register_hooks_in_settings();

        // Should return an error, not silently clobber
        assert!(result.is_err());

        // Original content should be preserved
        let content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        assert_eq!(content, corrupt);
    }

    #[test]
    fn test_hooks_registered_checks_all_critical_events() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        // Write settings with only SessionStart (missing others)
        let partial = r#"{
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "hud-hook handle"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), partial).unwrap();

        // hooks_registered_in_settings should return false since PostToolUse is missing
        assert!(!checker.hooks_registered_in_settings());
    }

    #[test]
    fn test_hooks_registered_checks_matchers() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        // Write settings with PostToolUse but missing matcher
        let missing_matcher = r#"{
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "hud-hook handle"}]}],
                "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "hud-hook handle"}]}],
                "PostToolUse": [{"hooks": [{"type": "command", "command": "hud-hook handle"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "hud-hook handle"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), missing_matcher).unwrap();

        // hooks_registered_in_settings should return false since PostToolUse missing matcher
        assert!(!checker.hooks_registered_in_settings());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // install_binary_from_path tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_install_binary_source_not_found() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage);

        let result = checker
            .install_binary_from_path("/nonexistent/path/to/binary")
            .unwrap();

        assert!(!result.success);
        assert!(result.message.contains("not found"));
    }

    // NOTE: test_install_binary_success and test_install_binary_returns_path_on_success
    // have been removed because they MODIFY THE REAL ~/.local/bin/hud-hook file.
    // This caused production bugs where the real hook binary was replaced with a dummy
    // test script, breaking session tracking for all users.
    //
    // If install_binary_from_path() needs testing, use integration tests that run
    // in an isolated environment, not unit tests that affect the developer's machine.
}
