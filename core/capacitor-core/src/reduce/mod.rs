use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, Utc};

use crate::domain::{
    default_workspace_id, display_name, normalize_path_for_matching, now_rfc3339,
    resolve_project_identity, workspace_id, AppSnapshot, DiagnosticsSummary, HookEventType,
    IngestHookEventCommand, IngestShellSignalCommand, MutateDelegationCommand, MutateRunCommand,
    MutationOutcome, ProjectDelegationState, ProjectSummary, ResolveRoutingCommand, RoutingStatus,
    RoutingTarget, RoutingTargetKind, RoutingView, RunState, SessionState, SessionSummary,
    ShellSignal, TmuxPaneInfo,
};
use crate::runtime_types::ParentApp;

pub mod delegation;
pub mod run_reducer;

const STALE_EVENT_GRACE_SECS: i64 = 5;
const SHELL_SIGNAL_RETENTION: Duration = Duration::hours(4);

#[derive(Debug, Default, Clone)]
pub struct ReducerState {
    pub projects: BTreeMap<String, ProjectSummary>,
    pub delegations: BTreeMap<String, ProjectDelegationState>,
    pub runs: BTreeMap<String, RunState>,
    pub sessions: HashMap<String, SessionSummary>,
    pub shells: HashMap<u32, ShellSignal>,
    pub routing: BTreeMap<String, crate::domain::RoutingView>,
    pub events_ingested: u64,
    pub stale_events_skipped: u64,
    pub informational_events_skipped: u64,
    pub reducer_events_skipped: u64,
    pub last_error: Option<String>,
    pub last_hook_event_at: Option<String>,
}

#[allow(clippy::large_enum_variant)]
enum SessionUpdate {
    Upsert(SessionSummary),
    Delete(String),
    Skip(&'static str),
}

impl ReducerState {
    #[must_use]
    pub fn from_snapshot(snapshot: AppSnapshot) -> Self {
        let AppSnapshot {
            projects: snapshot_projects,
            sessions: snapshot_sessions,
            shells: snapshot_shells,
            routing: _,
            delegations: snapshot_delegations,
            runs: snapshot_runs,
            diagnostics,
            generated_at: _,
        } = snapshot;

        let mut projects = BTreeMap::new();
        for project in snapshot_projects {
            projects.insert(project.project_path.clone(), project);
        }

        let mut sessions = HashMap::new();
        for session in snapshot_sessions {
            sessions.insert(session.session_id.clone(), session);
        }

        let mut delegations = BTreeMap::new();
        for delegation in snapshot_delegations {
            delegations.insert(delegation.project_path.clone(), delegation);
        }

        let mut runs = BTreeMap::new();
        for run in snapshot_runs {
            let key = format!("{}#{}", run.project_path, run.id);
            runs.insert(key, run);
        }
        run_reducer::cleanup_runs(&mut runs);

        let mut shells = HashMap::new();
        for shell in snapshot_shells {
            shells.insert(shell.pid, shell);
        }

        let mut state = Self {
            projects,
            delegations,
            runs,
            sessions,
            shells,
            routing: BTreeMap::new(),
            events_ingested: diagnostics.events_ingested,
            stale_events_skipped: diagnostics.stale_events_skipped,
            informational_events_skipped: diagnostics.informational_events_skipped,
            reducer_events_skipped: diagnostics.reducer_events_skipped,
            last_error: diagnostics.last_error,
            last_hook_event_at: diagnostics.last_hook_event_at,
        };
        state.recompute_projects();
        state.recompute_routing();
        state
    }

    #[must_use]
    pub fn apply_hook_event(&mut self, command: IngestHookEventCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);

        if command.event_id.is_empty() {
            self.last_error = Some("ingest_hook_event missing event_id".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing event_id".to_string(),
            };
        }

        if command.session_id.is_empty() {
            self.last_error = Some("ingest_hook_event missing session_id".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing session_id".to_string(),
            };
        }

