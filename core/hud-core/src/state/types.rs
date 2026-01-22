//! Serialized state types used by the hook/state pipeline.
//!
//! **Breaking changes are allowed** (single-user project). Current on-disk format is v3.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::types::SessionState;

// =============================================================================
// Hook Input Types (JSON from Claude Code hooks)
// =============================================================================

/// Raw JSON input from Claude Code hooks.
///
/// This struct captures all fields that Claude Code might send. Fields are optional
/// because different events include different data.
#[derive(Debug, Clone, Deserialize)]
pub struct HookInput {
    pub hook_event_name: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
    pub trigger: Option<String>,
    pub notification_type: Option<String>,
    pub stop_hook_active: Option<bool>,
    pub tool_name: Option<String>,
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub tool_input: Option<ToolInput>,
    #[serde(default)]
    pub tool_response: Option<ToolResponse>,
    pub source: Option<String>,
    pub reason: Option<String>,
    pub agent_id: Option<String>,
    pub agent_transcript_path: Option<String>,
}

/// Tool input fields (file paths from Edit, Write, Read, etc.)
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ToolInput {
    pub file_path: Option<String>,
    pub path: Option<String>,
}

/// Tool response fields
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ToolResponse {
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
}

/// Parsed hook event with associated data.
#[derive(Debug, Clone, PartialEq)]
pub enum HookEvent {
    SessionStart,
    SessionEnd,
    UserPromptSubmit,
    PreToolUse {
        tool_name: Option<String>,
    },
    PostToolUse {
        tool_name: Option<String>,
        file_path: Option<String>,
    },
    PermissionRequest,
    PreCompact,
    Notification {
        notification_type: String,
    },
    Stop {
        stop_hook_active: bool,
    },
    Unknown {
        event_name: String,
    },
}

impl HookInput {
    /// Parse a HookEvent from the raw input.
    pub fn to_event(&self) -> Option<HookEvent> {
        let event_name = self.hook_event_name.as_deref()?;

        Some(match event_name {
            "SessionStart" => HookEvent::SessionStart,
            "SessionEnd" => HookEvent::SessionEnd,
            "UserPromptSubmit" => HookEvent::UserPromptSubmit,
            "PreToolUse" => HookEvent::PreToolUse {
                tool_name: self.tool_name.clone(),
            },
            "PostToolUse" => {
                // Resolve file path from multiple possible locations
                let file_path = self
                    .tool_input
                    .as_ref()
                    .and_then(|ti| ti.file_path.clone().or_else(|| ti.path.clone()))
                    .or_else(|| {
                        self.tool_response
                            .as_ref()
                            .and_then(|tr| tr.file_path.clone())
                    });

                HookEvent::PostToolUse {
                    tool_name: self.tool_name.clone(),
                    file_path,
                }
            }
            "PermissionRequest" => HookEvent::PermissionRequest,
            "PreCompact" => HookEvent::PreCompact,
            "Notification" => HookEvent::Notification {
                notification_type: self.notification_type.clone().unwrap_or_default(),
            },
            "Stop" => HookEvent::Stop {
                stop_hook_active: self.stop_hook_active.unwrap_or(false),
            },
            _ => HookEvent::Unknown {
                event_name: event_name.to_string(),
            },
        })
    }

    /// Resolve the working directory, with fallbacks.
    pub fn resolve_cwd(&self, current_cwd: Option<&str>) -> Option<String> {
        // Priority: input cwd > env CLAUDE_PROJECT_DIR > existing cwd > env PWD
        self.cwd
            .clone()
            .or_else(|| std::env::var("CLAUDE_PROJECT_DIR").ok())
            .or_else(|| current_cwd.map(|s| s.to_string()))
            .or_else(|| std::env::var("PWD").ok())
            .map(|cwd| normalize_path(&cwd))
    }
}

/// Normalize a path: strip trailing slashes (except for root "/").
fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Records older than this are considered stale and untrusted without a lock.
pub const STALE_THRESHOLD_SECS: i64 = 300; // 5 minutes

/// Active states (Working, Waiting) fall back to Ready after this threshold.
/// This handles user interruptions (Escape key, cancel) where no hook event fires.
/// 30 seconds balances interrupt recovery with accuracy during long generations
/// (tool-free responses don't emit heartbeat events).
pub const ACTIVE_STATE_STALE_SECS: i64 = 30;

// -----------------------------------------------------------------------------
// Canonical hook→state mapping (implemented in core/hud-hook/)
//
// SessionStart           → ready    (+ creates lock)
// UserPromptSubmit       → working  (+ creates lock if missing)
// PreToolUse             → working  (heartbeat if already working)
// PostToolUse            → working  (+ tracks file activity)
// PermissionRequest      → waiting
// Notification           → ready    (only idle_prompt type; others ignored)
// PreCompact             → compacting
// Stop                   → ready    (ignored if stop_hook_active=true)
// SessionEnd             → removes session record
// SubagentStop           → ignored  (metadata only, no state change)
// -----------------------------------------------------------------------------

