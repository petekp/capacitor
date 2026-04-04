use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};

use crate::domain::{
    default_workspace_id, normalize_path_for_matching, now_rfc3339, ProjectSummary,
    ResolveRoutingCommand, RoutingStatus, RoutingTarget, RoutingTargetKind, RoutingView,
    SessionSummary, ShellSignal, TmuxPaneInfo,
};
use crate::runtime::types::ParentApp;

use super::utils::{compare_timestamp_strings, paths_match, trimmed_value};
use super::ReducerState;

#[derive(Debug, Clone, Copy)]
pub(super) struct TmuxInventoryCandidate<'a> {
    pub(super) carrier: &'a ShellSignal,
    pub(super) pane: &'a TmuxPaneInfo,
    pub(super) rank: u8,
}

#[derive(Debug, Clone, Copy)]
pub(super) enum CanonicalRoutingSource<'a> {
    Shell(&'a ShellSignal),
    Inventory(TmuxInventoryCandidate<'a>),
    None,
}

pub(super) fn recompute_routing(state: &mut ReducerState) {
    state.routing = routing_views_for(&state.projects, &state.sessions, &state.shells);
}

pub(super) fn resolve_routing(state: &ReducerState, command: ResolveRoutingCommand) -> RoutingView {
    let project_path = normalize_path_for_matching(command.project_path.as_str());
    let workspace_id = trimmed_value(command.workspace_id.as_deref())
        .unwrap_or_else(|| default_workspace_id(project_path.as_str()));
    let session_name = trimmed_value(command.session_name.as_deref());
    let client_tty = trimmed_value(command.client_tty.as_deref());

    if session_name.is_none() && client_tty.is_none() {
        let key = routing_key(workspace_id.as_str(), project_path.as_str());
        if let Some(route) = state.routing.get(key.as_str()) {
            if route.project_path == project_path {
                return route.clone();
            }
        }
        if let Some(route) = state
            .routing
            .values()
            .find(|route| route.project_path == project_path)
        {
            return route.clone();
        }
    }

    derive_activation_routing_view(
        workspace_id.as_str(),
        project_path.as_str(),
        session_name.as_deref(),
        client_tty.as_deref(),
        state.shells.values(),
    )
}

pub(super) fn routing_views_for(
    projects: &BTreeMap<String, ProjectSummary>,
    sessions: &HashMap<String, SessionSummary>,
    shells: &HashMap<u32, ShellSignal>,
) -> BTreeMap<String, RoutingView> {
    let mut next = BTreeMap::new();

    for project in projects
        .values()
        .filter(|project| project.session_count > 0)
    {
        let sessions = sessions
            .values()
            .filter(|session| session.project_path == project.project_path)
            .collect::<Vec<_>>();
        let route = derive_routing_view(project, &sessions, shells.values());
        next.insert(
            routing_key(route.workspace_id.as_str(), route.project_path.as_str()),
            route,
        );
    }

    next
}

pub(super) fn select_canonical_routing_source<'a>(
    project_path: &str,
    shell: Option<&'a ShellSignal>,
    inventory_candidate: Option<TmuxInventoryCandidate<'a>>,
) -> CanonicalRoutingSource<'a> {
    match (shell, inventory_candidate) {
        (None, Some(candidate)) => CanonicalRoutingSource::Inventory(candidate),
        (Some(shell), Some(candidate)) if !paths_match(shell.cwd.as_str(), project_path) => {
            CanonicalRoutingSource::Inventory(candidate)
        }
        (Some(shell), _) => CanonicalRoutingSource::Shell(shell),
        (None, None) => CanonicalRoutingSource::None,
    }
}

fn derive_routing_view<'a>(
    project: &ProjectSummary,
    sessions: &[&SessionSummary],
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> RoutingView {
    derive_routing_core(
        project.workspace_id.as_str(),
        project.project_path.as_str(),
        shells,
        || project.updated_at.clone(),
        |shell_set| select_shell_for_project(project, sessions, shell_set.iter().copied()),
    )
}

