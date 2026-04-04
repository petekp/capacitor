use super::{InstallResult, SetupChecker};
use crate::runtime::error::HudFfiError;

impl SetupChecker {
    pub(crate) fn install_hooks(&self) -> Result<InstallResult, HudFfiError> {
        if let Some(reason) = self.check_policy_blocks() {
            return Ok(InstallResult {
                success: false,
                message: format!("Cannot install hooks: {}", reason),
                script_path: None,
            });
        }

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

    pub(crate) fn remove_hooks(&self) -> Result<InstallResult, HudFfiError> {
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
}

#[cfg(test)]
mod tests {
    use super::super::env::managed_command_hook_command;
    use super::super::test_support::{
        env_lock, retired_state_tracker_command, setup_test_env, EnvVarGuard,
    };
    use super::super::SetupChecker;
    use fs_err as fs;

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
}