/// Most recent hook event observed for this session (captured for debugging + future features).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct LastEvent {
    #[serde(default)]
    pub hook_event_name: Option<String>,
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,

    // Common event-specific fields (all optional)
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub notification_type: Option<String>,
    #[serde(default)]
    pub trigger: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub stop_hook_active: Option<bool>,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_transcript_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    pub session_id: String,
    pub state: SessionState,
    pub cwd: String,
    pub updated_at: DateTime<Utc>,
    pub state_changed_at: DateTime<Utc>,
    #[serde(default)]
    pub working_on: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub last_event: Option<LastEvent>,
    #[serde(default)]
    pub active_subagent_count: u32,
}

impl SessionRecord {
    /// Returns true if this record is stale (not updated within [`STALE_THRESHOLD_SECS`]).
    pub fn is_stale(&self) -> bool {
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > STALE_THRESHOLD_SECS
    }

    /// Returns true if this record is in an "active" state that hasn't been updated recently.
    /// Active states (Working, Waiting) should have frequent hook updates from tool use events.
    /// If stale, the user likely interrupted (Escape key, cancel) and we should show Ready.
    ///
    /// Note: Compacting is NOT included here because it receives no heartbeat updates after
    /// PreCompact fires. Compaction can take 30+ seconds, so it uses the general staleness
    /// threshold instead of this aggressive 5-second check.
    pub fn is_active_state_stale(&self) -> bool {
        let is_active = matches!(self.state, SessionState::Working | SessionState::Waiting);
        if !is_active {
            return false;
        }
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > ACTIVE_STATE_STALE_SECS
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
    use chrono::Duration;

    fn make_record(updated_at: DateTime<Utc>) -> SessionRecord {
        SessionRecord {
            session_id: "test".to_string(),
            state: crate::types::SessionState::Ready,
            cwd: "/test".to_string(),
            updated_at,
            state_changed_at: updated_at,
            working_on: None,
            transcript_path: None,
            permission_mode: None,
            project_dir: None,
            last_event: None,
            active_subagent_count: 0,
        }
    }

    #[test]
    fn test_is_stale_fresh_record() {
        let record = make_record(Utc::now());
        assert!(!record.is_stale());
    }

    #[test]
    fn test_is_stale_old_record() {
        let old_time = Utc::now() - Duration::seconds(STALE_THRESHOLD_SECS + 1);
        let record = make_record(old_time);
        assert!(record.is_stale());
    }

    #[test]
    fn test_is_stale_boundary() {
        // Exactly at threshold should NOT be stale (uses >)
        let boundary_time = Utc::now() - Duration::seconds(STALE_THRESHOLD_SECS);
        let record = make_record(boundary_time);
        assert!(!record.is_stale());
    }

    fn make_record_with_state(
        updated_at: DateTime<Utc>,
        state: crate::types::SessionState,
    ) -> SessionRecord {
        SessionRecord {
            session_id: "test".to_string(),
            state,
            cwd: "/test".to_string(),
            updated_at,
            state_changed_at: updated_at,
            working_on: None,
            transcript_path: None,
            permission_mode: None,
            project_dir: None,
            last_event: None,
            active_subagent_count: 0,
        }
    }

    #[test]
    fn test_active_state_stale_working_fresh() {
        let record = make_record_with_state(Utc::now(), crate::types::SessionState::Working);
        assert!(!record.is_active_state_stale());
    }

    #[test]
    fn test_active_state_stale_working_old() {
        let old_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 1);
        let record = make_record_with_state(old_time, crate::types::SessionState::Working);
        assert!(record.is_active_state_stale());
    }

    #[test]
    fn test_active_state_stale_waiting_old() {
        let old_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 1);
        let record = make_record_with_state(old_time, crate::types::SessionState::Waiting);
        assert!(record.is_active_state_stale());
    }

    #[test]
    fn test_active_state_stale_compacting_not_affected() {
        // Compacting is NOT subject to active staleness because it receives no heartbeat
        // updates after PreCompact fires, and compaction can take 30+ seconds
        let old_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 1);
        let record = make_record_with_state(old_time, crate::types::SessionState::Compacting);
        assert!(!record.is_active_state_stale());
    }

    #[test]
    fn test_active_state_stale_ready_not_affected() {
        // Ready is not an "active" state, so it should never be active-stale
        let old_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 1);
        let record = make_record_with_state(old_time, crate::types::SessionState::Ready);
        assert!(!record.is_active_state_stale());
    }

    #[test]
    fn test_active_state_stale_idle_not_affected() {
        // Idle is not an "active" state, so it should never be active-stale
        let old_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 1);
        let record = make_record_with_state(old_time, crate::types::SessionState::Idle);
        assert!(!record.is_active_state_stale());
    }
}