        self.last_hook_event_at = Some(if command.recorded_at.is_empty() {
            now_rfc3339()
        } else {
            command.recorded_at.clone()
        });

        let current = self.sessions.get(&command.session_id).cloned();
        if is_event_stale(current.as_ref(), &command) {
            self.stale_events_skipped += 1;
            return MutationOutcome {
                ok: true,
                message: "stale event skipped".to_string(),
            };
        }

        let update = reduce_session(current.as_ref(), &command);
        match &update {
            SessionUpdate::Upsert(session) => {
                self.sessions
                    .insert(session.session_id.clone(), session.clone());
            }
            SessionUpdate::Delete(session_id) => {
                self.sessions.remove(session_id);
            }
            SessionUpdate::Skip(reason) => {
                if is_informational_skip_reason(reason) {
                    self.informational_events_skipped += 1;
                } else {
                    self.reducer_events_skipped += 1;
                }
            }
        }

        self.recompute_projects();
        self.recompute_routing();

        match update {
            SessionUpdate::Upsert(_) => MutationOutcome {
                ok: true,
                message: "event ingested".to_string(),
            },
            SessionUpdate::Delete(_) => MutationOutcome {
                ok: true,
                message: "session ended".to_string(),
            },
            SessionUpdate::Skip(reason) => MutationOutcome {
                ok: true,
                message: format!("event skipped: {reason}"),
            },
        }
    }

    #[must_use]
    pub fn apply_shell_signal(&mut self, command: IngestShellSignalCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);

        if command.cwd.is_empty() || command.tty.is_empty() {
            self.last_error = Some("ingest_shell_signal missing cwd or tty".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing cwd or tty".to_string(),
            };
        }

        let updated_at = if command.recorded_at.is_empty() {
            now_rfc3339()
        } else {
            command.recorded_at
        };

        let current = self.shells.get(&command.pid);
        if is_shell_signal_stale(current, updated_at.as_str()) {
            self.stale_events_skipped += 1;
            return MutationOutcome {
                ok: true,
                message: "stale shell signal skipped".to_string(),
            };
        }

        let shell = ShellSignal {
            pid: command.pid,
            cwd: normalize_path_for_matching(&command.cwd),
            tty: command.tty,
            parent_app: command.parent_app,
            tmux_session: command.tmux_session,
            tmux_client_tty: command.tmux_client_tty,
            tmux_pane: command.tmux_pane,
            tmux_panes: command.tmux_panes,
            updated_at,
        };
        self.shells.insert(shell.pid, shell);
        self.recompute_routing();