fn derive_activation_routing_view<'a>(
    workspace_id: &str,
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> RoutingView {
    derive_routing_core(
        workspace_id,
        project_path,
        shells,
        now_rfc3339,
        |shell_set| {
            select_shell_for_activation(
                project_path,
                session_name,
                client_tty,
                shell_set.iter().copied(),
            )
        },
    )
}

fn derive_routing_core<'a, MissingUpdatedAt, SelectShell>(
    workspace_id: &str,
    project_path: &str,
    shells: impl Iterator<Item = &'a ShellSignal>,
    missing_updated_at: MissingUpdatedAt,
    select_shell: SelectShell,
) -> RoutingView
where
    MissingUpdatedAt: FnOnce() -> String,
    SelectShell: FnOnce(&[&'a ShellSignal]) -> Option<&'a ShellSignal>,
{
    let shell_set = shells.collect::<Vec<_>>();
    let shell = select_shell(&shell_set);
    let inventory_candidate =
        select_tmux_inventory_for_project(project_path, shell_set.iter().copied());
    let routing_source = select_canonical_routing_source(project_path, shell, inventory_candidate);
    let (status, target, reason_code, reason, updated_at) = match routing_source {
        CanonicalRoutingSource::Inventory(candidate) => {
            routing_for_tmux_inventory(candidate, &shell_set)
        }
        CanonicalRoutingSource::Shell(shell) => routing_for_shell(shell, &shell_set),
        CanonicalRoutingSource::None => (
            RoutingStatus::Unavailable,
            RoutingTarget::default(),
            "NO_TRUSTED_EVIDENCE".to_string(),
            "No routing evidence available".to_string(),
            missing_updated_at(),
        ),
    };

    RoutingView {
        workspace_id: workspace_id.to_string(),
        project_path: project_path.to_string(),
        status,
        target,
        reason_code,
        reason,
        updated_at,
    }
}

fn select_shell_for_project<'a>(
    project: &ProjectSummary,
    sessions: &[&SessionSummary],
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> Option<&'a ShellSignal> {
    let session_pids = sessions
        .iter()
        .map(|session| session.pid)
        .filter(|pid| *pid > 0)
        .collect::<Vec<_>>();

    select_shell_core(
        shells,
        |shell| shell_matches_project(shell, project.project_path.as_str(), &session_pids),
        |left, right| {
            compare_shell_candidates(left, right, project.project_path.as_str(), &session_pids)
        },
    )
}

fn select_shell_for_activation<'a>(
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> Option<&'a ShellSignal> {
    select_shell_core(
        shells,
        |shell| activation_shell_match_rank(shell, project_path, session_name, client_tty) > 0,
        |left, right| {
            compare_activation_shell_candidates(left, right, project_path, session_name, client_tty)
        },
    )
}

fn select_shell_core<'a, Compare, Matches>(
    shells: impl Iterator<Item = &'a ShellSignal>,
    matches: Matches,
    compare: Compare,
) -> Option<&'a ShellSignal>
where
    Matches: Fn(&ShellSignal) -> bool,
    Compare: Fn(&ShellSignal, &ShellSignal) -> Ordering,
{
    shells
        .filter(|shell| matches(shell))
        .filter(|shell| !is_managed_worktree_shell(shell))
        .max_by(|left, right| compare(left, right))
}

fn is_managed_worktree_pane(pane: &TmuxPaneInfo) -> bool {
    is_path_in_managed_worktree(pane.pane_path.as_str())
}

/// Returns true if this pane belongs to a managed-worktree session — either
/// the session name matches the delegation naming convention, or the session
/// contains panes whose paths are in managed worktrees.
fn is_pane_in_managed_worktree_session(pane: &TmuxPaneInfo, all_panes: &[TmuxPaneInfo]) -> bool {
    if is_managed_session_name(&pane.session_name) {
        return true;
    }
    all_panes.iter().any(|p| {
        p.session_name == pane.session_name && is_path_in_managed_worktree(p.pane_path.as_str())
    })
}

