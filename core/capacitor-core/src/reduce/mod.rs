use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, Utc};

use crate::domain::{
    AppSnapshot, DiagnosticsSummary, IngestHookEventCommand, IngestShellSignalCommand,
    MutateDelegationCommand, MutateRunCommand, MutationOutcome, ProjectDelegationState,
    ProjectSummary, ResolveRoutingCommand, RoutingView, RunState, SessionSummary, ShellSignal,
    ShellUnregisterCommand,
};

mod event_handler;
mod gc;
mod project_state;
mod routing;
mod session;
mod utils;

pub mod delegation;
pub mod run_reducer;

pub const GC_REASON_SOLE_DEAD_NO_SHELL: &str = "sole_dead_no_shell";
pub const GC_REASON_ORPHANED_STALE: &str = "orphaned_stale";

const STALE_EVENT_GRACE_SECS: i64 = 5;
const ORPHANED_SESSION_GRACE: Duration = Duration::minutes(5);
const SOLE_DEAD_SESSION_GRACE: Duration = Duration::minutes(10);
/// Must equal SOLE_DEAD_SESSION_GRACE — a shell signal that expires during one
/// GC cycle makes the sole session eligible for Idle transition on the next.
const SHELL_GC_RETENTION: Duration = Duration::minutes(10);
/// How recently a hook event must have arrived for the session to be
/// considered alive without shell corroboration.
const HOOK_ACTIVITY_ALIVE_SECS: i64 = 60;

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

#[cfg(test)]
use gc::cleanup_shells_at;
#[cfg(test)]
use routing::{select_canonical_routing_source, CanonicalRoutingSource, TmuxInventoryCandidate};
#[cfg(test)]
use session::{pid_alive_from_probe_result, should_skip_stop};

impl ReducerState {
    #[must_use]
    pub(crate) fn from_snapshot(snapshot: AppSnapshot) -> Self {
        let AppSnapshot {
            projects: snapshot_projects,
            sessions: snapshot_sessions,
            shells: snapshot_shells,
            routing: _,
            delegations: snapshot_delegations,
            runs: snapshot_runs,
            diagnostics,
            generated_at: _,
            snapshot_version: _,
            schema_version: _,
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

        let session_is_alive = gc::session_is_alive_map(&sessions, &shells, Utc::now());
        for session in sessions.values_mut() {
            session.is_alive = session_is_alive
                .get(&session.session_id)
                .copied()
                .unwrap_or(false);
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
        self.apply_hook_event_with_gc_reference_time(command, None)
    }

    #[must_use]
    pub(crate) fn apply_hook_event_with_gc_reference_time(
        &mut self,
        command: IngestHookEventCommand,
        gc_reference_time: Option<DateTime<Utc>>,
    ) -> MutationOutcome {
        event_handler::apply_hook_event_with_gc_reference_time(self, command, gc_reference_time)
    }

    #[must_use]
    pub(crate) fn apply_shell_signal(
        &mut self,
        command: IngestShellSignalCommand,
    ) -> MutationOutcome {
        event_handler::apply_shell_signal(self, command)
    }

    #[must_use]
    pub(crate) fn apply_shell_unregister(
        &mut self,
        command: ShellUnregisterCommand,
    ) -> MutationOutcome {
        event_handler::apply_shell_unregister(self, command)
    }

    #[must_use]
    pub(crate) fn apply_run_mutation(&mut self, command: MutateRunCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);
        run_reducer::cleanup_runs(&mut self.runs);
        run_reducer::apply_run_mutation(&mut self.runs, command)
    }

    #[must_use]
    pub(crate) fn apply_delegation_mutation(
        &mut self,
        command: MutateDelegationCommand,
    ) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);
        delegation::apply_delegation_mutation(&mut self.delegations, &mut self.last_error, command)
    }

    pub fn gc_stale_sessions(&mut self) -> bool {
        self.gc_stale_sessions_at(Utc::now())
    }

    pub(crate) fn gc_stale_sessions_at(&mut self, now: DateTime<Utc>) -> bool {
        gc::gc_stale_sessions_at(self, now)
    }

    #[must_use]
    pub(crate) fn snapshot(&self) -> AppSnapshot {
        let projects = self.projects.values().cloned().collect::<Vec<_>>();
        let delegations = self.delegations.values().cloned().collect::<Vec<_>>();

        let mut cleaned_shells = self.shells.clone();
        gc::cleanup_shells(&mut cleaned_shells);

        let session_is_alive =
            gc::session_is_alive_map(&self.sessions, &cleaned_shells, Utc::now());
        let mut sessions = self.sessions.values().cloned().collect::<Vec<_>>();
        for session in &mut sessions {
            session.is_alive = session_is_alive
                .get(&session.session_id)
                .copied()
                .unwrap_or(false);
        }
        sessions.sort_by(|left, right| {
            left.project_path
                .cmp(&right.project_path)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });

        let mut shells = cleaned_shells.values().cloned().collect::<Vec<_>>();
        shells.sort_by(|left, right| left.pid.cmp(&right.pid));
        let shell_count = shells.len() as u64;

        let routing = if cleaned_shells.len() == self.shells.len() {
            self.routing.values().cloned().collect::<Vec<_>>()
        } else {
            routing::routing_views_for(&self.projects, &self.sessions, &cleaned_shells)
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
            generated_at: crate::domain::now_rfc3339(),
            snapshot_version: 0,
            schema_version: 0,
        }
    }

    #[must_use]
    pub(crate) fn resolve_routing(&self, command: ResolveRoutingCommand) -> RoutingView {
        routing::resolve_routing(self, command)
    }

    fn recompute_projects(&mut self) {
        project_state::recompute_projects(self);
    }

    fn recompute_routing(&mut self) {
        routing::recompute_routing(self);
    }
}

#[cfg(test)]
mod tests;