        MutationOutcome {
            ok: true,
            message: "shell signal ingested".to_string(),
        }
    }

    #[must_use]
    pub fn apply_run_mutation(&mut self, command: MutateRunCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);
        run_reducer::cleanup_runs(&mut self.runs);
        run_reducer::apply_run_mutation(&mut self.runs, command)
    }

    #[must_use]
    pub fn apply_delegation_mutation(
        &mut self,
        command: MutateDelegationCommand,
    ) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);
        delegation::apply_delegation_mutation(&mut self.delegations, &mut self.last_error, command)
    }
    #[must_use]
    pub fn snapshot(&self) -> AppSnapshot {
        let projects = self.projects.values().cloned().collect::<Vec<_>>();
        let delegations = self.delegations.values().cloned().collect::<Vec<_>>();

        let mut sessions = self.sessions.values().cloned().collect::<Vec<_>>();
        sessions.sort_by(|left, right| {
            left.project_path
                .cmp(&right.project_path)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });

        let mut cleaned_shells = self.shells.clone();
        cleanup_shells(&mut cleaned_shells);
        let mut shells = cleaned_shells.values().cloned().collect::<Vec<_>>();
        shells.sort_by(|left, right| left.pid.cmp(&right.pid));
        let shell_count = shells.len() as u64;

        let routing = if cleaned_shells.len() == self.shells.len() {
            self.routing.values().cloned().collect::<Vec<_>>()
        } else {
            routing_views_for(&self.projects, &self.sessions, &cleaned_shells)
                .into_values()
                .collect::<Vec<_>>()
        };

        let mut runs = self.runs.clone();
        run_reducer::cleanup_runs(&mut runs);
        let runs = runs.into_values().collect::<Vec<_>>();

        AppSnapshot {
            projects,
            sessions,
            shells,
            routing,
            delegations,
            runs,
            diagnostics: DiagnosticsSummary {
                events_ingested: self.events_ingested,
                sessions_tracked: self.sessions.len() as u64,
                shell_signals_tracked: shell_count,
                events_skipped: self.stale_events_skipped
                    + self.informational_events_skipped
                    + self.reducer_events_skipped,
                stale_events_skipped: self.stale_events_skipped,
                informational_events_skipped: self.informational_events_skipped,
                reducer_events_skipped: self.reducer_events_skipped,
                last_error: self.last_error.clone(),
                last_hook_event_at: self.last_hook_event_at.clone(),
            },
            generated_at: now_rfc3339(),
        }
    }

    #[must_use]
    pub fn resolve_routing(&self, command: ResolveRoutingCommand) -> RoutingView {
        let project_path = normalize_path_for_matching(command.project_path.as_str());
        let workspace_id = normalized_value(command.workspace_id.as_deref())
            .unwrap_or_else(|| default_workspace_id(project_path.as_str()));
        let session_name = normalized_value(command.session_name.as_deref());
        let client_tty = normalized_value(command.client_tty.as_deref());

        if session_name.is_none() && client_tty.is_none() {
            let key = routing_key(workspace_id.as_str(), project_path.as_str());
            if let Some(route) = self.routing.get(key.as_str()) {
                if route.project_path == project_path {
                    return route.clone();
                }
            }
            if let Some(route) = self
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
            self.shells.values(),
        )
    }

    fn recompute_projects(&mut self) {
        let mut next = BTreeMap::new();

        for existing in self.projects.values() {
            next.insert(
                existing.project_path.clone(),
                ProjectSummary {
                    project_path: existing.project_path.clone(),
                    project_id: existing.project_id.clone(),
                    workspace_id: existing.workspace_id.clone(),
                    display_name: existing.display_name.clone(),
                    state: SessionState::Idle,
                    state_changed_at: existing.state_changed_at.clone(),
                    updated_at: existing.updated_at.clone(),
                    representative_session_id: None,
                    latest_session_id: None,
                    session_count: 0,
                    active_count: 0,
                    has_session: false,
                },
            );
        }

        let mut by_project: HashMap<String, Vec<&SessionSummary>> = HashMap::new();
        for session in self.sessions.values() {
            if session.project_path.is_empty() {
                continue;
            }
            by_project
                .entry(session.project_path.clone())
                .or_default()
                .push(session);
        }

        for (project_path, sessions) in by_project {
            let Some(reduced) = reduce_project_sessions(&project_path, &sessions) else {
                continue;
            };

            let entry = next
                .entry(project_path.clone())
                .or_insert_with(|| ProjectSummary {
                    project_path: project_path.clone(),
                    project_id: reduced.project_id.clone(),
                    workspace_id: reduced.workspace_id.clone(),
                    display_name: display_name(&project_path),
                    state: SessionState::Idle,
                    state_changed_at: reduced.state_changed_at.clone(),
                    updated_at: reduced.updated_at.clone(),
                    representative_session_id: None,
                    latest_session_id: None,
                    session_count: 0,
                    active_count: 0,
                    has_session: false,
                });

            entry.project_id = reduced.project_id;
            entry.workspace_id = reduced.workspace_id;
            entry.display_name = if entry.display_name.trim().is_empty() {
                display_name(&project_path)
            } else {
                entry.display_name.clone()
            };
            entry.state = reduced.state;
            entry.state_changed_at = reduced.state_changed_at;
            entry.updated_at = reduced.updated_at;
            entry.representative_session_id = reduced.representative_session_id;
            entry.latest_session_id = reduced.latest_session_id;
            entry.session_count = reduced.session_count;
            entry.active_count = reduced.active_count;
            entry.has_session = reduced.session_count > 0;
        }

        self.projects = next;
    }

    fn recompute_routing(&mut self) {
        self.routing = routing_views_for(&self.projects, &self.sessions, &self.shells);
    }
}

