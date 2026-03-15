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

use crate::runtime_contracts::{
    managed_hook_event_contracts, ClaudeHookEventContract, HookTransport,
};
use crate::runtime_error::HudFfiError;
use crate::runtime_storage::StorageConfig;
use fs_err as fs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::NamedTempFile;

/// Default HTTP hook endpoint for the local `hud-hook serve` server.
const HOOK_HTTP_URL: &str = "http://127.0.0.1:7474/hook";

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

struct ResolvedSymlinkTarget {
    target_path: PathBuf,
    canonical_target: Option<PathBuf>,
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

        let binary_path = self.get_hook_binary_path();
        let symlink_target = match resolve_symlink_target(&binary_path) {
            Ok(target) => target,
            Err(reason) => return HookStatus::BinaryBroken { reason },
        };

        if let Some(target) = symlink_target.as_ref() {
            if !target.target_path.exists() {
                return HookStatus::SymlinkBroken {
                    target: target.target_path.to_string_lossy().to_string(),
                    reason: "Symlink target no longer exists. The app may have moved or `cargo clean` was run.".to_string(),
                };
            }
        }

        if !binary_path.exists() && symlink_target.is_none() {
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

        // Check if hooks are registered in settings and match the current contract.
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

        if let Some(target) = resolve_symlink_target(&binary_path)? {
            if !target.target_path.exists() {
                return Err(format!(
                    "SYMLINK_BROKEN:{}:Symlink target no longer exists. \
                     The app may have moved or `cargo clean` was run.",
                    target.target_path.display()
                ));
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

        for contract in managed_hook_event_contracts() {
            let has_hook = hooks
                .get(contract.event_name)
                .map(|h| self.has_hud_hook_with_correct_config(h, contract))
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
        contract: &ClaudeHookEventContract,
    ) -> bool {
        for hook_config in hooks {
            let has_managed_hook = hook_config
                .hooks
                .as_ref()
                .map(|inner| {
                    inner
                        .iter()
                        .any(|hook| inner_hook_matches_managed_contract(hook, contract))
                })
                .unwrap_or(false);

            if has_managed_hook {
                if contract.needs_matcher {
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

    /// Normalizes existing Capacitor-managed hooks to the current contract shape.
    ///
    /// Only current managed hooks and outdated managed transport choices are
    /// rewritten in-place to the contract's current managed transport.
    fn normalize_hud_hook_config(
        &self,
        hook_config: &mut HookConfig,
        contract: &ClaudeHookEventContract,
    ) -> bool {
        let mut has_hud_hook = false;

        if let Some(inner_hooks) = hook_config.hooks.as_mut() {
            for hook in inner_hooks.iter_mut() {
                if inner_hook_matches_managed_contract(hook, contract) {
                    has_hud_hook = true;
                    continue;
                }
                if is_managed_hook(hook) {
                    apply_managed_contract(hook, contract);
                    has_hud_hook = true;
                }
            }
        }

        if has_hud_hook && contract.needs_matcher {
            let matcher_ok = hook_config
                .matcher
                .as_ref()
                .map(matcher_matches_all_tools)
                .unwrap_or(false);
            if !matcher_ok {
                hook_config.matcher = Some(serde_json::Value::String("*".to_string()));
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
        if let Ok(Some(current_target)) = resolve_symlink_target(&dest_path) {
            if current_target
                .canonical_target
                .as_ref()
                .is_some_and(|target| target == &source_abs)
            {
                return Ok(InstallResult {
                    success: true,
                    message: "Hook binary symlink already correct".to_string(),
                    script_path: Some(dest_path.to_string_lossy().to_string()),
                });
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
            for hook_config in event_hooks.iter_mut() {
                removed_count += self.remove_managed_inner_hooks(hook_config);
            }
            event_hooks.retain(|hook_config| self.hook_config_has_remaining_hooks(hook_config));
            !event_hooks.is_empty()
        });

        if hooks.is_empty() {
            settings.hooks = None;
        }

        self.persist_settings_file(&settings_path, &settings)?;

        Ok(InstallResult {
            success: true,
            message: format!("Removed {removed_count} Capacitor-managed hook(s)"),
            script_path: Some(settings_path.to_string_lossy().to_string()),
        })
    }

    /// Registers managed hooks in settings.json for all contract-managed events.
    ///
    /// Normalizes existing managed hooks to the current transport contract and
    /// adds any missing managed hook entries.
    pub(crate) fn register_hooks_in_settings(&self) -> Result<(), HudFfiError> {
        let settings_path = self.storage.claude_settings_file();
        let mut settings = if settings_path.exists() {
            self.load_settings_file(&settings_path)?
        } else {
            SettingsFile::default()
        };

        let hooks = settings.hooks.get_or_insert_with(HashMap::new);

        for contract in managed_hook_event_contracts() {
            let event_hooks = hooks.entry(contract.event_name.to_string()).or_default();

            // Normalize any existing managed entries to the current contract,
            // then check if we already have a conforming one.
            let mut already_has_hud_hook = false;
            for hook_config in event_hooks.iter_mut() {
                if self.normalize_hud_hook_config(hook_config, contract) {
                    already_has_hud_hook = true;
                }
            }

            if !already_has_hud_hook {
                let hook_config = HookConfig {
                    matcher: if contract.needs_matcher {
                        Some(serde_json::Value::String("*".to_string()))
                    } else {
                        None
                    },
                    hooks: Some(vec![managed_inner_hook(contract)]),
                    other: HashMap::new(),
                };

                event_hooks.push(hook_config);
            }
        }

        self.persist_settings_file(&settings_path, &settings)
    }

    fn remove_managed_inner_hooks(&self, hook_config: &mut HookConfig) -> u32 {
        let Some(inner_hooks) = hook_config.hooks.as_mut() else {
            return 0;
        };

        let before_len = inner_hooks.len();
        inner_hooks.retain(|hook| !is_managed_hook(hook));
        (before_len.saturating_sub(inner_hooks.len())) as u32
    }

    fn hook_config_has_remaining_hooks(&self, hook_config: &HookConfig) -> bool {
        hook_config
            .hooks
            .as_ref()
            .map(|inner_hooks| !inner_hooks.is_empty())
            .unwrap_or(true)
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

fn resolve_symlink_target(path: &Path) -> Result<Option<ResolvedSymlinkTarget>, String> {
    if !path.is_symlink() {
        return Ok(None);
    }

    let target = fs::read_link(path).map_err(|e| format!("Cannot read symlink: {}", e))?;
    let target_path = if target.is_absolute() {
        target
    } else {
        path.parent()
            .map(|parent| parent.join(&target))
            .unwrap_or(target)
    };

    let canonical_target = fs::canonicalize(&target_path).ok();
    Ok(Some(ResolvedSymlinkTarget {
        target_path,
        canonical_target,
    }))
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

fn is_managed_hook_command(cmd: Option<&str>) -> bool {
    let Some(command) = cmd else {
        return false;
    };
    is_current_managed_hook_command(Some(command))
}

/// Check if a URL is the HUD hook HTTP endpoint.
fn is_hud_hook_url(url: Option<&str>) -> bool {
    match url {
        Some(u) => u.trim() == HOOK_HTTP_URL,
        None => false,
    }
}

/// Check if an InnerHook is managed by Capacitor (either command or HTTP).
fn is_managed_hook(hook: &InnerHook) -> bool {
    is_managed_hook_command(
        hook.command
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty()),
    ) || is_hud_hook_url(hook.url.as_deref())
}

fn managed_command_hook_command() -> String {
    format!(
        "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"{url}\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'",
        url = HOOK_HTTP_URL
    )
}

fn is_current_managed_hook_command(cmd: Option<&str>) -> bool {
    let Some(command) = cmd else {
        return false;
    };
    command.trim() == managed_command_hook_command()
}

fn managed_inner_hook(contract: &ClaudeHookEventContract) -> InnerHook {
    let transport = contract
        .managed_transport
        .expect("managed hook contract must declare a transport");
    if transport == HookTransport::Http {
        InnerHook {
            hook_type: Some("http".to_string()),
            command: None,
            url: Some(HOOK_HTTP_URL.to_string()),
            async_hook: None,
            timeout: None,
            other: HashMap::new(),
        }
    } else {
        debug_assert_eq!(transport, HookTransport::Command);
        InnerHook {
            hook_type: Some("command".to_string()),
            command: Some(managed_command_hook_command()),
            url: None,
            async_hook: None,
            timeout: None,
            other: HashMap::new(),
        }
    }
}

fn apply_managed_contract(hook: &mut InnerHook, contract: &ClaudeHookEventContract) {
    let transport = contract
        .managed_transport
        .expect("managed hook contract must declare a transport");
    if transport == HookTransport::Http {
        hook.hook_type = Some("http".to_string());
        hook.url = Some(HOOK_HTTP_URL.to_string());
        hook.command = None;
        hook.async_hook = None;
        hook.timeout = None;
    } else {
        debug_assert_eq!(transport, HookTransport::Command);
        {
            hook.hook_type = Some("command".to_string());
            hook.command = Some(managed_command_hook_command());
            hook.url = None;
            hook.async_hook = None;
            hook.timeout = None;
        }
    }
}

fn inner_hook_matches_managed_contract(
    hook: &InnerHook,
    contract: &ClaudeHookEventContract,
) -> bool {
    if let Some(transport) = contract.managed_transport {
        if transport == HookTransport::Http {
            return is_hud_hook_url(hook.url.as_deref());
        }
        debug_assert_eq!(transport, HookTransport::Command);
        return is_current_managed_hook_command(hook.command.as_deref());
    }
    false
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
    use crate::runtime_state::snapshot::test_support::env_lock as shared_env_lock;
    use tempfile::TempDir;

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
        shared_env_lock()
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

    fn retired_handle_command() -> String {
        ["hud-hook", "handle"].join(" ")
    }

    fn retired_prefixed_handle_command() -> String {
        format!(
            "CAPACITOR_CORE_ENABLED=1 $HOME/.local/bin/{}",
            retired_handle_command()
        )
    }

    fn retired_state_tracker_command() -> String {
        ["hud", "state", "tracker"].join("-")
    }

    fn marker_prefixed_managed_command() -> String {
        format!(
            "{} {}",
            ["CAPACITOR", "HOOK", "MARKER=1"].join("_"),
            managed_command_hook_command()
        )
    }

    #[test]
    fn test_check_hooks_not_installed() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
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
    fn test_register_hooks_in_settings_uses_command_for_command_only_events_and_http_for_http_events(
    ) {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        checker.register_hooks_in_settings().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(
            settings["hooks"]["SessionStart"][0]["hooks"][0]["type"],
            "command"
        );
        assert!(settings["hooks"]["SessionStart"][0]["hooks"][0]["command"]
            .as_str()
            .is_some_and(|value| value.contains("/usr/bin/curl") && value.contains("/hook")));

        assert_eq!(
            settings["hooks"]["PreToolUse"][0]["hooks"][0]["type"],
            "http"
        );
        assert_eq!(
            settings["hooks"]["PreToolUse"][0]["hooks"][0]["url"],
            HOOK_HTTP_URL
        );
    }

    #[test]
    fn test_register_hooks_preserves_noncanonical_flat_entries() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let noncanonical = format!(
            r#"{{
                "hooks": {{
                    "SessionStart": [{{"type": "command", "command": "$HOME/.local/bin/{session_start}"}}],
                    "SessionEnd": [{{"type": "command", "command": "{session_end}"}}],
                    "CustomEvent": [{{"type": "command", "command": "custom.sh"}}]
                }}
            }}"#,
            session_start = retired_handle_command(),
            session_end = retired_state_tracker_command(),
        );
        fs::write(storage.claude_settings_file(), noncanonical).unwrap();

        checker.register_hooks_in_settings().unwrap();

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        let session_start = settings["hooks"]["SessionStart"]
            .as_array()
            .expect("SessionStart should remain an array");
        assert_eq!(session_start.len(), 2);
        assert_eq!(
            session_start[0]["command"],
            format!("$HOME/.local/bin/{}", retired_handle_command())
        );
        assert!(session_start[0]["hooks"].is_null());
        assert_eq!(session_start[1]["hooks"][0]["type"], "command");
        assert_eq!(
            session_start[1]["hooks"][0]["command"],
            managed_command_hook_command()
        );

        assert_eq!(settings["hooks"]["CustomEvent"][0]["command"], "custom.sh");
        assert!(
            settings["hooks"]["CustomEvent"][0]["hooks"].is_null(),
            "unrelated flat entries should stay untouched in the current contract path"
        );
        assert!(checker.hooks_registered_in_settings());
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
        let binary_path = bin_dir.join("hud-hook");
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
        let binary_path = bin_dir.join("hud-hook");
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
        let binary_path = bin_dir.join("hud-hook");
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

    #[cfg(unix)]
    #[test]
    fn test_verify_hook_binary_accepts_relative_symlink_target() {
        use std::os::unix::fs::symlink;

        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let build_dir = home.join("build");
        fs::create_dir_all(&build_dir).expect("create build dir");
        let source_binary = build_dir.join("hud-hook");
        write_executable_script(
            &source_binary,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve cwd\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let symlink_path = bin_dir.join("hud-hook");
        symlink("../../build/hud-hook", &symlink_path).expect("create relative symlink");

        let checker = SetupChecker::new(storage);
        let result = checker.verify_hook_binary();
        assert!(
            result.is_ok(),
            "verify_hook_binary should accept valid relative symlink targets, got: {result:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_check_hooks_status_accepts_relative_symlink_target() {
        use std::os::unix::fs::symlink;

        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let build_dir = home.join("build");
        fs::create_dir_all(&build_dir).expect("create build dir");
        let source_binary = build_dir.join("hud-hook");
        write_executable_script(
            &source_binary,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve cwd\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let symlink_path = bin_dir.join("hud-hook");
        symlink("../../build/hud-hook", &symlink_path).expect("create relative symlink");

        let checker = SetupChecker::new(storage.clone());
        checker.register_hooks_in_settings().unwrap();

        let status = checker.check_hooks_status();
        assert!(
            matches!(status, HookStatus::Installed { .. }),
            "check_hooks_status should accept valid relative symlink targets, got: {status:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_install_binary_from_path_keeps_relative_symlink_to_same_target() {
        use std::os::unix::fs::symlink;

        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let build_dir = home.join("build");
        fs::create_dir_all(&build_dir).expect("create build dir");
        let source_binary = build_dir.join("hud-hook");
        write_executable_script(
            &source_binary,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve cwd\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let symlink_path = bin_dir.join("hud-hook");
        symlink("../../build/hud-hook", &symlink_path).expect("create relative symlink");

        let checker = SetupChecker::new(storage);
        let result = checker
            .install_binary_from_path(source_binary.to_string_lossy().as_ref())
            .expect("install binary from path");
        assert!(result.success);
        assert!(
            result.message.contains("already correct"),
            "relative symlink to the same binary should be preserved, got: {}",
            result.message
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
        let partial = format!(
            r#"{{
                "hooks": {{
                    "SessionStart": [{{"hooks": [{{"type": "command", "command": "{command}"}}]}}]
                }}
            }}"#,
            command = managed_command_hook_command(),
        );
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
                "SessionStart": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "SessionEnd": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "UserPromptSubmit": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PreToolUse": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PostToolUse": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PostToolUseFailure": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PermissionRequest": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "Stop": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "PreCompact": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "Notification": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "SubagentStart": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "SubagentStop": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}],
                "TeammateIdle": [{"hooks": [{"type": "command", "command": "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"http://127.0.0.1:7474/hook\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'"}]}],
                "TaskCompleted": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:7474/hook"}]}]
            }
        }"#;
        fs::write(storage.claude_settings_file(), missing_matcher).unwrap();

        // hooks_registered_in_settings should return false since matcher is missing
        assert!(!checker.hooks_registered_in_settings());
    }

    #[test]
    fn test_hooks_registered_rejects_http_transport_for_command_only_event() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let invalid = format!(
            r#"{{
                "hooks": {{
                    "SessionStart": [{{
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "SessionEnd": [{{
                        "hooks": [{{"type": "command", "command": "{command}"}}]
                    }}],
                    "UserPromptSubmit": [{{
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "PreToolUse": [{{
                        "matcher": "*",
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "PostToolUse": [{{
                        "matcher": "*",
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "PostToolUseFailure": [{{
                        "matcher": "*",
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "PermissionRequest": [{{
                        "matcher": "*",
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "Stop": [{{
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "PreCompact": [{{
                        "hooks": [{{"type": "command", "command": "{command}"}}]
                    }}],
                    "Notification": [{{
                        "hooks": [{{"type": "command", "command": "{command}"}}]
                    }}],
                    "SubagentStart": [{{
                        "hooks": [{{"type": "command", "command": "{command}"}}]
                    }}],
                    "SubagentStop": [{{
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}],
                    "TeammateIdle": [{{
                        "hooks": [{{"type": "command", "command": "{command}"}}]
                    }}],
                    "TaskCompleted": [{{
                        "hooks": [{{"type": "http", "url": "{hook_url}"}}]
                    }}]
                }}
            }}"#,
            hook_url = HOOK_HTTP_URL,
            command = managed_command_hook_command(),
        );
        fs::write(storage.claude_settings_file(), invalid).unwrap();

        assert!(
            !checker.hooks_registered_in_settings(),
            "SessionStart is command-only and should reject HTTP configuration"
        );
    }

    #[test]
    fn test_is_managed_hook_command_accepts_only_current_contract_command() {
        let cases = [
            (managed_command_hook_command(), true),
            (marker_prefixed_managed_command(), false),
            (retired_prefixed_handle_command(), false),
            (
                format!("$HOME/.local/bin/{}", retired_handle_command()),
                false,
            ),
            (retired_handle_command(), false),
            (retired_state_tracker_command(), false),
            (format!("echo {}", retired_handle_command()), false),
            ("custom-hud-hook-wrapper handle".to_string(), false),
            ("python -c \"print('hud-hook')\"".to_string(), false),
        ];

        for (cmd, expected) in cases {
            assert_eq!(
                is_managed_hook_command(Some(cmd.as_str())),
                expected,
                "command mismatch for: {cmd}"
            );
        }
    }

    #[test]
    fn test_normalize_hud_hook_config_does_not_rewrite_unrelated_commands() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage);

        let original = format!("echo {}", retired_handle_command());
        let mut hook_config = HookConfig {
            matcher: None,
            hooks: Some(vec![InnerHook {
                hook_type: Some("command".to_string()),
                command: Some(original.clone()),
                url: None,
                async_hook: None,
                timeout: None,
                other: HashMap::new(),
            }]),
            other: HashMap::new(),
        };

        let contract = managed_hook_event_contracts()
            .find(|contract| contract.event_name == "SessionStart")
            .expect("managed contract exists");
        let normalized = checker.normalize_hud_hook_config(&mut hook_config, contract);
        assert!(!normalized);

        let hook = hook_config
            .hooks
            .as_ref()
            .and_then(|hooks| hooks.first())
            .expect("hook exists");
        // Unrelated command should not be modified
        assert_eq!(hook.command.as_deref(), Some(original.as_str()));
        assert_eq!(hook.async_hook, None);
        assert_eq!(hook.timeout, None);
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

        let existing = serde_json::json!({
            "someOtherSetting": "value",
            "hooks": {
                "SessionStart": [
                    {"hooks": [{"type": "command", "command": managed_command_hook_command()}]},
                    {"hooks": [{"type": "command", "command": "custom-start.sh"}]}
                ],
                "SessionEnd": [
                    {"type": "command", "command": retired_state_tracker_command()}
                ],
                "PostToolUse": [
                    {"matcher": {"tools": ["BashTool"]}, "hooks": [{"type": "command", "command": "custom-post-tool.sh"}]}
                ]
            }
        });
        fs::write(
            storage.claude_settings_file(),
            serde_json::to_string_pretty(&existing).unwrap(),
        )
        .unwrap();

        let result = checker.remove_hooks().unwrap();
        assert!(result.success);
        assert!(result.message.contains("Removed 1"));

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(settings["someOtherSetting"], "value");
        assert_eq!(
            settings["hooks"]["SessionStart"][0]["hooks"][0]["command"],
            "custom-start.sh"
        );
        assert!(
            settings["hooks"]["SessionEnd"].is_array(),
            "retired entries are no longer auto-removed as managed hooks"
        );
        assert_eq!(
            settings["hooks"]["SessionEnd"][0]["command"],
            retired_state_tracker_command()
        );
        assert_eq!(
            settings["hooks"]["PostToolUse"][0]["hooks"][0]["command"],
            "custom-post-tool.sh"
        );
    }

    #[test]
    fn test_remove_hooks_preserves_custom_inner_hooks_in_mixed_entry() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage.clone());

        let existing = serde_json::json!({
            "someOtherSetting": "value",
            "hooks": {
                "SessionStart": [
                    {
                        "hooks": [
                            {"type": "command", "command": managed_command_hook_command()},
                            {"type": "command", "command": "custom-start.sh"}
                        ]
                    }
                ]
            }
        });
        fs::write(
            storage.claude_settings_file(),
            serde_json::to_string_pretty(&existing).unwrap(),
        )
        .unwrap();

        let result = checker.remove_hooks().unwrap();
        assert!(result.success);

        let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
        let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

        assert_eq!(settings["someOtherSetting"], "value");
        assert_eq!(
            settings["hooks"]["SessionStart"][0]["hooks"][0]["command"],
            "custom-start.sh"
        );
        assert_eq!(
            settings["hooks"]["SessionStart"][0]["hooks"]
                .as_array()
                .map(Vec::len),
            Some(1),
            "only the custom inner hook should remain after managed hooks are removed"
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
    // have been removed because they MODIFY THE REAL ~/.local/bin/hud-hook file.
    // This caused production bugs where the real hook binary was replaced with a dummy
    // test script, breaking session tracking for all users.
    //
    // If install_binary_from_path() needs testing, use integration tests that run
    // in an isolated environment, not unit tests that affect the developer's machine.
}
