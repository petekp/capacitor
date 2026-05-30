use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, Utc};

use crate::domain::{
    AppSnapshot, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
    IngestOsLivenessCommand, IngestShellSignalCommand, MutateDelegationCommand,
    MutateProjectCommand, MutateRunCommand, MutationOutcome, ProjectDelegationState,
    ProjectSummary, ResolveRoutingCommand, RoutingView, RunState, SessionSummary, ShellSignal,
    ShellUnregisterCommand, SignalAuthority, StateSource,
};
use crate::observation::transcript::TranscriptDiscovery;

mod event_handler;
mod gc;
mod project;
mod project_state;
mod routing;
mod session;
mod utils;

pub mod delegation;
pub mod run_reducer;

pub const GC_REASON_SIGNAL_ABSENCE: &str = "signal_absence";

const STALE_EVENT_GRACE_SECS: i64 = 5;
/// Single GC safety net. Sessions with no observational or definitive
/// signal for this duration are transitioned to Idle. This is a recovery
/// mechanism for lost events, not a primary lifecycle driver.
const SIGNAL_ABSENCE_GRACE: Duration = Duration::minutes(10);
/// Idle sessions older than this are removed entirely. This prevents
/// unbounded accumulation from completed sessions.
const IDLE_RETENTION: Duration = Duration::hours(24);
/// Shell signals older than this are removed. Slightly longer than
/// SIGNAL_ABSENCE_GRACE to prevent shell cleanup from racing with
/// session GC.
const SHELL_RETENTION: Duration = Duration::minutes(15);
/// How recently a hook event must have arrived for the session to be
/// considered alive without shell corroboration.
/// Grace period for idle_prompt and SubagentStop: skip the Ready transition
/// if the session received a hook event within this window. Covers the typical
/// 2-6 second LLM thinking gap between tool calls.
const IDLE_PROMPT_GRACE_SECS: i64 = 8;
/// Freshness window for terminal-tier authority. Once a session receives a
/// `DefinitiveTerminal` event (session ended), strictly lower-authority
/// events cannot override it for this long. Long because "the session
/// ended" is a sticky fact that shouldn't be contradicted by a late
/// `idle_prompt` notification or an inferential observation. Sessions
/// typically GC after `IDLE_RETENTION` anyway, so this is effectively
/// lifetime-scoped under normal conditions. ADR-005 Phase 3 step 9.
const AUTHORITY_TERMINAL_FRESHNESS_SECS: i64 = 300;
/// Freshness window for non-terminal authority tiers (DefinitiveTransient,
/// AmbiguousPerTurn, MetaAwaitingInput, Inferential). Short, because the
/// state machine must be free to progress through hook-driven transitions
/// (e.g., `PreToolUse` → `Stop` → `idle_prompt`) without the guard
/// suppressing legitimate lower-authority events that arrive after a brief
/// settling period. Sized to block immediate reordered/duplicate lower
/// events (`< 3s` gap) while allowing the state machine to breathe.
/// ADR-005 Phase 3 step 9.
const AUTHORITY_NONTERMINAL_FRESHNESS_SECS: i64 = 3;
const HOOK_ACTIVITY_ALIVE_SECS: i64 = 180;

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
    #[allow(dead_code)]
    Delete(String),
    Skip(&'static str),
}

#[cfg(test)]
use gc::cleanup_shells_at;
#[cfg(test)]
use routing::{select_canonical_routing_source, CanonicalRoutingSource, TmuxInventoryCandidate};
#[cfg(test)]
use session::{classify_signal, should_skip_stop};

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
            change_version: _,
            disk_format_version: _,
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
    pub(crate) fn apply_os_liveness(
        &mut self,
        command: IngestOsLivenessCommand,
    ) -> MutationOutcome {
        event_handler::apply_os_liveness(self, command)
    }

    #[must_use]
    pub(crate) fn apply_transcript_discovery(
        &mut self,
        discovery: TranscriptDiscovery,
    ) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);

        let normalized_path = crate::domain::normalize_path_for_matching(&discovery.project_path);

        if let Some(existing) = self.sessions.get(&discovery.session_id) {
            let existing_authority = existing
                .state_source
                .as_ref()
                .map(|ss| session::classify_signal(ss.event_kind))
                .unwrap_or(SignalAuthority::Inferential);

            if existing_authority != SignalAuthority::Inferential {
                return MutationOutcome {
                    ok: true,
                    message: "transcript_discovery_skipped_higher_authority".to_string(),
                };
            }

            let mut updated = existing.clone();
            updated.updated_at = discovery.file_mtime_rfc3339.clone();
            updated.last_activity_at = Some(discovery.file_mtime_rfc3339.clone());
            updated.state_source = Some(StateSource {
                event_kind: HookEventType::TranscriptActivity,
                authority: SignalAuthority::Inferential,
                observed_at: discovery.file_mtime_rfc3339,
            });
            self.sessions.insert(discovery.session_id, updated);
        } else {
            let project_id = crate::domain::resolve_project_identity(&normalized_path)
                .map(|identity| identity.project_id)
                .unwrap_or_else(|| normalized_path.clone());
            let workspace_id = crate::domain::default_workspace_id(&normalized_path);

            let session = SessionSummary {
                session_id: discovery.session_id.clone(),
                pid: 0,
                cwd: normalized_path.clone(),
                project_id,
                project_path: normalized_path,
                workspace_id,
                state: crate::domain::SessionState::Idle,
                state_changed_at: discovery.file_mtime_rfc3339.clone(),
                updated_at: discovery.file_mtime_rfc3339.clone(),
                last_event: Some("transcript_activity".to_string()),
                last_activity_at: Some(discovery.file_mtime_rfc3339.clone()),
                terminated_at: None,
                tools_in_flight: 0,
                state_source: Some(StateSource {
                    event_kind: HookEventType::TranscriptActivity,
                    authority: SignalAuthority::Inferential,
                    observed_at: discovery.file_mtime_rfc3339,
                }),
                last_authoritative_event_at: None,
                is_alive: false,
                gc_reason: None,
                process_start_time: None,
                os_process_alive: None,
            };
            self.sessions.insert(discovery.session_id, session);
        }

        self.recompute_projects();
        self.recompute_routing();

        MutationOutcome {
            ok: true,
            message: "transcript_discovery_applied".to_string(),
        }
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

    #[must_use]
    pub(crate) fn apply_project_mutation(
        &mut self,
        command: MutateProjectCommand,
    ) -> MutationOutcome {
        project::apply_project_mutation(
            &mut self.projects,
            &mut self.delegations,
            &mut self.sessions,
            command,
        )
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
        shells.sort_by_key(|shell| shell.pid);
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
            // change_version is stamped by core_query::app_snapshot (live counter);
            // disk_format_version is stamped by storage on save. Reduce owns neither.
            change_version: 0,
            disk_format_version: 0,
            schema_version: crate::domain::SCHEMA_VERSION,
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