#[derive(Debug, Clone)]
struct ReducedProjectState {
    project_id: String,
    workspace_id: String,
    state: SessionState,
    representative_session_id: Option<String>,
    latest_session_id: Option<String>,
    state_changed_at: String,
    updated_at: String,
    session_count: u64,
    active_count: u64,
}

#[derive(Debug, Clone, Copy)]
struct TmuxInventoryCandidate<'a> {
    carrier: &'a ShellSignal,
    pane: &'a TmuxPaneInfo,
    rank: u8,
}

#[derive(Debug, Clone, Copy)]
enum CanonicalRoutingSource<'a> {
    Shell(&'a ShellSignal),
    Inventory(TmuxInventoryCandidate<'a>),
    None,
}

fn select_canonical_routing_source<'a>(
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
    let shell_set = shells.collect::<Vec<_>>();
    let shell = select_shell_for_project(project, sessions, shell_set.iter().copied());
    let inventory_candidate =
        select_tmux_inventory_for_project(project.project_path.as_str(), shell_set.iter().copied());
    let routing_source =
        select_canonical_routing_source(project.project_path.as_str(), shell, inventory_candidate);
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
            project.updated_at.clone(),
        ),
    };

    RoutingView {
        workspace_id: project.workspace_id.clone(),
        project_path: project.project_path.clone(),
        status,
        target,
        reason_code,
        reason,
        updated_at,
    }
}

fn derive_activation_routing_view<'a>(
    workspace_id: &str,
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> RoutingView {
    let shell_set = shells.collect::<Vec<_>>();
    let shell = select_shell_for_activation(
        project_path,
        session_name,
        client_tty,
        shell_set.iter().copied(),
    );
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
            now_rfc3339(),
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

    shells
        .filter(|shell| shell_matches_project(shell, project.project_path.as_str(), &session_pids))
        .filter(|shell| !is_managed_worktree_shell(shell))
        .max_by(|left, right| {
            compare_shell_candidates(left, right, project.project_path.as_str(), &session_pids)
        })
}

fn select_shell_for_activation<'a>(
    project_path: &str,
    session_name: Option<&str>,
    client_tty: Option<&str>,
    shells: impl Iterator<Item = &'a ShellSignal>,
) -> Option<&'a ShellSignal> {
    shells
        .filter(|shell| {
            activation_shell_match_rank(shell, project_path, session_name, client_tty) > 0
        })
        .filter(|shell| !is_managed_worktree_shell(shell))
        .max_by(|left, right| {
            compare_activation_shell_candidates(left, right, project_path, session_name, client_tty)
        })
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
            (!is_managed_worktree_pane(left.pane))
                .cmp(&(!is_managed_worktree_pane(right.pane)))
                .then_with(|| left.rank.cmp(&right.rank))
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
    // Must have at least one character (the worktree name) after the marker
    idx + marker.len() < normalized.len()
}

