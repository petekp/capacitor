//! IPC protocol types and validation for capacitor-daemon.
//!
//! This crate is shared by the daemon and its clients to prevent schema drift.
//! The daemon remains the authority on validation, but clients can reuse the
//! same types to construct valid requests.

use chrono::DateTime;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024; // 1MB

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Method {
    GetHealth,
    Event,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub protocol_version: u32,
    pub method: Method,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ErrorInfo {
    pub code: String,
    pub message: String,
}

impl ErrorInfo {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl Response {
    pub fn ok(id: Option<String>, data: Value) -> Self {
        Self {
            ok: true,
            id,
            data: Some(data),
            error: None,
        }
    }

    pub fn error(id: Option<String>, code: &str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            id,
            data: None,
            error: Some(ErrorInfo::new(code, message)),
        }
    }

    pub fn error_with_info(id: Option<String>, error: ErrorInfo) -> Self {
        Self {
            ok: false,
            id,
            data: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum EventType {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    PermissionRequest,
    PreCompact,
    Notification,
    Stop,
    SessionEnd,
    ShellCwd,
}

// IPC contract fields; not all are consumed in Phase 1, but we keep them
// to lock the schema early and avoid churn during client integration.
#[allow(dead_code)]
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EventEnvelope {
    pub event_id: String,
    pub recorded_at: String,
    pub event_type: EventType,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub parent_app: Option<String>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub tmux_session: Option<String>,
    #[serde(default)]
    pub tmux_client_tty: Option<String>,
    #[serde(default)]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub metadata: Option<Value>,
}

impl EventEnvelope {
    pub fn validate(&self) -> Result<(), ErrorInfo> {
        if self.event_id.trim().is_empty() {
            return Err(ErrorInfo::new("invalid_event_id", "event_id is required"));
        }
        if self.event_id.len() > 128 {
            return Err(ErrorInfo::new(
                "invalid_event_id",
                "event_id must be 128 characters or fewer",
            ));
        }

        if DateTime::parse_from_rfc3339(&self.recorded_at).is_err() {
            return Err(ErrorInfo::new(
                "invalid_timestamp",
                "recorded_at must be RFC3339",
            ));
        }

        match self.event_type {
            EventType::ShellCwd => {
                require_pid(&self.pid)?;
                require_string(&self.cwd, "cwd")?;
                require_string(&self.tty, "tty")?;
            }
            EventType::Notification => {
                require_session_fields(self)?;
                require_string(&self.notification_type, "notification_type")?;
            }
            EventType::Stop => {
                require_session_fields(self)?;
                require_bool(&self.stop_hook_active, "stop_hook_active")?;
            }
            EventType::SessionStart
            | EventType::UserPromptSubmit
            | EventType::PreToolUse
            | EventType::PostToolUse
            | EventType::PermissionRequest
            | EventType::PreCompact
            | EventType::SessionEnd => {
                require_session_fields(self)?;
            }
        }

        Ok(())
    }
}

pub fn parse_event(params: Value) -> Result<EventEnvelope, ErrorInfo> {
    let envelope: EventEnvelope = serde_json::from_value(params).map_err(|err| {
        ErrorInfo::new(
            "invalid_params",
            format!("event payload is invalid JSON: {}", err),
        )
    })?;
    envelope.validate()?;
    Ok(envelope)
}

fn require_session_fields(event: &EventEnvelope) -> Result<(), ErrorInfo> {
    require_string(&event.session_id, "session_id")?;
    require_pid(&event.pid)?;
    require_string(&event.cwd, "cwd")?;
    Ok(())
}

fn require_string(value: &Option<String>, field: &str) -> Result<(), ErrorInfo> {
    if let Some(candidate) = value {
        if !candidate.trim().is_empty() {
            return Ok(());
        }
    }
    Err(ErrorInfo::new(
        "missing_field",
        format!("{} is required", field),
    ))
}

fn require_pid(pid: &Option<u32>) -> Result<(), ErrorInfo> {
    match pid {
        Some(0) | None => Err(ErrorInfo::new("invalid_pid", "pid is required")),
        Some(_) => Ok(()),
    }
}

fn require_bool(value: &Option<bool>, field: &str) -> Result<(), ErrorInfo> {
    match value {
        Some(_) => Ok(()),
        None => Err(ErrorInfo::new(
            "missing_field",
            format!("{} is required", field),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_event(event_type: EventType) -> EventEnvelope {
        EventEnvelope {
            event_id: "evt-1".to_string(),
            recorded_at: "2026-01-30T12:00:00Z".to_string(),
            event_type,
            session_id: Some("session-1".to_string()),
            pid: Some(1234),
            cwd: Some("/repo".to_string()),
            tool: None,
            file_path: None,
            parent_app: None,
            tty: None,
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        }
    }

    #[test]
    fn validates_session_event() {
        let event = base_event(EventType::SessionStart);
        assert!(event.validate().is_ok());
    }

    #[test]
    fn validates_stop_requires_flag() {
        let event = base_event(EventType::Stop);
        assert!(event.validate().is_err());
    }

    #[test]
    fn validates_notification_requires_type() {
        let event = base_event(EventType::Notification);
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_missing_session_id() {
        let mut event = base_event(EventType::SessionStart);
        event.session_id = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn validates_shell_cwd_requires_tty() {
        let mut event = base_event(EventType::ShellCwd);
        event.tty = None;
        event.session_id = None;
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_bad_timestamp() {
        let mut event = base_event(EventType::SessionEnd);
        event.recorded_at = "not-a-time".to_string();
        assert!(event.validate().is_err());
    }

    #[test]
    fn rejects_long_event_id() {
        let mut event = base_event(EventType::SessionEnd);
        event.event_id = "a".repeat(256);
        assert!(event.validate().is_err());
    }
}
