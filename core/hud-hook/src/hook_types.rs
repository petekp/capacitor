use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize)]
pub struct HookInput {
    pub hook_event_name: Option<String>,
    pub session_id: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    pub trigger: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    pub notification_type: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    pub tool_name: Option<String>,
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_input: Option<ToolInput>,
    #[serde(default)]
    pub tool_response: Option<ToolResponse>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub is_interrupt: Option<bool>,
    #[serde(default)]
    pub permission_suggestions: Option<Value>,
    #[serde(default)]
    pub source: Option<Value>,
    #[serde(default)]
    pub reason: Option<Value>,
    #[serde(default)]
    pub model: Option<String>,
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_type: Option<String>,
    pub agent_transcript_path: Option<String>,
    #[serde(default)]
    pub teammate_name: Option<String>,
    #[serde(default)]
    pub team_name: Option<String>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub task_subject: Option<String>,
    #[serde(default)]
    pub task_description: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Default, Deserialize, serde::Serialize)]
pub struct ToolInput {
    pub file_path: Option<String>,
    pub path: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Default, Deserialize, serde::Serialize)]
pub struct ToolResponse {
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, Value>,
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
            .or_else(|| std::env::var("CLAUDE_PROJECT_DIR").ok())
            .or_else(|| current_cwd.map(ToString::to_string))
            .or_else(|| std::env::var("PWD").ok())
            .map(|cwd| normalize_path(&cwd))
    }

    #[allow(dead_code)]
    pub fn to_metadata_map(&self) -> Map<String, Value> {
        let mut metadata = Map::new();

        insert_trimmed_str(
            &mut metadata,
            "transcript_path",
            self.transcript_path.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "permission_mode",
            self.permission_mode.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "trigger", self.trigger.as_deref());
        insert_trimmed_str(&mut metadata, "prompt", self.prompt.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "custom_instructions",
            self.custom_instructions.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "notification_type",
            self.notification_type.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "message", self.message.as_deref());
        insert_trimmed_str(&mut metadata, "title", self.title.as_deref());
        if let Some(stop_hook_active) = self.stop_hook_active {
            metadata.insert(
                "stop_hook_active".to_string(),
                Value::Bool(stop_hook_active),
            );
        }
        insert_trimmed_str(
            &mut metadata,
            "last_assistant_message",
            self.last_assistant_message.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "tool_name", self.tool_name.as_deref());
        insert_trimmed_str(&mut metadata, "tool_use_id", self.tool_use_id.as_deref());
        insert_trimmed_str(&mut metadata, "error", self.error.as_deref());
        if let Some(is_interrupt) = self.is_interrupt {
            metadata.insert("is_interrupt".to_string(), Value::Bool(is_interrupt));
        }
        insert_trimmed_str(&mut metadata, "model", self.model.as_deref());
        insert_trimmed_str(&mut metadata, "agent_id", self.agent_id.as_deref());
        insert_trimmed_str(&mut metadata, "agent_type", self.agent_type.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "agent_transcript_path",
            self.agent_transcript_path.as_deref(),
        );
        insert_trimmed_str(
            &mut metadata,
            "teammate_name",
            self.teammate_name.as_deref(),
        );
        insert_trimmed_str(&mut metadata, "team_name", self.team_name.as_deref());
        insert_trimmed_str(&mut metadata, "task_id", self.task_id.as_deref());
        insert_trimmed_str(&mut metadata, "task_subject", self.task_subject.as_deref());
        insert_trimmed_str(
            &mut metadata,
            "task_description",
            self.task_description.as_deref(),
        );

        if let Some(source) = &self.source {
            metadata.insert("source".to_string(), source.clone());
        }
        if let Some(reason) = &self.reason {
            metadata.insert("reason".to_string(), reason.clone());
        }
        if let Some(permission_suggestions) = &self.permission_suggestions {
            metadata.insert(
                "permission_suggestions".to_string(),
                permission_suggestions.clone(),
            );
        }

        if let Some(tool_input) = &self.tool_input {
            if let Ok(value) = serde_json::to_value(tool_input) {
                if !value_is_empty_object(&value) {
                    metadata.insert("tool_input".to_string(), value);
                }
            }
        }
        if let Some(tool_response) = &self.tool_response {
            if let Ok(value) = serde_json::to_value(tool_response) {
                if !value_is_empty_object(&value) {
                    metadata.insert("tool_response".to_string(), value);
                }
            }
        }

        for (key, value) in &self.extra {
            metadata.entry(key.clone()).or_insert_with(|| value.clone());
        }

        metadata
    }
}

fn insert_trimmed_str(map: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) {
        map.insert(key.to_string(), Value::String(value.to_string()));
    }
}

fn value_is_empty_object(value: &Value) -> bool {
    match value {
        Value::Object(object) => object.is_empty(),
        _ => false,
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