fn is_managed_worktree_shell(shell: &ShellSignal) -> bool {
    if is_path_in_managed_worktree(shell.cwd.as_str()) {
        return true;
    }
    if let Some(session) = shell.tmux_session.as_ref() {
        // The session itself is a managed-worktree session (named "delegation-<hex>")
        if is_managed_session_name(session) {
            return true;
        }
        // Or the session contains panes whose paths are in managed worktrees
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

fn normalized_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn trimmed_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn routing_key(workspace_id: &str, project_path: &str) -> String {
    if workspace_id.trim().is_empty() {
        project_path.to_string()
    } else {
        workspace_id.to_string()
    }
}

fn reduce_project_sessions(
    project_path: &str,
    sessions: &[&SessionSummary],
) -> Option<ReducedProjectState> {
    let representative = sessions.iter().max_by(|left, right| {
        left.state
            .priority()
            .cmp(&right.state.priority())
            .then_with(|| compare_timestamp_strings(&left.updated_at, &right.updated_at))
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let latest = sessions.iter().max_by(|left, right| {
        compare_timestamp_strings(&left.updated_at, &right.updated_at)
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let project_id = if !representative.project_id.is_empty() {
        representative.project_id.clone()
    } else if !latest.project_id.is_empty() {
        latest.project_id.clone()
    } else {
        project_path.to_string()
    };

    let workspace = if !representative.workspace_id.is_empty() {
        representative.workspace_id.clone()
    } else if !latest.workspace_id.is_empty() {
        latest.workspace_id.clone()
    } else {
        workspace_id(&project_id, project_path)
    };

    let active_count = sessions
        .iter()
        .filter(|session| session.state.is_active())
        .count() as u64;

    Some(ReducedProjectState {
        project_id,
        workspace_id: workspace,
        state: representative.state,
        representative_session_id: Some(representative.session_id.clone()),
        latest_session_id: Some(latest.session_id.clone()),
        state_changed_at: representative.state_changed_at.clone(),
        updated_at: latest.updated_at.clone(),
        session_count: sessions.len() as u64,
        active_count,
    })
}

fn reduce_session(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
) -> SessionUpdate {
    match event.event_type {
        HookEventType::SessionStart => {
            let already_working = current
                .map(|record| {
                    record.state == SessionState::Working || record.state == SessionState::Waiting
                })
                .unwrap_or(false);
            if already_working {
                SessionUpdate::Skip("session_start_already_active")
            } else {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Ready, None))
            }
        }
        HookEventType::UserPromptSubmit | HookEventType::PreToolUse => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
        }
        HookEventType::PostToolUse | HookEventType::PostToolUseFailure => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
        }
        HookEventType::PermissionRequest => {
            // Guard: if tools_in_flight == 0, the tool already completed and this
            // PermissionRequest arrived late. Skip it to avoid overwriting Working.
            if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                SessionUpdate::Skip("permission_request_no_tools_in_flight")
            } else {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Waiting, None))
            }
        }
        HookEventType::PreCompact => SessionUpdate::Upsert(upsert_session(
            current,
            event,
            SessionState::Compacting,
            None,
        )),
        HookEventType::Notification => match event.notification_type.as_deref() {
            Some("idle_prompt") => {
                if current
                    .map(|record| record.tools_in_flight > 0)
                    .unwrap_or(false)
                {
                    let mut corrected = upsert_session(
                        current,
                        event,
                        current
                            .map(|record| record.state)
                            .unwrap_or(SessionState::Working),
                        current.and_then(|record| record.ready_reason.clone()),
                    );
                    corrected.tools_in_flight = 0;
                    SessionUpdate::Upsert(corrected)
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        event,
                        SessionState::Ready,
                        Some("idle_prompt".to_string()),
                    ))
                }
            }
            Some("auth_success") => SessionUpdate::Upsert(upsert_session(
                current,
                event,
                SessionState::Ready,
                Some("auth_success".to_string()),
            )),
            Some("permission_prompt") => {
                // Guard: if tools_in_flight == 0, the tool already completed and
                // this notification arrived late. Skip to avoid overwriting Working.
                if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                    SessionUpdate::Skip("permission_prompt_no_tools_in_flight")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        event,
                        SessionState::Waiting,
                        Some("permission_prompt".to_string()),
                    ))
                }
            }
            Some("elicitation_dialog") => {
                // Guard: if tools_in_flight == 0, the tool already completed and
                // this notification arrived late. Skip to avoid overwriting Working.
                if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                    SessionUpdate::Skip("elicitation_dialog_no_tools_in_flight")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        event,
                        SessionState::Waiting,
                        None,
                    ))
                }
            }
            _ => SessionUpdate::Skip("notification_non_stateful"),
        },
        HookEventType::Stop => {
            if should_skip_stop(event) {
                SessionUpdate::Skip("stop_guard")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("stop_gate".to_string()),
                ))
            }
        }
        HookEventType::TaskCompleted => {
            if has_auxiliary_task_metadata(event) {
                SessionUpdate::Skip("auxiliary_task_metadata")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("task_completed".to_string()),
                ))
            }
        }
        HookEventType::SessionEnd => {
            let pid = event
                .pid
                .or_else(|| current.map(|record| record.pid))
                .unwrap_or(0);
            if pid > 0 && is_pid_alive(pid) {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("session_cleared".to_string()),
                ))
            } else {
                SessionUpdate::Delete(event.session_id.clone())
            }
        }
        HookEventType::SubagentStart => {
            if current_has_higher_priority_state(current) {
                SessionUpdate::Skip("subagent_start_higher_priority_active")
            } else {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
            }
        }
        HookEventType::SubagentStop => {
            if current_has_higher_priority_state(current) {
                SessionUpdate::Skip("subagent_stop_higher_priority_active")
            } else if current
                .map(|record| record.state == SessionState::Working && record.tools_in_flight > 0)
                .unwrap_or(false)
            {
                // Other tools are still in flight — the session is genuinely active.
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
            } else if current
                .map(|record| record.state == SessionState::Working)
                .unwrap_or(false)
            {
                // Working with no tools in flight: the parent LLM may still be
                // generating, but we must not refresh updated_at so the existing
                // staleness clock (SessionStaleness + PID liveness) remains valid
                // as a self-heal backstop if Stop never fires.
                SessionUpdate::Skip("subagent_stop_working_no_tools")
            } else {
                // Late background-agent completions must not upgrade or create a session.
                SessionUpdate::Skip("subagent_stop_session_not_working")
            }
        }
        HookEventType::TeammateIdle => SessionUpdate::Skip("teammate_idle_informational"),
        HookEventType::WorktreeCreate => SessionUpdate::Skip("worktree_create_informational"),
        HookEventType::WorktreeRemove => SessionUpdate::Skip("worktree_remove_informational"),
        HookEventType::ConfigChange => SessionUpdate::Skip("config_change_informational"),
        HookEventType::Unknown => SessionUpdate::Skip("unknown_event_type"),
    }
}

