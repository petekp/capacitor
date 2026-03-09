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

use crate::runtime_error::HudFfiError;
use crate::runtime_storage::StorageConfig;
use fs_err as fs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;
use tempfile::NamedTempFile;

/// Default HTTP hook endpoint for the local `capacitor-hook serve` server.
const HOOK_HTTP_URL: &str = "http://127.0.0.1:7474/hook";

/// Hook event configuration: (event_name, needs_matcher)
/// - `needs_matcher`: Tool events like PreToolUse/PostToolUse/PostToolUseFailure/PermissionRequest
///   need `matcher: "*"` to match all tools.
const CAPACITOR_HOOK_EVENTS: [(&str, bool); 14] = [
    ("SessionStart", false),
    ("SessionEnd", false),
    ("UserPromptSubmit", false),
    ("PreToolUse", true),
    ("PostToolUse", true),
    ("PostToolUseFailure", true),
    ("PermissionRequest", true),
    ("Stop", false),
    ("PreCompact", false),
    ("Notification", false),
    ("SubagentStart", false),
    ("SubagentStop", false),
    ("TeammateIdle", false),
    ("TaskCompleted", false),
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
            self.check_capacitor_hook(),
            self.check_tmux(),
            self.check_claude(),
        ]
    }

    fn check_capacitor_hook(&self) -> DependencyStatus {
        // Check for the Rust hook handler binary
        let path = which("capacitor-hook").or_else(|| {
            // Also check the standard install location
            dirs::home_dir()
                .map(|h| h.join(".local/bin/capacitor-hook"))
                .filter(|p| p.exists())
                .map(|p| p.to_string_lossy().to_string())
        });

        DependencyStatus {
            name: "capacitor-hook".to_string(),
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
            .map(|h| h.join(".local/bin/capacitor-hook"))
            .unwrap_or_else(|| PathBuf::from("/usr/local/bin/capacitor-hook"))
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

        // Probe a supported CLI path and verify expected command surface.
        let output = Command::new(&binary_path)
            .arg("--help")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output();

        match output {
            Ok(output) => {
                let code = output.status.code().unwrap_or(-1);
                if code == 137 {
                    // SIGKILL - macOS killed unsigned binary
                    // This shouldn't happen with symlinks, but catch it anyway
                    return Err(
                        "Binary killed by macOS (exit 137). Try reinstalling the app.".to_string(),
                    );
                }
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(format!(
                        "Binary failed --help probe (exit {}): {}",
                        code,
                        stderr.trim()
                    ));
                }

                let stdout = String::from_utf8_lossy(&output.stdout);
                if !(stdout.contains("serve") && stdout.contains("cwd")) {
                    return Err(
                        "Binary missing required subcommands (`serve` and `cwd`)".to_string()
                    );
                }

                Ok(())
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

        for (event, needs_matcher) in CAPACITOR_HOOK_EVENTS {
            let has_hook = hooks
                .get(event)
                .map(|h| self.has_capacitor_hook_with_correct_config(h, needs_matcher))
                .unwrap_or(false);

            if !has_hook {
                return false;
            }
        }

        true
    }

    fn has_capacitor_hook_with_correct_config(
        &self,
        hooks: &[HookConfig],
        needs_matcher: bool,
    ) -> bool {
        for hook_config in hooks {
            let has_managed_hook = hook_config
                .hooks
                .as_ref()
                .map(|inner| inner.iter().any(is_managed_hook))
                .unwrap_or(false);

            if has_managed_hook {
                if needs_matcher {
                    let matcher_ok = hook_config
                        .matcher
                        .as_ref()
                        .map(matcher_matches_all_tools)
                        .unwrap_or(false);
                    if matcher_ok {
                        return true;
                    }
                } else {
                    return true;
                }
            }
        }
        false
    }

    /// Ensures a canonical HTTP hook config still satisfies matcher requirements.
    fn ensure_canonical_capacitor_hook_config(
        &self,
        hook_config: &mut HookConfig,
        needs_matcher: bool,
    ) -> bool {
        let mut has_capacitor_hook = false;

        if let Some(inner_hooks) = hook_config.hooks.as_ref() {
            for hook in inner_hooks {
                if is_capacitor_hook_url(hook.url.as_deref()) {
                    has_capacitor_hook = true;
                }
            }
        }

        if has_capacitor_hook && needs_matcher {
            let matcher_ok = hook_config
                .matcher
                .as_ref()
                .map(matcher_matches_all_tools)
                .unwrap_or(false);
            if !matcher_ok {
                hook_config.matcher = Some(serde_json::Value::String("*".to_string()));
            }
        }

        has_capacitor_hook
    }

    fn reject_noncanonical_hook_entries(
        &self,
        hooks: &HashMap<String, Vec<HookConfig>>,
    ) -> Result<(), HudFfiError> {
        for (event, event_hooks) in hooks {
            if event_hooks
                .iter()
                .any(|hook_config| hook_config.hooks.is_none())
            {
                return Err(HudFfiError::General {
                    message: format!(
                        "Unsupported non-canonical hook entry for {event}. Remove outdated command-style hooks and try again."
                    ),
                });
            }
        }
        Ok(())
    }

    /// Installs the hook binary from a given source path to ~/.local/bin/capacitor-hook.
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

        let dest_path = dest_dir.join("capacitor-hook");

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

    pub fn remove_hooks(&self) -> Result<InstallResult, HudFfiError> {
        let settings_path = self.storage.claude_settings_file();
        if !settings_path.exists() {
            return Ok(InstallResult {
                success: true,
                message: "No Claude settings file found; nothing to remove".to_string(),
                script_path: None,
            });
        }

        let mut settings = self.load_settings_file(&settings_path)?;
        let hooks = match settings.hooks.as_mut() {
            Some(hooks) => hooks,
            None => {
                return Ok(InstallResult {
                    success: true,
                    message: "No hook entries found in Claude settings".to_string(),
                    script_path: Some(settings_path.to_string_lossy().to_string()),
                });
            }
        };

        let mut removed_count = 0u32;
        hooks.retain(|_, event_hooks| {
            let before_len = event_hooks.len();
            event_hooks.retain(|hook_config| !self.hook_config_contains_managed_hook(hook_config));
            removed_count += (before_len.saturating_sub(event_hooks.len())) as u32;
            !event_hooks.is_empty()
        });

        if hooks.is_empty() {
            settings.hooks = None;
        }

        self.persist_settings_file(&settings_path, &settings)?;

        Ok(InstallResult {
            success: true,
            message: format!("Removed {removed_count} Capacitor-managed hook entrie(s)"),
            script_path: Some(settings_path.to_string_lossy().to_string()),
        })
    }

    /// Registers HTTP hooks in settings.json for all managed events.
    ///
    /// Rejects unsupported hook shapes and adds canonical HTTP hook entries for
    /// any managed events that do not already have one.
    pub(crate) fn register_hooks_in_settings(&self) -> Result<(), HudFfiError> {
        let settings_path = self.storage.claude_settings_file();
        let mut settings = if settings_path.exists() {
            self.load_settings_file(&settings_path)?
        } else {
            SettingsFile::default()
        };

        let hooks = settings.hooks.get_or_insert_with(HashMap::new);
        self.reject_noncanonical_hook_entries(hooks)?;

        for (event, needs_matcher) in CAPACITOR_HOOK_EVENTS {
            let event_hooks = hooks.entry(event.to_string()).or_default();

            // Keep canonical HTTP hook entries in canonical matcher form.
            let mut already_has_capacitor_hook = false;
            for hook_config in event_hooks.iter_mut() {
                if self.ensure_canonical_capacitor_hook_config(hook_config, needs_matcher) {
                    already_has_capacitor_hook = true;
                }
            }

            if !already_has_capacitor_hook {
                let hook_config = HookConfig {
                    matcher: if needs_matcher {
                        Some(serde_json::Value::String("*".to_string()))
                    } else {
                        None
                    },
                    hooks: Some(vec![InnerHook {
                        hook_type: Some("http".to_string()),
                        command: None,
                        url: Some(HOOK_HTTP_URL.to_string()),
                        async_hook: None,
                        timeout: None,
                        other: HashMap::new(),
                    }]),
                    other: HashMap::new(),
                };

                event_hooks.push(hook_config);
            }
        }

        self.persist_settings_file(&settings_path, &settings)
    }

    fn hook_config_contains_managed_hook(&self, hook_config: &HookConfig) -> bool {
        hook_config
            .hooks
            .as_ref()
            .map(|inner_hooks| inner_hooks.iter().any(is_managed_hook))
            .unwrap_or(false)
    }

    fn load_settings_file(&self, settings_path: &PathBuf) -> Result<SettingsFile, HudFfiError> {
        let content = fs::read_to_string(settings_path).map_err(|e| HudFfiError::General {
            message: format!("Failed to read settings: {}", e),
        })?;
        serde_json::from_str(&content).map_err(|e| HudFfiError::General {
            message: format!(
                "Failed to parse settings.json (file may be corrupted): {}. \
                 Please fix the JSON syntax or delete the file to start fresh.",
                e
            ),
        })
    }

    fn persist_settings_file(
        &self,
        settings_path: &PathBuf,
        settings: &SettingsFile,
    ) -> Result<(), HudFfiError> {
        let content = serde_json::to_string_pretty(settings).map_err(|e| HudFfiError::General {
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
            .persist(settings_path)
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

/// Check if a URL is the HUD hook HTTP endpoint.
fn is_capacitor_hook_url(url: Option<&str>) -> bool {
    match url {
        Some(u) => u.trim() == HOOK_HTTP_URL,
        None => false,
    }
}

/// Check if an InnerHook is the canonical Capacitor-managed HTTP hook.
fn is_managed_hook(hook: &InnerHook) -> bool {
    is_capacitor_hook_url(hook.url.as_deref())
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
    matcher: Option<serde_json::Value>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    #[serde(rename = "async", skip_serializing_if = "Option::is_none")]
    async_hook: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout: Option<u32>,
    #[serde(flatten)]
    other: HashMap<String, serde_json::Value>,
}

fn matcher_matches_all_tools(matcher: &serde_json::Value) -> bool {
    match matcher {
        serde_json::Value::String(value) => value.trim() == "*",
        serde_json::Value::Object(map) => map
            .get("tools")
            .and_then(|tools| tools.as_array())
            .map(|tools| {
                tools.iter().any(|tool| {
                    tool.as_str()
                        .map(|value| value.trim() == "*")
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};
    use tempfile::TempDir;

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    struct EnvVarGuard {
        key: &'static str,
        original: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: &std::path::Path) -> Self {
            let original = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, original }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("env lock poisoned")
    }

    #[cfg(unix)]
    fn write_executable_script(path: &std::path::Path, script: &str) {
        use std::os::unix::fs::PermissionsExt;

        fs::write(path, script).expect("write script");
        let mut perms = fs::metadata(path).expect("script metadata").permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms).expect("set executable permission");
    }

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
        assert!(settings["hooks"]["PostToolUseFailure"].is_array());
        assert!(settings["hooks"]["TaskCompleted"].is_array());
        assert!(settings["hooks"]["SubagentStop"].is_array());

        let post_tool_use = &settings["hooks"]["PostToolUse"][0];
        assert_eq!(post_tool_use["matcher"], "*");

        let post_tool_use_failure = &settings["hooks"]["PostToolUseFailure"][0];
        assert_eq!(post_tool_use_failure["matcher"], "*");
    }

    #[test]
    fn test_register_hooks_preserves_object_matcher_entries() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let existing = r#"{
            "hooks": {
                "PostToolUse": [
                    {
                        "matcher": {"tools": ["BashTool"]},
                        "hooks": [{"type": "command", "command": "custom-post-tool.sh"}]
                    }
                ]
            }
        }"#;
        fs::write(storage.claude_settings_file(), existing).unwrap();

        checker.register_hooks_in_settings().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();
        let post_tool_use = settings["hooks"]["PostToolUse"]
            .as_array()
            .expect("PostToolUse should remain an array");

        assert!(
            post_tool_use.iter().any(|entry| {
                entry["matcher"]["tools"][0] == "BashTool"
                    && entry["hooks"][0]["command"] == "custom-post-tool.sh"
            }),
            "object-matcher custom entry should be preserved"
        );

        assert!(
            post_tool_use.iter().any(|entry| {
                entry["hooks"][0]["type"] == "http"
                    && entry["hooks"][0]["url"] == HOOK_HTTP_URL
                    && entry["matcher"] == "*"
            }),
            "Capacitor-managed HTTP hook should be registered"
        );
    }

    #[test]
    fn test_register_hooks_rejects_unsupported_flat_command_entries() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let existing = r#"{
            "hooks": {
                "SessionStart": [{"type": "command", "command": "$HOME/.local/bin/capacitor-hook handle"}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), existing).unwrap();

        let result = checker.register_hooks_in_settings();
        assert!(result.is_err(), "flat command entries should be rejected");

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        assert_eq!(settings_content, existing);
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
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);
        let checker = SetupChecker::new(storage);

        let result = checker.install_hooks().unwrap();

        assert!(!result.success);
        assert!(result.message.contains("not found"));
    }

    #[cfg(unix)]
    #[test]
    fn test_verify_hook_binary_rejects_unsupported_cli_shape() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let binary_path = bin_dir.join("capacitor-hook");
        write_executable_script(
            &binary_path,
            "#!/bin/sh\n\
             # Simulate a binary that is executable but does not expose supported CLI shape.\n\
             if [ \"$1\" = \"handle\" ]; then\n\
               exit 2\n\
             fi\n\
             echo \"unsupported\"\n\
             exit 2\n",
        );

        let checker = SetupChecker::new(storage);
        let result = checker.verify_hook_binary();
        assert!(
            result.is_err(),
            "verify_hook_binary should fail for unsupported CLI shape, got: {result:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_verify_hook_binary_accepts_supported_cli_shape_from_help_output() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let binary_path = bin_dir.join("capacitor-hook");
        write_executable_script(
            &binary_path,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve cwd\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let checker = SetupChecker::new(storage);
        let result = checker.verify_hook_binary();
        assert!(
            result.is_ok(),
            "verify_hook_binary should accept supported CLI shape, got: {result:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_verify_hook_binary_rejects_help_output_missing_required_subcommand() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let binary_path = bin_dir.join("capacitor-hook");
        write_executable_script(
            &binary_path,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let checker = SetupChecker::new(storage);
        let result = checker.verify_hook_binary();
        assert!(
            result
                .as_ref()
                .err()
                .is_some_and(|message| message.contains("missing required subcommands")),
            "verify_hook_binary should reject help output missing required subcommands, got: {result:?}"
        );
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
                "SessionStart": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), partial).unwrap();

        // hooks_registered_in_settings should return false since required events are missing
        assert!(!checker.hooks_registered_in_settings());
    }

    #[test]
    fn test_hooks_registered_checks_matchers() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        // Write settings with tool events but missing matcher
        let missing_matcher = r#"{
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "UserPromptSubmit": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PostToolUse": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PostToolUseFailure": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "Stop": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), missing_matcher).unwrap();

        // hooks_registered_in_settings should return false since matcher is missing
        assert!(!checker.hooks_registered_in_settings());
    }

    #[test]
    fn test_matcher_matches_all_tools_supports_string_and_object_forms() {
        assert!(matcher_matches_all_tools(&serde_json::json!("*")));
        assert!(matcher_matches_all_tools(&serde_json::json!({
            "tools": ["BashTool", "*"]
        })));
        assert!(!matcher_matches_all_tools(&serde_json::json!({
            "tools": ["BashTool"]
        })));
        assert!(!matcher_matches_all_tools(&serde_json::json!(null)));
    }

    #[test]
    fn test_remove_hooks_removes_managed_entries_but_preserves_custom_hooks_and_settings() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let existing = r#"{
            "someOtherSetting": "value",
            "hooks": {
                "SessionStart": [
                    {"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]},
                    {"hooks": [{"type": "command", "command": "custom-start.sh"}]}
                ],
                "SessionEnd": [
                    {"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}
                ],
                "PostToolUse": [
                    {"matcher": {"tools": ["BashTool"]}, "hooks": [{"type": "command", "command": "custom-post-tool.sh"}]}
                ]
            }
        }"#;
        fs::write(storage.claude_settings_file(), existing).unwrap();

        let result = checker.remove_hooks().unwrap();
        assert!(result.success);
        assert!(result.message.contains("Removed 2"));

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(settings["someOtherSetting"], "value");
        assert_eq!(
            settings["hooks"]["SessionStart"][0]["hooks"][0]["command"],
            "custom-start.sh"
        );
        assert!(
            settings["hooks"]["SessionEnd"].is_null(),
            "managed SessionEnd should be removed entirely"
        );
        assert_eq!(
            settings["hooks"]["PostToolUse"][0]["hooks"][0]["command"],
            "custom-post-tool.sh"
        );
    }

    #[test]
    fn test_remove_hooks_preserves_unsupported_flat_command_entries() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let existing = r#"{
            "hooks": {
                "SessionStart": [{"type": "command", "command": "$HOME/.local/bin/capacitor-hook handle"}],
                "SessionEnd": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), existing).unwrap();

        let result = checker.remove_hooks().unwrap();
        assert!(result.success);
        assert!(result.message.contains("Removed 1"));

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();
        assert_eq!(
            settings["hooks"]["SessionStart"][0]["command"],
            "$HOME/.local/bin/capacitor-hook handle"
        );
        assert!(
            settings["hooks"]["SessionEnd"].is_null(),
            "canonical HTTP hook should be removed entirely"
        );
    }

    #[test]
    fn test_remove_hooks_clears_hooks_key_when_only_managed_entries_exist() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        checker.register_hooks_in_settings().unwrap();
        let result = checker.remove_hooks().unwrap();
        assert!(result.success);

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();
        assert!(
            settings["hooks"].is_null(),
            "hooks key should be removed when no hook entries remain"
        );
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
    // have been removed because they MODIFY THE REAL ~/.local/bin/capacitor-hook file.
    // This caused production bugs where the real hook binary was replaced with a dummy
    // test script, breaking session tracking for all users.
    //
    // If install_binary_from_path() needs testing, use integration tests that run
    // in an isolated environment, not unit tests that affect the developer's machine.
}
