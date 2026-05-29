use super::env::{which, which_with_fallback};
use super::paths::resolve_symlink_target;
use super::{DependencyStatus, HookStatus, SetupChecker};
use fs_err as fs;
use std::fmt;
use std::process::Command;

/// Typed failure modes from probing the hook binary. Replaces the previous
/// string-packed `SYMLINK_BROKEN:target:reason` scheme that `check_hooks_status`
/// had to `splitn`-parse back. `check_hooks_status` matches on these variants
/// directly; the `Display` impl preserves the exact human-facing message text
/// (notably "missing required subcommands", which a test asserts on).
#[derive(Debug)]
pub(super) enum BinaryProbeError {
    /// Symlink exists but its target is missing (app moved or repo cleaned).
    SymlinkBroken { target: String, reason: String },
    /// Binary path does not exist.
    NotFound,
    /// Binary was killed by macOS (exit 137) — typically a Gatekeeper SIGKILL.
    KilledByMacos,
    /// Binary ran but `--help` failed with a non-success exit code.
    ProbeFailed { code: i32, stderr: String },
    /// `--help` succeeded but the output lacked required subcommands.
    MissingSubcommands,
    /// Failed to spawn the binary process at all.
    SpawnFailed { message: String },
}

impl fmt::Display for BinaryProbeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BinaryProbeError::SymlinkBroken { reason, .. } => write!(f, "{reason}"),
            BinaryProbeError::NotFound => write!(f, "Binary not found"),
            BinaryProbeError::KilledByMacos => {
                write!(
                    f,
                    "Binary killed by macOS (exit 137). Try reinstalling the app."
                )
            }
            BinaryProbeError::ProbeFailed { code, stderr } => {
                write!(f, "Binary failed --help probe (exit {code}): {stderr}")
            }
            BinaryProbeError::MissingSubcommands => {
                write!(f, "Binary missing required subcommands (`serve` and `cwd`)")
            }
            BinaryProbeError::SpawnFailed { message } => {
                write!(f, "Failed to run binary: {message}")
            }
        }
    }
}

impl SetupChecker {
    pub(super) fn check_all_dependencies(&self) -> Vec<DependencyStatus> {
        vec![
            self.check_hud_hook(),
            self.check_tmux(),
            self.check_claude(),
        ]
    }