fn upsert_session(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
    new_state: SessionState,
    ready_reason: Option<String>,
) -> SessionSummary {
    let pid = event
        .pid
        .or_else(|| current.map(|record| record.pid))
        .unwrap_or(0);

    let cwd = event
        .cwd
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(normalize_path_for_matching)
        .or_else(|| {
            current
                .map(|record| normalize_path_for_matching(&record.cwd))
                .filter(|value| !value.is_empty())
        })
        .or_else(|| {
            if event.project_path.is_empty() {
                None
            } else {
                Some(normalize_path_for_matching(&event.project_path))
            }
        })
        .unwrap_or_default();

    let (project_path, project_id) = derive_project_identity(current, event, &cwd);

    let workspace = event
        .workspace_id
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| workspace_id(&project_id, &project_path));

    let updated_at = if event.recorded_at.is_empty() {
        now_rfc3339()
    } else {
        event.recorded_at.clone()
    };

    let state_changed_at = match current {
        Some(record) if record.state == new_state => record.state_changed_at.clone(),
        _ => updated_at.clone(),
    };

    let mut last_activity_at = current.and_then(|record| record.last_activity_at.clone());
    if should_update_activity(event.event_type) {
        last_activity_at = Some(updated_at.clone());
    }

    let tools_in_flight = adjust_tools_in_flight(
        current.map(|record| record.tools_in_flight).unwrap_or(0),
        event.event_type,
    );

    let next_ready_reason = if new_state == SessionState::Ready {
        ready_reason.or_else(|| current.and_then(|record| record.ready_reason.clone()))
    } else {
        None
    };

    SessionSummary {
        session_id: event.session_id.clone(),
        pid,
        cwd,
        project_id,
        project_path,
        workspace_id: workspace,
        state: new_state,
        state_changed_at,
        updated_at,
        last_event: Some(event.event_type.as_str().to_string()),
        last_activity_at,
        tools_in_flight,
        ready_reason: next_ready_reason,
    }
}

