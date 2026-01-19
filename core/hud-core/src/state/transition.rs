use super::types::{ClaudeState, HookEvent};

pub fn next_state(current: Option<ClaudeState>, event: HookEvent) -> Option<ClaudeState> {
    match event {
        HookEvent::SessionStart => Some(ClaudeState::Ready),
        HookEvent::UserPromptSubmit => Some(ClaudeState::Working),
        HookEvent::PostToolUse => Some(ClaudeState::Working),
        HookEvent::PermissionRequest => Some(ClaudeState::Blocked),
        HookEvent::PreCompact { ref trigger } if trigger == "auto" => Some(ClaudeState::Compacting),
        HookEvent::PreCompact { .. } => current,
        HookEvent::Stop => Some(ClaudeState::Ready),
        HookEvent::Notification {
            ref notification_type,
        } if notification_type == "idle_prompt" => Some(ClaudeState::Ready),
        HookEvent::Notification { .. } => current,
        HookEvent::SessionEnd => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_start_yields_ready() {
        assert_eq!(
            next_state(None, HookEvent::SessionStart),
            Some(ClaudeState::Ready)
        );
    }

    #[test]
    fn test_user_prompt_submit_yields_working() {
        assert_eq!(
            next_state(Some(ClaudeState::Ready), HookEvent::UserPromptSubmit),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_post_tool_use_stays_working() {
        assert_eq!(
            next_state(Some(ClaudeState::Working), HookEvent::PostToolUse),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_post_tool_use_resumes_from_blocked() {
        assert_eq!(
            next_state(Some(ClaudeState::Blocked), HookEvent::PostToolUse),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_post_tool_use_resumes_from_compacting() {
        assert_eq!(
            next_state(Some(ClaudeState::Compacting), HookEvent::PostToolUse),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_permission_request_yields_blocked() {
        assert_eq!(
            next_state(Some(ClaudeState::Working), HookEvent::PermissionRequest),
            Some(ClaudeState::Blocked)
        );
    }

    #[test]
    fn test_pre_compact_auto_yields_compacting() {
        assert_eq!(
            next_state(
                Some(ClaudeState::Working),
                HookEvent::PreCompact {
                    trigger: "auto".to_string()
                }
            ),
            Some(ClaudeState::Compacting)
        );
    }

    #[test]
    fn test_pre_compact_manual_ignored() {
        assert_eq!(
            next_state(
                Some(ClaudeState::Working),
                HookEvent::PreCompact {
                    trigger: "manual".to_string()
                }
            ),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_stop_yields_ready() {
        assert_eq!(
            next_state(Some(ClaudeState::Working), HookEvent::Stop),
            Some(ClaudeState::Ready)
        );
    }

    #[test]
    fn test_notification_idle_prompt_yields_ready() {
        assert_eq!(
            next_state(
                Some(ClaudeState::Working),
                HookEvent::Notification {
                    notification_type: "idle_prompt".to_string()
                }
            ),
            Some(ClaudeState::Ready)
        );
    }

    #[test]
    fn test_notification_other_ignored() {
        assert_eq!(
            next_state(
                Some(ClaudeState::Working),
                HookEvent::Notification {
                    notification_type: "other".to_string()
                }
            ),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_session_end_removes_state() {
        assert_eq!(
            next_state(Some(ClaudeState::Ready), HookEvent::SessionEnd),
            None
        );
    }

    #[test]
    fn test_from_none_user_prompt_starts_working() {
        assert_eq!(
            next_state(None, HookEvent::UserPromptSubmit),
            Some(ClaudeState::Working)
        );
    }

    #[test]
    fn test_from_none_post_tool_use_starts_working() {
        assert_eq!(
            next_state(None, HookEvent::PostToolUse),
            Some(ClaudeState::Working)
        );
    }
}
