use super::env::{
    apply_managed_contract, inner_hook_matches_managed_contract, is_managed_hook,
    managed_inner_hook, matcher_matches_all_tools,
};
use super::{HookSettingsStatus, SetupChecker};
use crate::runtime::contracts::{managed_hook_event_contracts, ClaudeHookEventContract};
use crate::runtime::error::HudFfiError;
use fs_err as fs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use tempfile::NamedTempFile;

#[derive(Debug, Default, Serialize, Deserialize)]
pub(super) struct SettingsFile {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) hooks: Option<HashMap<String, Vec<HookConfig>>>,
    #[serde(flatten)]
    pub(super) other: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct HookConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) matcher: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) hooks: Option<Vec<InnerHook>>,
    #[serde(flatten)]
    pub(super) other: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct InnerHook {
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub(super) hook_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) url: Option<String>,
    #[serde(rename = "async", skip_serializing_if = "Option::is_none")]
    pub(super) async_hook: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) timeout: Option<u32>,
    #[serde(flatten)]
    pub(super) other: HashMap<String, serde_json::Value>,
}

impl SetupChecker {
    pub(super) fn hooks_registered_in_settings(&self) -> HookSettingsStatus {
        let settings_path = self.storage.claude_settings_file();
        if !settings_path.exists() {
            return HookSettingsStatus::NotInstalled;
        }

        let content = match fs::read_to_string(&settings_path) {
            Ok(c) => c,
            Err(error) => {
                return HookSettingsStatus::SettingsUnreadable {
                    reason: format!("Failed to read settings.json: {error}"),
                };
            }
        };

        let settings: SettingsFile = match serde_json::from_str(&content) {
            Ok(s) => s,
            Err(error) => {
                return HookSettingsStatus::SettingsUnreadable {
                    reason: format!("Failed to parse settings.json: {error}"),
                };
            }
        };

        let hooks = match settings.hooks {
            Some(h) => h,
            None => return HookSettingsStatus::NotInstalled,
        };

        let missing_events: Vec<String> = managed_hook_event_contracts()
            .filter_map(|contract| {
                let has_hook = hooks
                    .get(contract.event_name)
                    .map(|configured_hooks| {
                        self.has_hud_hook_with_correct_config(configured_hooks, contract)
                    })
                    .unwrap_or(false);

                if has_hook {
                    None
                } else {
                    Some(contract.event_name.to_string())
                }
            })
            .collect();

        if missing_events.is_empty() {
            HookSettingsStatus::Installed
        } else {
            HookSettingsStatus::PartiallyConfigured {
                reason: format!(
                    "Missing or invalid managed hook configuration for {} event(s)",
                    missing_events.len()
                ),
                missing_events,
            }
        }
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

    pub(super) fn normalize_hud_hook_config(
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

            for hook_config in event_hooks.iter_mut() {
                self.normalize_hud_hook_config(hook_config, contract);
            }

            let mut already_has_hud_hook = false;
            let mut seen_managed_hook = false;
            event_hooks.retain(|hook_config| {
                let is_managed_entry = hook_config
                    .hooks
                    .as_ref()
                    .map(|inner_hooks| inner_hooks.iter().any(is_managed_hook))
                    .unwrap_or(false);

                if is_managed_entry {
                    if seen_managed_hook {
                        return false;
                    }
                    seen_managed_hook = true;
                    already_has_hud_hook = true;
                }

                true
            });

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

    pub(super) fn remove_managed_inner_hooks(&self, hook_config: &mut HookConfig) -> u32 {
        let Some(inner_hooks) = hook_config.hooks.as_mut() else {
            return 0;
        };

        let before_len = inner_hooks.len();
        inner_hooks.retain(|hook| !is_managed_hook(hook));
        (before_len.saturating_sub(inner_hooks.len())) as u32
    }

    pub(super) fn hook_config_has_remaining_hooks(&self, hook_config: &HookConfig) -> bool {
        hook_config
            .hooks
            .as_ref()
            .map(|inner_hooks| !inner_hooks.is_empty())
            .unwrap_or(true)
    }

    pub(super) fn load_settings_file(
        &self,
        settings_path: &PathBuf,
    ) -> Result<SettingsFile, HudFfiError> {
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

    pub(super) fn persist_settings_file(
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