fn derive_project_identity(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
    cwd: &str,
) -> (String, String) {
    let identity_from_file = event
        .file_path
        .as_deref()
        .and_then(|file_path| resolve_file_path(cwd, file_path))
        .and_then(|resolved| resolve_project_identity(&resolved));

    let identity = identity_from_file
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                resolve_project_identity(cwd)
            }
        })
        .or_else(|| {
            if event.project_path.trim().is_empty() {
                None
            } else {
                resolve_project_identity(&event.project_path)
            }
        });

    let mut project_path = identity
        .as_ref()
        .map(|value| value.project_path.clone())
        .or_else(|| {
            current
                .map(|record| record.project_path.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                Some(cwd.to_string())
            }
        })
        .or_else(|| {
            if event.project_path.trim().is_empty() {
                None
            } else {
                Some(event.project_path.clone())
            }
        })
        .unwrap_or_default();

    let mut project_id = identity
        .as_ref()
        .map(|value| value.project_id.clone())
        .or_else(|| {
            current
                .map(|record| record.project_id.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or_else(|| project_path.clone());

    if event.file_path.is_none() {
        if let Some(current_record) = current {
            if !current_record.project_path.is_empty()
                && path_is_parent_or_self(&project_path, &current_record.project_path)
            {
                project_path = current_record.project_path.clone();
                if !current_record.project_id.trim().is_empty() {
                    project_id = current_record.project_id.clone();
                }
            }
        }
    }

    (
        normalize_path_for_matching(&project_path),
        normalize_path_for_matching(&project_id),
    )
}

fn resolve_file_path(cwd: &str, file_path: &str) -> Option<String> {
    let trimmed = file_path.trim();
    if trimmed.is_empty() {
        return None;
    }

    let path = std::path::Path::new(trimmed);
    if path.is_absolute() {
        return Some(path.to_string_lossy().to_string());
    }

    if cwd.trim().is_empty() {
        return None;
    }

    let combined = std::path::Path::new(cwd).join(path);
    Some(combined.to_string_lossy().to_string())
}

fn path_is_parent_or_self(parent: &str, child: &str) -> bool {
    let parent = normalize_path_for_matching(parent);
    let child = normalize_path_for_matching(child);

    if parent.is_empty() || child.is_empty() {
        return false;
    }

    parent == child || child.starts_with(&(parent + "/"))
}

fn should_update_activity(event_type: HookEventType) -> bool {
    matches!(
        event_type,
        HookEventType::UserPromptSubmit
            | HookEventType::PreToolUse
            | HookEventType::PostToolUse
            | HookEventType::PostToolUseFailure
            | HookEventType::PreCompact
    )
}

fn current_has_higher_priority_state(current: Option<&SessionSummary>) -> bool {
    current
        .map(|record| {
            record.state == SessionState::Waiting || record.state == SessionState::Compacting
        })
        .unwrap_or(false)
}

fn adjust_tools_in_flight(current: u32, event_type: HookEventType) -> u32 {
    match event_type {
        HookEventType::PreToolUse => current.saturating_add(1),
        HookEventType::PostToolUse | HookEventType::PostToolUseFailure => current.saturating_sub(1),
        HookEventType::SessionStart
        | HookEventType::SessionEnd
        | HookEventType::PreCompact
        | HookEventType::Stop
        | HookEventType::TaskCompleted => 0,
        _ => current,
    }
}

fn is_informational_skip_reason(reason: &str) -> bool {
    matches!(
        reason,
        "informational_event"
            | "teammate_idle_informational"
            | "worktree_create_informational"
            | "worktree_remove_informational"
            | "config_change_informational"
    )
}

fn has_auxiliary_task_metadata(event: &IngestHookEventCommand) -> bool {
    event
        .agent_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty())
        || event
            .teammate_name
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
}

fn should_skip_stop(event: &IngestHookEventCommand) -> bool {
    if event.stop_hook_active == Some(true) {
        return true;
    }

    event
        .agent_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty())
}

