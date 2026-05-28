use super::env::{is_managed_hook, managed_command_hook_command, HOOK_HTTP_URL};
use super::settings::{HookConfig, InnerHook, SettingsFile};
use super::test_support::{retired_handle_command, retired_state_tracker_command, setup_test_env};
use super::{HookStatus, SetupChecker};
use crate::runtime::contracts::managed_hook_event_contracts;
use fs_err as fs;
use std::collections::HashMap;

#[test]
fn test_register_hooks_in_settings() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

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
fn test_register_hooks_in_settings_uses_command_transport_for_all_managed_events() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    checker.register_hooks_in_settings().unwrap();

    let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

    for contract in managed_hook_event_contracts() {
        let event = &settings["hooks"][contract.event_name];
        assert!(
            event.is_array(),
            "{} should have hooks registered",
            contract.event_name,
        );
        let inner_hook = &event[0]["hooks"][0];
        assert_eq!(
            inner_hook["type"], "command",
            "{} should use command transport",
            contract.event_name,
        );
        assert!(
            inner_hook["command"]
                .as_str()
                .is_some_and(|v| v.contains("/usr/bin/curl") && v.contains("/hook")),
            "{} should use the curl wrapper command",
            contract.event_name,
        );
    }
}

#[test]
fn test_register_hooks_in_settings_deduplicates_managed_entries_per_event() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let managed_cmd = managed_command_hook_command();
    let existing = serde_json::json!({
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": managed_cmd}]
                },
                {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": managed_command_hook_command()}]
                },
                {
                    "matcher": {"tools": ["BashTool"]},
                    "hooks": [{"type": "command", "command": "notify.sh"}]
                }
            ]
        }
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&existing).unwrap(),
    )
    .unwrap();

    checker.register_hooks_in_settings().unwrap();

    let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    let settings: SettingsFile = serde_json::from_str(&settings_content).unwrap();
    let pre_tool_use = settings
        .hooks
        .expect("hooks should exist")
        .remove("PreToolUse")
        .expect("PreToolUse hook list should exist");

    let managed_count = pre_tool_use
        .iter()
        .filter(|hook_config| {
            hook_config
                .hooks
                .as_ref()
                .map(|hooks| hooks.iter().any(is_managed_hook))
                .unwrap_or(false)
        })
        .count();

    assert_eq!(
        managed_count, 1,
        "register_hooks_in_settings should keep exactly one managed hook entry per event"
    );
    assert_eq!(
        pre_tool_use.len(),
        2,
        "the duplicate managed entry should be removed while preserving the custom hook"
    );
    assert!(
        pre_tool_use.iter().any(|hook_config| {
            hook_config.matcher == Some(serde_json::json!({"tools": ["BashTool"]}))
                && hook_config
                    .hooks
                    .as_ref()
                    .map(|hooks| {
                        hooks
                            .iter()
                            .any(|hook| hook.command.as_deref() == Some("notify.sh"))
                    })
                    .unwrap_or(false)
        }),
        "non-managed hooks should be preserved during deduplication"
    );
}

#[test]
fn test_register_hooks_migrates_retired_capacitor_entries_and_deduplicates() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let retired_no_auth_command = format!(
        "/bin/sh -c '/usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"{}\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true'",
        HOOK_HTTP_URL
    );
    let retired_handle_command = format!(
        "CAPACITOR_HOOK_MARKER=1 $HOME/.local/bin/{}",
        retired_handle_command()
    );
    let existing = serde_json::json!({
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": retired_no_auth_command}]
                },
                {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": managed_command_hook_command()}]
                },
                {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": retired_handle_command, "async": true, "timeout": 30}]
                },
                {
                    "matcher": {"tools": ["BashTool"]},
                    "hooks": [{"type": "command", "command": "notify.sh"}]
                }
            ]
        }
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&existing).unwrap(),
    )
    .unwrap();

    checker.register_hooks_in_settings().unwrap();

    let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    assert!(
        !settings_content.contains("hud-hook handle"),
        "retired handle hook should be removed during managed hook normalization"
    );
    assert_eq!(
        settings_content.matches(HOOK_HTTP_URL).count(),
        managed_hook_event_contracts().count(),
        "each managed event should have exactly one current hook endpoint command"
    );

    let settings: SettingsFile = serde_json::from_str(&settings_content).unwrap();
    let pre_tool_use = settings
        .hooks
        .expect("hooks should exist")
        .remove("PreToolUse")
        .expect("PreToolUse hook list should exist");
    let managed_count = pre_tool_use
        .iter()
        .filter(|hook_config| {
            hook_config
                .hooks
                .as_ref()
                .map(|hooks| hooks.iter().any(is_managed_hook))
                .unwrap_or(false)
        })
        .count();

    assert_eq!(managed_count, 1);
    assert!(
        pre_tool_use.iter().any(|hook_config| {
            hook_config.matcher == Some(serde_json::json!({"tools": ["BashTool"]}))
                && hook_config
                    .hooks
                    .as_ref()
                    .map(|hooks| {
                        hooks
                            .iter()
                            .any(|hook| hook.command.as_deref() == Some("notify.sh"))
                    })
                    .unwrap_or(false)
        }),
        "custom hook should survive Capacitor cleanup"
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
    assert_eq!(
        checker.hooks_registered_in_settings(),
        HookStatus::Installed
    );
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
            entry["hooks"][0]["type"] == "command"
                && entry["hooks"][0]["command"]
                    .as_str()
                    .is_some_and(|v| v.contains("/usr/bin/curl") && v.contains("/hook"))
                && entry["matcher"] == "*"
        }),
        "Capacitor-managed command hook should be registered"
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

    let corrupt = r#"{ invalid json }"#;
    fs::write(storage.claude_settings_file(), corrupt).unwrap();

    let checker = SetupChecker::new(storage.clone());
    let result = checker.register_hooks_in_settings();

    assert!(result.is_err());

    let content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    assert_eq!(content, corrupt);
}