fn select_tmux_inventory_for_project<'a>(
    project_path: &str,
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> Option<TmuxInventoryCandidate<'a>> {
    shells
        .flat_map(|carrier| {
            carrier.tmux_panes.iter().filter_map(move |pane| {
                let rank = tmux_inventory_match_rank(pane.pane_path.as_str(), project_path)?;
                Some(TmuxInventoryCandidate {
                    carrier,
                    pane,
                    rank,
                })
            })
        })
        .filter(|candidate| {
            !is_managed_worktree_pane(candidate.pane)
                && !is_pane_in_managed_worktree_session(
                    candidate.pane,
                    &candidate.carrier.tmux_panes,
                )
        })
        .max_by(|left, right| {
            left.rank
                .cmp(&right.rank)
                .then_with(|| left.pane.session_attached.cmp(&right.pane.session_attached))
                .then_with(|| {
                    compare_timestamp_strings(&left.carrier.updated_at, &right.carrier.updated_at)
                })
                .then_with(|| left.pane.pane_id.cmp(&right.pane.pane_id))
                .then_with(|| left.pane.session_name.cmp(&right.pane.session_name))
        })
}

fn is_path_in_managed_worktree(path: &str) -> bool {
    let normalized = normalize_path_for_matching(path);
    let marker = "/.capacitor/worktrees/";
    let Some(idx) = normalized.find(marker) else {
        return false;
    };
    // Must have at least one character (the worktree name) after the marker.
    idx + marker.len() < normalized.len()
}

fn is_managed_worktree_shell(shell: &ShellSignal) -> bool {
    if is_path_in_managed_worktree(shell.cwd.as_str()) {
        return true;
    }
    if let Some(session) = shell.tmux_session.as_ref() {
        // The session itself is a managed-worktree session (named "delegation-<hex>").
        if is_managed_session_name(session) {
            return true;
        }
        // Or the session contains panes whose paths are in managed worktrees.
        if shell.tmux_panes.iter().any(|pane| {
            pane.session_name == *session && is_path_in_managed_worktree(pane.pane_path.as_str())
        }) {
            return true;
        }
    }
    false
}

/// Returns true if a tmux session name matches the naming convention used by
/// managed worktree sessions (delegation workers).
fn is_managed_session_name(name: &str) -> bool {
    name.starts_with("delegation-")
}

fn compare_shell_candidates(
    left: &ShellSignal,
    right: &ShellSignal,
    project_path: &str,
    session_pids: &[u32],
) -> Ordering {
    (!is_managed_worktree_shell(left))
        .cmp(&(!is_managed_worktree_shell(right)))
        .then_with(|| {
            shell_match_rank(left, project_path, session_pids).cmp(&shell_match_rank(
                right,
                project_path,
                session_pids,
            ))
        })
        .then_with(|| shell_target_rank(left).cmp(&shell_target_rank(right)))
        .then_with(|| compare_timestamp_strings(&left.updated_at, &right.updated_at))
        .then_with(|| left.pid.cmp(&right.pid))
}

fn compare_activation_shell_candidates(
    left: &ShellSignal,
    right: &ShellSignal,
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
) -> Ordering {
    activation_shell_match_rank(left, project_path, session_name, client_tty)
        .cmp(&activation_shell_match_rank(
            right,
            project_path,
            session_name,
            client_tty,
        ))
        .then_with(|| shell_target_rank(left).cmp(&shell_target_rank(right)))
        .then_with(|| compare_timestamp_strings(&left.updated_at, &right.updated_at))
        .then_with(|| left.pid.cmp(&right.pid))
}

fn shell_matches_project(shell: &ShellSignal, project_path: &str, session_pids: &[u32]) -> bool {
    shell_match_rank(shell, project_path, session_pids) > 0
}

fn shell_match_rank(shell: &ShellSignal, project_path: &str, session_pids: &[u32]) -> u8 {
    if session_pids.contains(&shell.pid) {
        2
    } else if paths_match(shell.cwd.as_str(), project_path) {
        1
    } else {
        0
    }
}