/// Checks whether a process is still running via `kill(pid, 0)`.
///
/// Used to distinguish `/clear` (process stays alive) from a true session exit
/// (process is gone). When the PID is alive at `SessionEnd` time, we transition
/// to `Ready` instead of deleting the session — avoiding a transient idle flicker
/// while Claude Code reinitializes the cleared conversation.
fn is_pid_alive(pid: u32) -> bool {
    // SAFETY: kill(pid, 0) is a standard POSIX call that checks process existence
    // without sending any signal. Returns 0 if the process exists, -1 otherwise.
    unsafe {
        let result = libc::kill(pid as libc::pid_t, 0);
        let errno = if result == -1 {
            std::io::Error::last_os_error().raw_os_error()
        } else {
            None
        };
        pid_alive_from_probe_result(result, errno)
    }
}

fn pid_alive_from_probe_result(result: libc::c_int, errno: Option<i32>) -> bool {
    result == 0 || (result == -1 && errno == Some(libc::EPERM))
}

fn is_event_stale(current: Option<&SessionSummary>, event: &IngestHookEventCommand) -> bool {
    let Some(current) = current else { return false };
    is_timestamp_stale(current.updated_at.as_str(), event.recorded_at.as_str())
}

fn is_shell_signal_stale(current: Option<&ShellSignal>, incoming_recorded_at: &str) -> bool {
    let Some(current) = current else { return false };
    is_timestamp_stale(current.updated_at.as_str(), incoming_recorded_at)
}

fn cleanup_shells(shells: &mut HashMap<u32, ShellSignal>) {
    cleanup_shells_at(shells, Utc::now());
}

fn cleanup_shells_at(shells: &mut HashMap<u32, ShellSignal>, now: DateTime<Utc>) {
    let expired_pids: Vec<u32> = shells
        .iter()
        .filter(|(_, shell)| {
            parse_rfc3339(&shell.updated_at)
                .map(|ts| now.signed_duration_since(ts) > SHELL_SIGNAL_RETENTION)
                .unwrap_or(false)
        })
        .map(|(pid, _)| *pid)
        .collect();
    for pid in expired_pids {
        shells.remove(&pid);
    }
}

fn is_timestamp_stale(current_updated_at: &str, incoming_recorded_at: &str) -> bool {
    let Some(incoming_time) = parse_rfc3339(incoming_recorded_at) else {
        return false;
    };
    let Some(current_time) = parse_rfc3339(current_updated_at) else {
        return false;
    };

    current_time
        .signed_duration_since(incoming_time)
        .num_seconds()
        > STALE_EVENT_GRACE_SECS
}

fn paths_match(left: &str, right: &str) -> bool {
    let shell_path = normalize_path_for_matching(left);
    let project_path = normalize_path_for_matching(right);

    if shell_path == project_path {
        return true;
    }

    shell_path
        .strip_prefix(project_path.as_str())
        .is_some_and(|rest| rest.starts_with('/'))
}

fn compare_timestamp_strings(left: &str, right: &str) -> Ordering {
    match (parse_rfc3339(left), parse_rfc3339(right)) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

fn routing_views_for(
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

#[cfg(test)]
mod tests;
