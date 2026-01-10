use chrono::{DateTime, Utc};

use crate::domain::{
    default_workspace_id, ActivationActionKind, ActivationPlan, ResolveActivationCommand,
    ResolveActivationOutcome, RoutingStatus, RoutingTargetKind,
};
use crate::reduce::ReducerState;

#[must_use]
pub fn resolve_activation(
    state: &ReducerState,
    command: ResolveActivationCommand,
) -> ResolveActivationOutcome {
    let project_path = crate::domain::normalize_path_for_matching(&command.project_path);
    let workspace_id = command
        .workspace_id
        .clone()
        .unwrap_or_else(|| default_workspace_id(&project_path));

    if let Some(route) = state.routing.get(&workspace_id) {
        let (action, tmux_session, app_name) = match (route.status, route.target_kind) {
            (RoutingStatus::Attached, RoutingTargetKind::TmuxSession) => (
                ActivationActionKind::SwitchTmuxSession,
                route.target_value.clone(),
                None,
            ),
            (RoutingStatus::Detached, RoutingTargetKind::TmuxSession) => (
                ActivationActionKind::EnsureTmuxSession,
                route.target_value.clone(),
                None,
            ),
            (RoutingStatus::Attached, RoutingTargetKind::TerminalApp) => (
                ActivationActionKind::ActivateApp,
                None,
                route.target_value.clone(),
            ),
            _ => (ActivationActionKind::LaunchNewTerminal, None, None),
        };

        return ResolveActivationOutcome {
            plan: ActivationPlan {
                action,
                target_tty: None,
                tmux_session,
                app_name,
                project_path,
                reason_code: route.reason_code.clone(),
            },
            confidence: "high".to_string(),
        };
    }

    let fallback_shell = state
        .shells
        .values()
        .filter(|shell| shell_path_is_within_project(&project_path, &shell.cwd))
        .max_by(|left, right| compare_timestamp_strings(&left.updated_at, &right.updated_at));

    if let Some(shell) = fallback_shell {
        return ResolveActivationOutcome {
            plan: ActivationPlan {
                action: ActivationActionKind::ActivateByTty,
                target_tty: Some(shell.tty.clone()),
                tmux_session: shell.tmux_session.clone(),
                app_name: if shell.tmux_session.is_some() {
                    None
                } else {
                    sanitize_parent_app(&shell.parent_app).map(str::to_string)
                },
                project_path,
                reason_code: "fallback_shell_cwd".to_string(),
            },
            confidence: "medium".to_string(),
        };
    }

    ResolveActivationOutcome {
        plan: ActivationPlan {
            action: ActivationActionKind::LaunchNewTerminal,
            target_tty: None,
            tmux_session: None,
            app_name: None,
            project_path,
            reason_code: "fallback_launch".to_string(),
        },
        confidence: "low".to_string(),
    }
}

fn shell_path_is_within_project(project_path: &str, shell_cwd: &str) -> bool {
    let normalized_project = crate::domain::normalize_path_for_matching(project_path);
    let normalized_shell = crate::domain::normalize_path_for_matching(shell_cwd);
    normalized_shell == normalized_project
        || normalized_shell.starts_with(&(normalized_project + "/"))
}

fn compare_timestamp_strings(left: &str, right: &str) -> std::cmp::Ordering {
    match (parse_rfc3339(left), parse_rfc3339(right)) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => std::cmp::Ordering::Greater,
        (None, Some(_)) => std::cmp::Ordering::Less,
        (None, None) => std::cmp::Ordering::Equal,
    }
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

fn sanitize_parent_app(value: &str) -> Option<&str> {
    let normalized = value.trim();
    if normalized.is_empty() || normalized.eq_ignore_ascii_case("unknown") {
        None
    } else {
        Some(normalized)
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        activate::resolve_activation,
        domain::{IngestShellSignalCommand, ResolveActivationCommand},
        reduce::ReducerState,
    };

    #[test]
    fn resolve_activation_prefers_existing_shell_tty() {
        let mut state = ReducerState::default();
        let _ = state.apply_shell_signal(IngestShellSignalCommand {
            pid: 17,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys008".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: Some("cap-main".to_string()),
            recorded_at: "2026-02-28T00:00:00Z".to_string(),
        });

        let outcome = resolve_activation(
            &state,
            ResolveActivationCommand {
                project_path: "/repo".to_string(),
                workspace_id: None,
            },
        );

        assert_eq!(outcome.plan.target_tty.as_deref(), Some("/dev/ttys008"));
        assert_eq!(outcome.plan.tmux_session.as_deref(), Some("cap-main"));
    }

    #[test]
    fn resolve_activation_ignores_parent_directory_shell() {
        let mut state = ReducerState::default();
        let _ = state.apply_shell_signal(IngestShellSignalCommand {
            pid: 17,
            cwd: "/users/pete".to_string(),
            tty: "/dev/ttys008".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            recorded_at: "2026-02-28T00:00:00Z".to_string(),
        });

        let outcome = resolve_activation(
            &state,
            ResolveActivationCommand {
                project_path: "/users/pete/code/capacitor".to_string(),
                workspace_id: None,
            },
        );

        assert_eq!(
            outcome.plan.action,
            crate::domain::ActivationActionKind::LaunchNewTerminal
        );
    }
}