fn activation_shell_match_rank(
    shell: &ShellSignal,
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
) -> u8 {
    let project_path_matches = paths_match(shell.cwd.as_str(), project_path);
    let session_matches = session_name.is_some_and(|expected| {
        shell
            .tmux_session
            .as_deref()
            .is_some_and(|actual| actual == expected)
    });

    if let Some(client_tty) = client_tty {
        if shell
            .tmux_client_tty
            .as_deref()
            .map(str::trim)
            .is_some_and(|tty| tty == client_tty)
        {
            4
        } else if shell.tty.trim() == client_tty {
            3
        } else if session_matches {
            2
        } else if project_path_matches {
            1
        } else {
            0
        }
    } else if project_path_matches && session_matches {
        3
    } else if project_path_matches {
        2
    } else if session_matches {
        1
    } else {
        0
    }
}

fn shell_target_rank(shell: &ShellSignal) -> u8 {
    if shell.tmux_pane.is_some() {
        3
    } else if shell.tmux_session.is_some() {
        2
    } else if routing_parent_app(shell.parent_app.as_str()).is_some() {
        1
    } else {
        0
    }
}

fn routing_for_shell(
    shell: &ShellSignal,
    shells: &[&ShellSignal],
) -> (RoutingStatus, RoutingTarget, String, String, String) {
    if let Some(pane) = shell.tmux_pane.as_ref() {
        let status = if shell
            .tmux_client_tty
            .as_ref()
            .is_some_and(|tty| !tty.trim().is_empty())
        {
            RoutingStatus::Attached
        } else {
            RoutingStatus::Detached
        };
        return (
            status,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxPane,
                terminal_app: infer_attached_tmux_terminal_app(shell, shells),
                session_name: shell.tmux_session.clone(),
                pane_id: Some(pane.clone()),
                host_tty: shell.tmux_client_tty.clone(),
            },
            match status {
                RoutingStatus::Attached => "TMUX_PANE_ATTACHED".to_string(),
                RoutingStatus::Detached => "TMUX_PANE_DETACHED".to_string(),
                RoutingStatus::Unavailable => "TMUX_PANE_UNAVAILABLE".to_string(),
            },
            format!("Matched tmux pane '{pane}'"),
            shell.updated_at.clone(),
        );
    }

    if let Some(session) = shell.tmux_session.as_ref() {
        let status = if shell
            .tmux_client_tty
            .as_ref()
            .is_some_and(|tty| !tty.trim().is_empty())
        {
            RoutingStatus::Attached
        } else {
            RoutingStatus::Detached
        };
        return (
            status,
            RoutingTarget {
                kind: RoutingTargetKind::TmuxSession,
                terminal_app: infer_attached_tmux_terminal_app(shell, shells),
                session_name: Some(session.clone()),
                pane_id: None,
                host_tty: shell.tmux_client_tty.clone(),
            },
            match status {
                RoutingStatus::Attached => "TMUX_SESSION_ATTACHED".to_string(),
                RoutingStatus::Detached => "TMUX_SESSION_DETACHED".to_string(),
                RoutingStatus::Unavailable => "TMUX_SESSION_UNAVAILABLE".to_string(),
            },
            format!("Matched tmux session '{session}'"),
            shell.updated_at.clone(),
        );
    }

    if let Some(parent_app) = routing_parent_app(shell.parent_app.as_str()) {
        return (
            RoutingStatus::Detached,
            RoutingTarget {
                kind: RoutingTargetKind::TerminalApp,
                terminal_app: Some(parent_app.clone()),
                session_name: None,
                pane_id: None,
                host_tty: None,
            },
            "TERMINAL_APP_DETACHED".to_string(),
            format!("Matched terminal app '{parent_app}'"),
            shell.updated_at.clone(),
        );
    }

    (
        RoutingStatus::Unavailable,
        RoutingTarget::default(),
        "NO_TRUSTED_EVIDENCE".to_string(),
        "No routing evidence available".to_string(),
        shell.updated_at.clone(),
    )
}