    fn check_hud_hook(&self) -> DependencyStatus {
        let path = which("hud-hook").or_else(|| {
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

    pub(super) fn check_tmux(&self) -> DependencyStatus {
        let path = which("tmux");
        DependencyStatus {
            name: "tmux".to_string(),
            required: false,
            found: path.is_some(),
            path,
            install_hint: Some("brew install tmux".to_string()),
        }
    }

    pub(super) fn check_claude(&self) -> DependencyStatus {
        let path = which_with_fallback(
            "claude",
            &["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
        );

        DependencyStatus {
            name: "claude".to_string(),
            required: true,
            found: path.is_some(),
            path,
            install_hint: Some("Install from claude.ai/download".to_string()),
        }
    }

    pub(crate) fn check_hooks_status(&self) -> HookStatus {
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

        if let Err(error) = self.verify_hook_binary() {
            return match error {
                BinaryProbeError::SymlinkBroken { target, reason } => {
                    HookStatus::SymlinkBroken { target, reason }
                }
                other => HookStatus::BinaryBroken {
                    reason: other.to_string(),
                },
            };
        }

        self.hooks_registered_in_settings()
    }

    pub(super) fn check_policy_blocks(&self) -> Option<String> {
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

    pub(super) fn verify_hook_binary(&self) -> Result<(), BinaryProbeError> {
        let binary_path = self.get_hook_binary_path();

        match resolve_symlink_target(&binary_path) {
            Ok(Some(target)) if !target.target_path.exists() => {
                return Err(BinaryProbeError::SymlinkBroken {
                    target: target.target_path.display().to_string(),
                    reason: "Symlink target no longer exists. \
                             The app may have moved or `cargo clean` was run."
                        .to_string(),
                });
            }
            Ok(_) => {}
            Err(message) => return Err(BinaryProbeError::SpawnFailed { message }),
        }

        if !binary_path.exists() {
            return Err(BinaryProbeError::NotFound);
        }

        let output = Command::new(&binary_path)
            .arg("--help")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output();

        match output {
            Ok(output) => {
                let code = output.status.code().unwrap_or(-1);
                if code == 137 {
                    return Err(BinaryProbeError::KilledByMacos);
                }
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(BinaryProbeError::ProbeFailed {
                        code,
                        stderr: stderr.trim().to_string(),
                    });
                }

                let stdout = String::from_utf8_lossy(&output.stdout);
                if !(stdout.contains("serve") && stdout.contains("cwd")) {
                    return Err(BinaryProbeError::MissingSubcommands);
                }

                Ok(())
            }
            Err(e) => Err(BinaryProbeError::SpawnFailed {
                message: e.to_string(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::env::managed_command_hook_command;
    use super::super::test_support::{
        env_lock, install_working_hook_binary, setup_test_env, write_executable_script, EnvVarGuard,
    };
    use super::super::{HookStatus, SetupChecker};
    use fs_err as fs;

    #[test]
    fn test_check_hooks_not_installed() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();
        assert!(matches!(status, HookStatus::NotInstalled));
    }

    #[cfg(unix)]
    #[test]
    fn test_hooks_status_settings_unreadable() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
        install_working_hook_binary(temp.path());
        fs::write(storage.claude_settings_file(), "{ invalid json }").unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(
            matches!(status, HookStatus::SettingsUnreadable { .. }),
            "status was {status:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_hooks_status_partially_configured() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
        install_working_hook_binary(temp.path());
        let command = managed_command_hook_command();
        let partial = serde_json::json!({
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "UserPromptSubmit": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": command.clone()}]}],
                "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": command.clone()}]}],
                "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": command.clone()}]}],
                "PostToolUseFailure": [{"matcher": "*", "hooks": [{"type": "command", "command": command.clone()}]}],
                "Notification": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "Stop": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "SubagentStart": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "SubagentStop": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "PreCompact": [{"hooks": [{"type": "command", "command": command.clone()}]}],
                "TeammateIdle": [{"hooks": [{"type": "command", "command": command}]}]
            }
        });
        fs::write(
            storage.claude_settings_file(),
            serde_json::to_string_pretty(&partial).unwrap(),
        )
        .unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(
            matches!(
                &status,
                HookStatus::PartiallyConfigured { missing_events, .. }
                    if missing_events
                        == &vec![
                            "TaskCompleted".to_string(),
                            "SessionEnd".to_string(),
                        ]
            ),
            "status was {status:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_hooks_status_not_installed_when_no_hooks_key() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
        install_working_hook_binary(temp.path());
        fs::write(storage.claude_settings_file(), r#"{"theme":"dark"}"#).unwrap();

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(matches!(status, HookStatus::NotInstalled));
    }

    #[cfg(unix)]
    #[test]
    fn test_hooks_status_not_installed_when_no_settings_file() {
        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let _home_guard = EnvVarGuard::set("HOME", temp.path());
        install_working_hook_binary(temp.path());

        let checker = SetupChecker::new(storage);
        let status = checker.check_hooks_status();

        assert!(matches!(status, HookStatus::NotInstalled));
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
        // The typed error's Display text must still contain the load-bearing
        // "missing required subcommands" phrase after the BinaryProbeError move.
        assert!(
            result
                .as_ref()
                .err()
                .is_some_and(|error| error.to_string().contains("missing required subcommands")),
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
            matches!(status, HookStatus::Installed),
            "check_hooks_status should accept valid relative symlink targets, got: {status:?}"
        );
    }
}
