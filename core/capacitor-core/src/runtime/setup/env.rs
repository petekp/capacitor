use super::settings::InnerHook;
use crate::runtime::contracts::{ClaudeHookEventContract, HookTransport};
use std::collections::HashMap;
use std::process::Command;

pub(super) const HOOK_HTTP_URL: &str = "http://127.0.0.1:7474/hook";

pub(super) fn which(binary: &str) -> Option<String> {
    let output = Command::new("which").arg(binary).output().ok()?;

    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() {
            return Some(path);
        }
    }
    None
}

pub(super) fn which_with_fallback(binary: &str, fallback_paths: &[&str]) -> Option<String> {
    if let Some(path) = which(binary) {
        return Some(path);
    }

    for path in fallback_paths {
        let p = std::path::Path::new(path);
        if p.exists() && p.is_file() {
            return Some(path.to_string());
        }
    }

    if let Some(home) = dirs::home_dir() {
        let local_bin = home.join(".local/bin").join(binary);
        if local_bin.exists() {
            return Some(local_bin.to_string_lossy().to_string());
        }
    }

    None
}

pub(super) fn is_managed_hook_command(cmd: Option<&str>) -> bool {
    let Some(command) = cmd else {
        return false;
    };
    is_current_managed_hook_command(Some(command)) || is_retired_managed_hook_command(Some(command))
}

pub(super) fn is_hud_hook_url(url: Option<&str>) -> bool {
    match url {
        Some(u) => u.trim() == HOOK_HTTP_URL,
        None => false,
    }
}

pub(super) fn is_managed_hook(hook: &InnerHook) -> bool {
    is_managed_hook_command(
        hook.command
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty()),
    ) || is_hud_hook_url(hook.url.as_deref())
}

pub(super) fn managed_command_hook_command() -> String {
    format!(
        "/bin/sh -c 'TOKEN=$(cat \"$HOME/.capacitor/runtime/runtime-service-7474.token\" 2>/dev/null); /usr/bin/curl -fsS --connect-timeout 1 --max-time 1 -X POST \"{url}\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer $TOKEN\" --data-binary @- >/dev/null 2>&1 || true'",
        url = HOOK_HTTP_URL
    )
}

pub(super) fn is_current_managed_hook_command(cmd: Option<&str>) -> bool {
    let Some(command) = cmd else {
        return false;
    };
    command.trim() == managed_command_hook_command()
}

fn is_retired_managed_hook_command(cmd: Option<&str>) -> bool {
    let Some(command) = cmd else {
        return false;
    };
    let command = command.trim();
    if command.is_empty() || is_current_managed_hook_command(Some(command)) {
        return false;
    }

    command_posts_to_retired_hook_endpoint(command) || is_retired_handle_command(command)
}

fn command_posts_to_retired_hook_endpoint(command: &str) -> bool {
    command.contains(HOOK_HTTP_URL) && command.contains("/usr/bin/curl")
}

fn is_retired_handle_command(command: &str) -> bool {
    let mut remaining = command.trim();
    loop {
        if let Some(stripped) = remaining.strip_prefix("CAPACITOR_HOOK_MARKER=1 ") {
            remaining = stripped.trim_start();
            continue;
        }
        if let Some(stripped) = remaining.strip_prefix("CAPACITOR_CORE_ENABLED=1 ") {
            remaining = stripped.trim_start();
            continue;
        }
        break;
    }

    remaining == "hud-hook handle"
        || remaining == "$HOME/.local/bin/hud-hook handle"
        || remaining == "~/.local/bin/hud-hook handle"
        || remaining.ends_with("/.local/bin/hud-hook handle")
}

pub(super) fn managed_inner_hook(contract: &ClaudeHookEventContract) -> InnerHook {
    let transport = contract
        .managed_transport
        .expect("managed hook contract must declare a transport");
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

pub(super) fn apply_managed_contract(hook: &mut InnerHook, contract: &ClaudeHookEventContract) {
    let transport = contract
        .managed_transport
        .expect("managed hook contract must declare a transport");
    debug_assert_eq!(transport, HookTransport::Command);

    hook.hook_type = Some("command".to_string());
    hook.command = Some(managed_command_hook_command());
    hook.url = None;
    hook.async_hook = None;
    hook.timeout = None;
}

pub(super) fn inner_hook_matches_managed_contract(
    hook: &InnerHook,
    contract: &ClaudeHookEventContract,
) -> bool {
    if let Some(transport) = contract.managed_transport {
        debug_assert_eq!(transport, HookTransport::Command);
        return is_current_managed_hook_command(hook.command.as_deref());
    }
    false
}

pub(super) fn matcher_matches_all_tools(matcher: &serde_json::Value) -> bool {
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
    use super::super::test_support::{
        marker_prefixed_managed_command, retired_handle_command, retired_prefixed_handle_command,
        retired_state_tracker_command,
    };
    use super::*;

    #[test]
    fn test_is_managed_hook_command_accepts_current_and_retired_capacitor_commands() {
        let retired_no_auth_hook_command = format!(
            "/bin/sh -c '/usr/bin/curl -fsS -X POST \"{}\" --data-binary @- >/dev/null 2>&1 || true'",
            HOOK_HTTP_URL
        );
        let marker_prefixed_handle_command = format!(
            "CAPACITOR_HOOK_MARKER=1 $HOME/.local/bin/{}",
            retired_handle_command()
        );
        let cases = [
            (managed_command_hook_command(), true),
            (marker_prefixed_managed_command(), true),
            (retired_no_auth_hook_command, true),
            (marker_prefixed_handle_command, true),
            (retired_prefixed_handle_command(), true),
            (
                format!("$HOME/.local/bin/{}", retired_handle_command()),
                true,
            ),
            (retired_handle_command(), true),
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
    fn test_current_managed_hook_command_accepts_only_current_contract_command() {
        assert!(is_current_managed_hook_command(Some(
            managed_command_hook_command().as_str()
        )));
        assert!(!is_current_managed_hook_command(Some(
            retired_prefixed_handle_command().as_str()
        )));
        assert!(!is_current_managed_hook_command(Some(
            marker_prefixed_managed_command().as_str()
        )));
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
}