fn routing_for_tmux_inventory(
    candidate: TmuxInventoryCandidate<'_>,
    shells: &[&ShellSignal],
) -> (RoutingStatus, RoutingTarget, String, String, String) {
    let attached_shell = shells
        .iter()
        .copied()
        .filter(|shell| {
            shell.tmux_session.as_deref() == Some(candidate.pane.session_name.as_str())
                && shell
                    .tmux_client_tty
                    .as_deref()
                    .is_some_and(|tty| !tty.trim().is_empty())
        })
        .max_by(|left, right| {
            compare_timestamp_strings(&left.updated_at, &right.updated_at)
                .then_with(|| left.pid.cmp(&right.pid))
        });

    let status = if attached_shell.is_some() || candidate.pane.session_attached {
        RoutingStatus::Attached
    } else {
        RoutingStatus::Detached
    };
    let terminal_app =
        attached_shell.and_then(|shell| infer_attached_tmux_terminal_app(shell, shells));
    let host_tty = attached_shell.and_then(|shell| shell.tmux_client_tty.clone());

    (
        status,
        RoutingTarget {
            kind: RoutingTargetKind::TmuxPane,
            terminal_app,
            session_name: Some(candidate.pane.session_name.clone()),
            pane_id: Some(candidate.pane.pane_id.clone()),
            host_tty,
        },
        match status {
            RoutingStatus::Attached => "TMUX_PANE_ATTACHED".to_string(),
            RoutingStatus::Detached => "TMUX_PANE_DETACHED".to_string(),
            RoutingStatus::Unavailable => "TMUX_PANE_UNAVAILABLE".to_string(),
        },
        format!(
            "Matched tmux pane '{}' from pane inventory",
            candidate.pane.pane_id
        ),
        candidate.carrier.updated_at.clone(),
    )
}

fn infer_attached_tmux_terminal_app(
    shell: &ShellSignal,
    shells: &[&ShellSignal],
) -> Option<String> {
    if let Some(app) = routing_parent_app(shell.parent_app.as_str()) {
        return Some(app);
    }

    let host_tty = shell
        .tmux_client_tty
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())?;

    shells
        .iter()
        .filter_map(|candidate| {
            let app = routing_parent_app(candidate.parent_app.as_str())?;
            let rank = if candidate.tty.trim() == host_tty {
                2
            } else if candidate
                .tmux_client_tty
                .as_deref()
                .map(str::trim)
                .is_some_and(|tty| tty == host_tty)
            {
                1
            } else {
                return None;
            };

            Some((rank, candidate.updated_at.as_str(), candidate.pid, app))
        })
        .max_by(|left, right| {
            left.0
                .cmp(&right.0)
                .then_with(|| compare_timestamp_strings(left.1, right.1))
                .then_with(|| left.2.cmp(&right.2))
        })
        .map(|(_, _, _, app)| app)
}

fn tmux_inventory_match_rank(pane_path: &str, project_path: &str) -> Option<u8> {
    let pane_path = normalize_path_for_matching(pane_path);
    let project_path = normalize_path_for_matching(project_path);

    if pane_path == project_path {
        Some(2)
    } else if pane_path
        .strip_prefix(project_path.as_str())
        .is_some_and(|rest| rest.starts_with('/'))
    {
        Some(1)
    } else {
        None
    }
}

fn routing_parent_app(value: &str) -> Option<String> {
    let normalized = ParentApp::from_string(value);
    if matches!(normalized, ParentApp::Unknown | ParentApp::Tmux) {
        return None;
    }

    serde_json::to_string(&normalized)
        .ok()
        .map(|value| value.trim_matches('"').to_string())
}

fn routing_key(workspace_id: &str, project_path: &str) -> String {
    if workspace_id.trim().is_empty() {
        project_path.to_string()
    } else {
        workspace_id.to_string()
    }
}
