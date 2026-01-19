use serde::{Deserialize, Serialize};

/// Universal agent states - maps to any CLI agent's activity
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, Serialize, Deserialize)]
pub enum AgentState {
    Idle,
    Ready,
    Working,
    Waiting,
}

impl std::fmt::Display for AgentState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AgentState::Idle => write!(f, "idle"),
            AgentState::Ready => write!(f, "ready"),
            AgentState::Working => write!(f, "working"),
            AgentState::Waiting => write!(f, "waiting"),
        }
    }
}

/// Known agent types - flat enum for UniFFI compatibility
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum, Serialize, Deserialize)]
pub enum AgentType {
    Claude,
    Codex,
    Aider,
    Amp,
    OpenCode,
    Droid,
    Other,
}

impl AgentType {
    pub fn id(&self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Aider => "aider",
            Self::Amp => "amp",
            Self::OpenCode => "opencode",
            Self::Droid => "droid",
            Self::Other => "other",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "OpenAI Codex",
            Self::Aider => "Aider",
            Self::Amp => "Amp",
            Self::OpenCode => "OpenCode",
            Self::Droid => "Droid",
            Self::Other => "Other",
        }
    }
}

impl std::fmt::Display for AgentType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.id())
    }
}

/// A detected agent session
///
/// NOTE: The composite key is (agent_type, session_id). Session IDs are only
/// unique within an agent type, not globally.
#[derive(Debug, Clone, uniffi::Record, Serialize, Deserialize)]
pub struct AgentSession {
    pub agent_type: AgentType,
    pub agent_name: String,
    pub state: AgentState,
    #[serde(default)]
    pub session_id: Option<String>,
    pub cwd: String,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub working_on: Option<String>,
    #[serde(default)]
    pub updated_at: Option<String>,
}

/// Agent configuration with user preferences
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AgentConfig {
    #[serde(default)]
    pub disabled: Vec<String>,
    #[serde(default)]
    pub agent_order: Vec<String>,
}

/// Errors that can occur in adapter operations
#[derive(Debug, Clone)]
pub enum AdapterError {
    CorruptedState { path: String, reason: String },
    PermissionDenied { path: String },
    IoError { message: String },
    InitFailed { reason: String },
}

impl std::fmt::Display for AdapterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AdapterError::CorruptedState { path, reason } => {
                write!(f, "Corrupted state at {}: {}", path, reason)
            }
            AdapterError::PermissionDenied { path } => {
                write!(f, "Permission denied: {}", path)
            }
            AdapterError::IoError { message } => {
                write!(f, "IO error: {}", message)
            }
            AdapterError::InitFailed { reason } => {
                write!(f, "Initialization failed: {}", reason)
            }
        }
    }
}

impl std::error::Error for AdapterError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_agent_state_display() {
        assert_eq!(AgentState::Idle.to_string(), "idle");
        assert_eq!(AgentState::Ready.to_string(), "ready");
        assert_eq!(AgentState::Working.to_string(), "working");
        assert_eq!(AgentState::Waiting.to_string(), "waiting");
    }

    #[test]
    fn test_agent_type_id() {
        assert_eq!(AgentType::Claude.id(), "claude");
        assert_eq!(AgentType::Codex.id(), "codex");
        assert_eq!(AgentType::Aider.id(), "aider");
        assert_eq!(AgentType::Amp.id(), "amp");
        assert_eq!(AgentType::OpenCode.id(), "opencode");
        assert_eq!(AgentType::Droid.id(), "droid");
        assert_eq!(AgentType::Other.id(), "other");
    }

    #[test]
    fn test_agent_type_display_name() {
        assert_eq!(AgentType::Claude.display_name(), "Claude Code");
        assert_eq!(AgentType::Codex.display_name(), "OpenAI Codex");
    }

    #[test]
    fn test_adapter_error_display() {
        let err = AdapterError::CorruptedState {
            path: "/test".to_string(),
            reason: "invalid json".to_string(),
        };
        assert!(err.to_string().contains("Corrupted state"));
        assert!(err.to_string().contains("/test"));
    }

    #[test]
    fn test_agent_config_default() {
        let config = AgentConfig::default();
        assert!(config.disabled.is_empty());
        assert!(config.agent_order.is_empty());
    }
}
