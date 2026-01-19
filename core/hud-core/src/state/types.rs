use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClaudeState {
    Ready,
    Working,
    Compacting,
    Blocked,
}

impl std::fmt::Display for ClaudeState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClaudeState::Ready => write!(f, "ready"),
            ClaudeState::Working => write!(f, "working"),
            ClaudeState::Compacting => write!(f, "compacting"),
            ClaudeState::Blocked => write!(f, "blocked"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookEvent {
    SessionStart,
    UserPromptSubmit,
    PostToolUse,
    PermissionRequest,
    PreCompact { trigger: String },
    Stop,
    Notification { notification_type: String },
    SessionEnd,
}

impl HookEvent {
    pub fn from_name(
        name: &str,
        trigger: Option<&str>,
        notification_type: Option<&str>,
    ) -> Option<Self> {
        match name {
            "SessionStart" => Some(HookEvent::SessionStart),
            "UserPromptSubmit" => Some(HookEvent::UserPromptSubmit),
            "PostToolUse" => Some(HookEvent::PostToolUse),
            "PermissionRequest" => Some(HookEvent::PermissionRequest),
            "PreCompact" => Some(HookEvent::PreCompact {
                trigger: trigger.unwrap_or("manual").to_string(),
            }),
            "Stop" => Some(HookEvent::Stop),
            "Notification" => Some(HookEvent::Notification {
                notification_type: notification_type.unwrap_or("").to_string(),
            }),
            "SessionEnd" => Some(HookEvent::SessionEnd),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    pub session_id: String,
    pub state: ClaudeState,
    pub cwd: String,
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub working_on: Option<String>,
    #[serde(default)]
    pub pid: Option<u32>,
}

impl SessionRecord {
    /// Returns true if this record is stale (not updated in last 5 minutes)
    pub fn is_stale(&self) -> bool {
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > 300 // 5 minutes
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockInfo {
    pub pid: u32,
    pub path: String,
    /// Process start time (Unix timestamp) for PID identity verification.
    /// None for legacy locks created before PID verification was added.
    #[serde(default)]
    pub proc_started: Option<u64>,
    /// Lock creation time (Unix timestamp) for "newest lock wins" selection.
    /// Uses the old field name "started" for backward compatibility with reading old locks.
    /// New locks write to "created" field instead.
    #[serde(default, alias = "started")]
    pub created: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_claude_state_display() {
        assert_eq!(ClaudeState::Ready.to_string(), "ready");
        assert_eq!(ClaudeState::Working.to_string(), "working");
        assert_eq!(ClaudeState::Compacting.to_string(), "compacting");
        assert_eq!(ClaudeState::Blocked.to_string(), "blocked");
    }

    #[test]
    fn test_hook_event_from_name() {
        assert_eq!(
            HookEvent::from_name("SessionStart", None, None),
            Some(HookEvent::SessionStart)
        );
        assert_eq!(
            HookEvent::from_name("UserPromptSubmit", None, None),
            Some(HookEvent::UserPromptSubmit)
        );
        assert_eq!(
            HookEvent::from_name("PostToolUse", None, None),
            Some(HookEvent::PostToolUse)
        );
        assert_eq!(
            HookEvent::from_name("PermissionRequest", None, None),
            Some(HookEvent::PermissionRequest)
        );
        assert_eq!(
            HookEvent::from_name("PreCompact", Some("auto"), None),
            Some(HookEvent::PreCompact {
                trigger: "auto".to_string()
            })
        );
        assert_eq!(
            HookEvent::from_name("Stop", None, None),
            Some(HookEvent::Stop)
        );
        assert_eq!(
            HookEvent::from_name("Notification", None, Some("idle_prompt")),
            Some(HookEvent::Notification {
                notification_type: "idle_prompt".to_string()
            })
        );
        assert_eq!(
            HookEvent::from_name("SessionEnd", None, None),
            Some(HookEvent::SessionEnd)
        );
        assert_eq!(HookEvent::from_name("Unknown", None, None), None);
    }
}