#[test]
fn test_hooks_registered_checks_all_critical_events() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let partial = serde_json::json!({
        "hooks": {
            "SessionStart": [{
                "hooks": [{
                    "type": "command",
                    "command": managed_command_hook_command(),
                }],
            }],
        },
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&partial).unwrap(),
    )
    .unwrap();

    assert!(matches!(
        checker.hooks_registered_in_settings(),
        HookStatus::PartiallyConfigured { .. }
    ));
}

#[test]
fn test_hooks_registered_checks_matchers() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let managed_cmd = managed_command_hook_command();
    let missing_matcher = serde_json::json!({
        "hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "SessionEnd": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PreToolUse": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PostToolUse": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PostToolUseFailure": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PermissionRequest": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "Stop": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PreCompact": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "Notification": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "SubagentStart": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "SubagentStop": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "TeammateIdle": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "TaskCompleted": [{"hooks": [{"type": "command", "command": managed_cmd}]}],
        },
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&missing_matcher).unwrap(),
    )
    .unwrap();

    assert!(matches!(
        checker.hooks_registered_in_settings(),
        HookStatus::PartiallyConfigured { .. }
    ));
}

#[test]
fn test_hooks_registered_rejects_http_transport_for_any_managed_event() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let managed_cmd = managed_command_hook_command();
    let invalid = serde_json::json!({
        "hooks": {
            "SessionStart": [{"hooks": [{"type": "http", "url": HOOK_HTTP_URL}]}],
            "SessionEnd": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PostToolUseFailure": [{"matcher": "*", "hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "Stop": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "PreCompact": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "Notification": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "SubagentStart": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "SubagentStop": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "TeammateIdle": [{"hooks": [{"type": "command", "command": managed_cmd.clone()}]}],
            "TaskCompleted": [{"hooks": [{"type": "command", "command": managed_cmd}]}],
        },
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&invalid).unwrap(),
    )
    .unwrap();

    assert!(
        matches!(
            checker.hooks_registered_in_settings(),
            HookStatus::PartiallyConfigured { .. }
        ),
        "HTTP hook on any managed event should be rejected since all contracts require command transport"
    );
}

#[test]
fn test_hooks_registered_requires_repair_when_retired_managed_entries_remain() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    checker.register_hooks_in_settings().unwrap();

    let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    let mut settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();
    settings["hooks"]["PreToolUse"]
        .as_array_mut()
        .expect("PreToolUse hooks should exist")
        .push(serde_json::json!({
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": format!("CAPACITOR_HOOK_MARKER=1 $HOME/.local/bin/{}", retired_handle_command()),
                "async": true,
                "timeout": 30,
            }],
        }));
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&settings).unwrap(),
    )
    .unwrap();

    assert!(
        matches!(
            checker.hooks_registered_in_settings(),
            HookStatus::PartiallyConfigured { missing_events, .. }
                if missing_events == vec!["PreToolUse".to_string()]
        ),
        "retired Capacitor-managed hooks should make setup repair the event"
    );
}

#[test]
fn test_register_hooks_migrates_existing_http_hooks_to_command_transport() {
    let (_temp, storage) = setup_test_env();
    let checker = SetupChecker::new(storage.clone());

    let existing = serde_json::json!({
        "hooks": {
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "http", "url": HOOK_HTTP_URL}]}],
            "Stop": [{"hooks": [{"type": "http", "url": HOOK_HTTP_URL}]}],
            "SubagentStop": [{"hooks": [{"type": "http", "url": HOOK_HTTP_URL}]}],
            "TaskCompleted": [{"hooks": [{"type": "http", "url": HOOK_HTTP_URL}]}]
        }
    });
    fs::write(
        storage.claude_settings_file(),
        serde_json::to_string_pretty(&existing).unwrap(),
    )
    .unwrap();

    checker.register_hooks_in_settings().unwrap();

    let settings_content = fs::read_to_string(storage.claude_settings_file()).unwrap();
    let settings: serde_json::Value = serde_json::from_str(&settings_content).unwrap();

    for event_name in ["PreToolUse", "Stop", "SubagentStop", "TaskCompleted"] {
        let hooks = settings["hooks"][event_name]
            .as_array()
            .unwrap_or_else(|| panic!("{event_name} should have hooks"));
        let managed = hooks.iter().find(|h| {
            h["hooks"]
                .as_array()
                .map(|inner| {
                    inner.iter().any(|hook| {
                        hook["command"]
                            .as_str()
                            .is_some_and(|c| c.contains("/usr/bin/curl"))
                    })
                })
                .unwrap_or(false)
        });
        assert!(
            managed.is_some(),
            "{event_name} should have been migrated to command transport"
        );
        let inner = &managed.unwrap()["hooks"][0];
        assert_eq!(
            inner["type"], "command",
            "{event_name} should use command type after migration"
        );
        assert!(
            inner["url"].is_null(),
            "{event_name} should not have url field after migration"
        );
    }

    assert_eq!(
        checker.hooks_registered_in_settings(),
        HookStatus::Installed
    );
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
    assert_eq!(hook.command.as_deref(), Some(original.as_str()));
    assert_eq!(hook.async_hook, None);
    assert_eq!(hook.timeout, None);
}
