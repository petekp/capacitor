use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct HookInput {
    pub hook_event_name: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
    pub notification_type: Option<String>,
    pub stop_hook_active: Option<bool>,
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_input: Option<ToolInput>,
    #[serde(default)]
    pub tool_response: Option<ToolResponse>,
    pub agent_id: Option<String>,
    #[serde(default)]
    pub teammate_name: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, serde::Serialize)]
pub struct ToolInput {
    pub file_path: Option<String>,
    pub path: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, serde::Serialize)]
pub struct ToolResponse {
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum HookEvent {
    SessionStart,
    SessionEnd,
    UserPromptSubmit,
    PreToolUse {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PostToolUse {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PostToolUseFailure {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PermissionRequest,
    PreCompact,
    Notification {
        notification_type: String,
    },
    SubagentStart,
    SubagentStop,
    Stop {
        stop_hook_active: bool,
    },
    TeammateIdle,
    TaskCompleted,
    WorktreeCreate,
    WorktreeRemove,
    ConfigChange,
    Unknown {
        event_name: String,
    },
}

impl HookInput {
    pub fn to_event(&self) -> Option<HookEvent> {
        let event_name = self.hook_event_name.as_deref()?;
        let tool_input_file_path = || {
            self.tool_input
                .as_ref()
                .and_then(|ti| ti.file_path.clone().or_else(|| ti.path.clone()))
        };

        Some(match event_name {
            "SessionStart" => HookEvent::SessionStart,
            "SessionEnd" => HookEvent::SessionEnd,
            "UserPromptSubmit" => HookEvent::UserPromptSubmit,
            "PreToolUse" => HookEvent::PreToolUse {
                tool_name: self.tool_name.clone(),
                file_path: tool_input_file_path(),
            },
            "PostToolUse" => {
                let file_path = tool_input_file_path().or_else(|| {
                    self.tool_response
                        .as_ref()
                        .and_then(|tr| tr.file_path.clone())
                });
                HookEvent::PostToolUse {
                    tool_name: self.tool_name.clone(),
                    file_path,
                }
            }
            "PostToolUseFailure" => {
                let file_path = tool_input_file_path().or_else(|| {
                    self.tool_response
                        .as_ref()
                        .and_then(|tr| tr.file_path.clone())
                });
                HookEvent::PostToolUseFailure {
                    tool_name: self.tool_name.clone(),
                    file_path,
                }
            }
            "PermissionRequest" => HookEvent::PermissionRequest,
            "PreCompact" => HookEvent::PreCompact,
            "Notification" => HookEvent::Notification {
                notification_type: self.notification_type.clone().unwrap_or_default(),
            },
            "SubagentStart" => HookEvent::SubagentStart,
            "SubagentStop" => HookEvent::SubagentStop,
            "Stop" => HookEvent::Stop {
                stop_hook_active: self.stop_hook_active.unwrap_or(false),
            },
            "TeammateIdle" => HookEvent::TeammateIdle,
            "TaskCompleted" => HookEvent::TaskCompleted,
            "WorktreeCreate" => HookEvent::WorktreeCreate,
            "WorktreeRemove" => HookEvent::WorktreeRemove,
            "ConfigChange" => HookEvent::ConfigChange,
            _ => HookEvent::Unknown {
                event_name: event_name.to_string(),
            },
        })
    }

    pub fn resolve_cwd(&self, current_cwd: Option<&str>) -> Option<String> {
        self.cwd
            .clone()
            .or_else(|| current_cwd.map(ToString::to_string))
            .map(|cwd| normalize_path(&cwd))
    }
}

fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::HookInput;
    use crate::test_support::env_lock;

    struct EnvGuard {
        key: &'static str,
        prior: Option<String>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, prior }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.prior {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    fn hook_input_with_cwd(cwd: Option<&str>) -> HookInput {
        let value = match cwd {
            Some(path) => serde_json::json!({ "hook_event_name": "SessionStart", "cwd": path }),
            None => serde_json::json!({ "hook_event_name": "SessionStart" }),
        };
        serde_json::from_value(value).expect("valid hook input json")
    }

    #[test]
    fn resolve_cwd_uses_payload_cwd_when_present() {
        let input = hook_input_with_cwd(Some("/repo/path/"));
        assert_eq!(input.resolve_cwd(None).as_deref(), Some("/repo/path"));
    }

    #[test]
    fn resolve_cwd_uses_current_cwd_when_provided() {
        let _guard = env_lock();
        let _pwd = EnvGuard::set("PWD", "/ambient/pwd");
        let _project_dir = EnvGuard::set("CLAUDE_PROJECT_DIR", "/ambient/project");
        let input = hook_input_with_cwd(None);

        assert_eq!(
            input.resolve_cwd(Some("/request/cwd/")).as_deref(),
            Some("/request/cwd")
        );
    }

    #[test]
    fn resolve_cwd_does_not_use_ambient_env_when_request_cwd_missing() {
        let _guard = env_lock();
        let _pwd = EnvGuard::set("PWD", "/ambient/pwd");
        let _project_dir = EnvGuard::set("CLAUDE_PROJECT_DIR", "/ambient/project");
        let input = hook_input_with_cwd(None);

        assert_eq!(input.resolve_cwd(None), None);
    }
}
