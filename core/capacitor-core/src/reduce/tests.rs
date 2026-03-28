use chrono::{Duration, Utc};

use super::{
    select_canonical_routing_source, CanonicalRoutingSource, ReducerState, TmuxInventoryCandidate,
};
use crate::domain::{
    default_workspace_id, AppSnapshot, DelegationMutationKind, DelegationReviewDecision,
    DelegationStatus, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
    IngestShellSignalCommand, InvolvementLevel, MutateDelegationCommand, PhaseInstance,
    PhaseStatus, ResolveRoutingCommand, RoutingStatus, RoutingTargetKind, RoutingView, RunState,
    RunStatus, SessionState, SessionSummary, ShellSignal, TmuxPaneInfo,
};

fn event_base(event_type: HookEventType) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2026-01-31T00:00:00Z".to_string(),
        event_type,
        session_id: "session-1".to_string(),
        pid: Some(1234),
        project_path: "/repo".to_string(),
        cwd: Some("/repo".to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    }
}

fn assert_persisted_routing_matches_resolved_routing(
    state: &ReducerState,
    expected_project_path: &str,
) {
    let persisted = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == expected_project_path)
        .expect("persisted route");

    let resolved = state.resolve_routing(ResolveRoutingCommand {
        project_path: persisted.project_path.clone(),
        workspace_id: Some(persisted.workspace_id.clone()),
        session_name: None,
        client_tty: None,
    });

    assert_eq!(resolved, persisted);
}

fn persisted_route_for(state: &ReducerState, project_path: &str) -> RoutingView {
    state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == project_path)
        .expect("persisted route")
}

fn run_state_fixture(
    id: &str,
    status: RunStatus,
    created_at: String,
    updated_at: String,
) -> RunState {
    RunState {
        id: id.to_string(),
        project_path: "/repo".to_string(),
        method_id: "execution_only".to_string(),
        method_name: "Execute".to_string(),
        involvement: InvolvementLevel::Supervised,
        status,
        phases: vec![PhaseInstance {
            id: "phase-001".to_string(),
            template_id: "execute".to_string(),
            name: "Execute".to_string(),
            status: match status {
                RunStatus::Completed => PhaseStatus::Completed,
                RunStatus::Active | RunStatus::Paused => PhaseStatus::Active,
                _ => PhaseStatus::Pending,
            },
            checkpoint_policy: "manual".to_string(),
            skill_hint: None,
            started_at: None,
            completed_at: None,
        }],
        current_phase_index: 0,
        active_checkpoint: None,
        session_id: None,
        delegation_worker_id: None,
        status_message: None,
        idea_id: None,
        idea_title: None,
        idea_description: None,
        created_at,
        updated_at,
    }
}

fn shell_signal_fixture(pid: u32, cwd: &str) -> ShellSignal {
    ShellSignal {
        pid,
        cwd: cwd.to_string(),
        tty: format!("/dev/ttys{pid:03}"),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some(format!("%{pid}")),
        tmux_panes: vec![],
        updated_at: format!("2026-03-16T00:00:{:02}Z", pid % 60),
    }
}

fn session_summary_fixture(
    session_id: &str,
    pid: u32,
    project_path: &str,
    cwd: &str,
    state: SessionState,
    updated_at: &str,
) -> SessionSummary {
    SessionSummary {
        session_id: session_id.to_string(),
        pid,
        cwd: cwd.to_string(),
        project_id: project_path.to_string(),
        project_path: project_path.to_string(),
        workspace_id: default_workspace_id(project_path),
        state,
        state_changed_at: updated_at.to_string(),
        updated_at: updated_at.to_string(),
        last_event: None,
        last_activity_at: None,
        tools_in_flight: 0,
        ready_reason: None,
    }
}

fn routing_state_fixture(sessions: Vec<SessionSummary>, shells: Vec<ShellSignal>) -> ReducerState {
    ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions,
        shells,
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 0,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2026-03-27T00:00:00Z".to_string(),
    })
}

fn tmux_pane_fixture(pane_id: &str, pane_path: &str) -> TmuxPaneInfo {
    TmuxPaneInfo {
        session_name: "caps".to_string(),
        pane_id: pane_id.to_string(),
        pane_path: pane_path.to_string(),
        session_attached: true,
    }
}

fn delegation_start_command() -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::Start,
        project_path: "/repo".to_string(),
        worker_id: "worker-1".to_string(),
        idea_id: Some("idea-1".to_string()),
        worktree_name: Some("delegation-worker-1".to_string()),
        worktree_path: Some("/repo/.capacitor/worktrees/delegation-worker-1".to_string()),
        session_id: Some("session-1".to_string()),
        milestone_id: None,
        brief_path: None,
        manifest_path: None,
        review_decision: None,
        note: None,
    }
}

fn delegation_review_ready_command(milestone_id: &str) -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::ReviewReady,
        milestone_id: Some(milestone_id.to_string()),
        brief_path: Some(format!(
            "/repo/.capacitor/delegations/worker-1/milestones/{milestone_id}/brief.md"
        )),
        manifest_path: Some(format!(
            "/repo/.capacitor/delegations/worker-1/milestones/{milestone_id}/manifest.json"
        )),
        ..delegation_start_command()
    }
}

fn delegation_submit_review_command(
    review_decision: DelegationReviewDecision,
) -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::SubmitReview,
        review_decision: Some(review_decision),
        note: Some("Looks good".to_string()),
        ..delegation_start_command()
    }
}

fn delegation_resume_command() -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::Resume,
        ..delegation_start_command()
    }
}

fn delegation_resume_failed_command() -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::ResumeFailed,
        ..delegation_start_command()
    }
}

fn started_delegation_state() -> ReducerState {
    let mut state = ReducerState::default();
    let outcome = state.apply_delegation_mutation(delegation_start_command());
    assert!(outcome.ok, "{outcome:?}");
    state
}

fn review_ready_delegation_state(milestone_id: &str) -> ReducerState {
    let mut state = started_delegation_state();
    let outcome = state.apply_delegation_mutation(delegation_review_ready_command(milestone_id));
    assert!(outcome.ok, "{outcome:?}");
    state
}

fn resume_pending_delegation_state(milestone_id: &str) -> ReducerState {
    let mut state = review_ready_delegation_state(milestone_id);
    let outcome = state.apply_delegation_mutation(delegation_submit_review_command(
        DelegationReviewDecision::Approve,
    ));
    assert!(outcome.ok, "{outcome:?}");
    state
}

#[test]
fn submit_review_sets_resume_pending_and_preserves_current_review() {
    let mut state = review_ready_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_submit_review_command(
        DelegationReviewDecision::Approve,
    ));

    assert!(outcome.ok, "{outcome:?}");

    let delegation = state.delegations.get("/repo").expect("delegation");
    assert_eq!(delegation.status, DelegationStatus::ResumePending);
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01"),
    );
}

#[test]
fn resume_from_resume_pending_transitions_to_working_and_clears_review() {
    let mut state = resume_pending_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_resume_command());

    assert!(outcome.ok, "{outcome:?}");

    let delegation = state.delegations.get("/repo").expect("delegation");
    assert_eq!(delegation.status, DelegationStatus::Working);
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
    assert!(delegation.current_review.is_none());
}

#[test]
fn review_ready_is_rejected_when_resume_pending_for_submitted_milestone() {
    let mut state = resume_pending_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_review_ready_command("01"));

    assert!(!outcome.ok);
    assert_eq!(outcome.message, "review suppressed during resume_pending");

    let delegation = state.delegations.get("/repo").expect("delegation");
    assert_eq!(delegation.status, DelegationStatus::ResumePending);
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01"),
    );
}

#[test]
fn review_ready_is_accepted_when_resume_pending_for_newer_milestone() {
    let mut state = resume_pending_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_review_ready_command("02"));

    assert!(outcome.ok, "{outcome:?}");

    let delegation = state.delegations.get("/repo").expect("delegation");
    assert_eq!(delegation.status, DelegationStatus::ReviewNeeded);
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("02"),
    );
}

#[test]
fn resume_failed_preserves_review_context_for_retry() {
    let mut state = resume_pending_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_resume_failed_command());

    assert!(outcome.ok, "{outcome:?}");

    let delegation = state.delegations.get("/repo").expect("delegation");
    assert_eq!(delegation.status, DelegationStatus::ResumeFailed);
    assert_eq!(delegation.submitted_milestone_id.as_deref(), Some("01"));
    assert_eq!(
        delegation
            .current_review
            .as_ref()
            .map(|review| review.milestone_id.as_str()),
        Some("01"),
    );
}

#[test]
fn submit_review_without_current_review_fails() {
    // From Working status: hits status guard first
    let mut state = started_delegation_state();

    let outcome = state.apply_delegation_mutation(delegation_submit_review_command(
        DelegationReviewDecision::Approve,
    ));

    assert!(!outcome.ok);
    assert_eq!(
        outcome.message,
        "delegation status must be review_needed or resume_failed"
    );
}

#[test]
fn resume_without_resume_pending_status_fails() {
    let mut state = review_ready_delegation_state("01");

    let outcome = state.apply_delegation_mutation(delegation_resume_command());

    assert!(!outcome.ok);
    assert_eq!(outcome.message, "delegation resume is not pending");
}

#[test]
fn reducer_maps_hook_events_into_session_state() {
    let mut state = ReducerState::default();
    let outcome = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn snapshot_prunes_terminal_runs_older_than_24_hours() {
    let now = Utc::now();
    let stale_timestamp = (now - Duration::hours(25)).to_rfc3339();
    let fresh_timestamp = (now - Duration::hours(2)).to_rfc3339();
    let mut state = ReducerState::default();

    state.runs.insert(
        "/repo#failed-stale".to_string(),
        run_state_fixture(
            "failed-stale",
            RunStatus::Failed,
            stale_timestamp.clone(),
            stale_timestamp.clone(),
        ),
    );
    state.runs.insert(
        "/repo#cancelled-stale".to_string(),
        run_state_fixture(
            "cancelled-stale",
            RunStatus::Cancelled,
            stale_timestamp.clone(),
            stale_timestamp.clone(),
        ),
    );
    state.runs.insert(
        "/repo#completed-stale".to_string(),
        run_state_fixture(
            "completed-stale",
            RunStatus::Completed,
            stale_timestamp.clone(),
            stale_timestamp,
        ),
    );
    state.runs.insert(
        "/repo#failed-fresh".to_string(),
        run_state_fixture(
            "failed-fresh",
            RunStatus::Failed,
            fresh_timestamp.clone(),
            fresh_timestamp,
        ),
    );

    let snapshot = state.snapshot();
    let run_ids: Vec<_> = snapshot.runs.iter().map(|run| run.id.as_str()).collect();

    assert!(!run_ids.contains(&"failed-stale"));
    assert!(!run_ids.contains(&"cancelled-stale"));
    assert!(!run_ids.contains(&"completed-stale"));
    assert!(run_ids.contains(&"failed-fresh"));
}

#[test]
fn snapshot_marks_created_runs_older_than_two_hours_failed() {
    let now = Utc::now();
    let created_at = (now - Duration::hours(3)).to_rfc3339();
    let updated_at = created_at.clone();
    let mut state = ReducerState::default();

    state.runs.insert(
        "/repo#created-stale".to_string(),
        run_state_fixture(
            "created-stale",
            RunStatus::Created,
            created_at,
            updated_at.clone(),
        ),
    );

    let snapshot = state.snapshot();
    let run = snapshot
        .runs
        .into_iter()
        .find(|run| run.id == "created-stale")
        .expect("created run");

    assert_eq!(run.status, RunStatus::Failed);
    assert_ne!(run.updated_at, updated_at);
}

#[test]
fn snapshot_leaves_old_paused_runs_intact() {
    let now = Utc::now();
    let stale_timestamp = (now - Duration::days(7)).to_rfc3339();
    let mut state = ReducerState::default();

    state.runs.insert(
        "/repo#paused-stale".to_string(),
        run_state_fixture(
            "paused-stale",
            RunStatus::Paused,
            stale_timestamp.clone(),
            stale_timestamp,
        ),
    );

    let snapshot = state.snapshot();
    let run = snapshot
        .runs
        .into_iter()
        .find(|run| run.id == "paused-stale")
        .expect("paused run");

    assert_eq!(run.status, RunStatus::Paused);
}

#[test]
fn reducer_ignores_stale_events() {
    let mut state = ReducerState::default();

    let mut current = event_base(HookEventType::UserPromptSubmit);
    current.recorded_at = "2026-01-31T00:00:10Z".to_string();
    let _ = state.apply_hook_event(current);

    let mut stale = event_base(HookEventType::PermissionRequest);
    stale.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(stale);

    assert!(outcome.ok);
    assert_eq!(outcome.message, "stale event skipped");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn reducer_tracks_tools_in_flight_and_idle_prompt_gate() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

    let mut notification = event_base(HookEventType::Notification);
    notification.notification_type = Some("idle_prompt".to_string());
    notification.recorded_at = "2026-01-31T00:00:01Z".to_string();

    let skipped = state.apply_hook_event(notification.clone());
    assert_eq!(
        skipped.message,
        "event skipped: idle_prompt_tools_in_flight"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );

    let mut post_tool = event_base(HookEventType::PostToolUse);
    post_tool.recorded_at = "2026-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(post_tool);

    notification.recorded_at = "2026-01-31T00:00:03Z".to_string();
    let applied = state.apply_hook_event(notification);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
    );
}

#[test]
fn reducer_stop_guard_skips_for_subagent() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.agent_id = Some("agent-1".to_string());
    stop.stop_hook_active = Some(false);
    stop.recorded_at = "2026-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(stop);
    assert_eq!(outcome.message, "event skipped: stop_guard");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn session_end_with_live_pid_transitions_to_ready() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    // Use the current process PID so is_pid_alive returns true
    end.pid = Some(std::process::id());
    end.recorded_at = "2026-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(end);
    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|s| s.state),
        Some(SessionState::Ready),
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|s| s.ready_reason.as_deref()),
        Some("session_cleared"),
    );
}

#[test]
fn session_end_with_dead_pid_deletes_session() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    // PID 1234 from event_base is not alive → should delete
    end.recorded_at = "2026-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(end);
    assert!(outcome.ok);
    assert!(!state.sessions.contains_key("session-1"));
}

#[test]
fn reducer_tracks_shell_signals() {
    let mut state = ReducerState::default();
    let outcome = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("cap".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
    });

    assert!(outcome.ok);
    assert!(state.shells.contains_key(&4242));
    assert_eq!(
        state
            .shells
            .get(&4242)
            .and_then(|shell| shell.tmux_client_tty.as_deref()),
        Some("/dev/ttys099")
    );
    assert_eq!(
        state
            .shells
            .get(&4242)
            .and_then(|shell| shell.tmux_pane.as_deref()),
        Some("%42")
    );
}

#[test]
fn routing_prefers_tmux_pane_targets_for_matching_shells() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("repo".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
    });

    let snapshot = state.snapshot();
    let route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/repo")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.session_name.as_deref(), Some("repo"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
}

#[test]
fn routing_parity_matches_persisted_attached_tmux_pane_from_active_shell_evidence() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("repo".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&state, "/repo");
}

#[test]
fn routing_falls_back_to_tmux_session_when_pane_missing() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("repo".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
    });

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/repo")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxSession);
    assert_eq!(route.target.session_name.as_deref(), Some("repo"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_SESSION_ATTACHED");
}

#[test]
fn routing_marks_projects_unavailable_until_shell_evidence_arrives() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/repo")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Unavailable);
    assert_eq!(route.target.kind, RoutingTargetKind::None);
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.pane_id, None);
    assert_eq!(route.reason_code, "NO_TRUSTED_EVIDENCE");
}

#[test]
fn routing_parity_matches_persisted_unavailable_route_without_trusted_evidence() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    assert_persisted_routing_matches_resolved_routing(&state, "/repo");
}

#[test]
fn routing_does_not_match_parent_directory_shells_to_descendant_projects() {
    let mut state = ReducerState::default();

    let mut attune = event_base(HookEventType::UserPromptSubmit);
    attune.session_id = "session-attune".to_string();
    attune.pid = Some(4100);
    attune.project_path = "/users/petepetrash/code/attune".to_string();
    attune.cwd = Some("/users/petepetrash/code/attune".to_string());
    attune.recorded_at = "2026-03-13T02:35:00Z".to_string();
    let _ = state.apply_hook_event(attune);

    let mut pete = event_base(HookEventType::UserPromptSubmit);
    pete.session_id = "session-pete".to_string();
    pete.pid = Some(4200);
    pete.project_path = "/users/petepetrash/code/pete-2025".to_string();
    pete.cwd = Some("/users/petepetrash/code/pete-2025".to_string());
    pete.recorded_at = "2026-03-13T02:35:01Z".to_string();
    let _ = state.apply_hook_event(pete);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 9999,
        cwd: "/users/petepetrash/code".to_string(),
        tty: "/dev/ttys009".to_string(),
        parent_app: "tmux".to_string(),
        tmux_session: Some("sanctuary".to_string()),
        tmux_client_tty: Some("/dev/ttys026".to_string()),
        tmux_pane: Some("%27".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-13T02:35:59Z".to_string(),
    });
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4200,
        cwd: "/users/petepetrash/code/pete-2025".to_string(),
        tty: "/dev/ttys005".to_string(),
        parent_app: "tmux".to_string(),
        tmux_session: Some("dev".to_string()),
        tmux_client_tty: Some("/dev/ttys009".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-13T02:40:41Z".to_string(),
    });

    let snapshot = state.snapshot();

    let attune_route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/users/petepetrash/code/attune")
        .expect("attune route");
    assert_eq!(attune_route.status, RoutingStatus::Unavailable);
    assert_eq!(attune_route.target.kind, RoutingTargetKind::None);
    assert_eq!(attune_route.reason_code, "NO_TRUSTED_EVIDENCE");

    let pete_route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/users/petepetrash/code/pete-2025")
        .expect("pete route");
    assert_eq!(pete_route.status, RoutingStatus::Attached);
    assert_eq!(pete_route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(pete_route.target.pane_id.as_deref(), Some("%0"));
    assert_eq!(pete_route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(pete_route.target.host_tty.as_deref(), Some("/dev/ttys009"));
}

#[test]
fn routing_still_matches_shells_inside_project_subdirectories() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = "/users/petepetrash/code/capacitor".to_string();
    event.cwd = Some("/users/petepetrash/code/capacitor".to_string());
    event.recorded_at = "2026-03-13T02:45:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/users/petepetrash/code/capacitor/apps/swift".to_string(),
        tty: "/dev/ttys021".to_string(),
        parent_app: "tmux".to_string(),
        tmux_session: Some("capacitor".to_string()),
        tmux_client_tty: Some("/dev/ttys022".to_string()),
        tmux_pane: Some("%21".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-13T02:45:30Z".to_string(),
    });

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/users/petepetrash/code/capacitor")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.pane_id.as_deref(), Some("%21"));
    assert_eq!(route.target.session_name.as_deref(), Some("capacitor"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys022"));
}

#[test]
fn routing_infers_attached_tmux_terminal_app_from_host_tty_shell_evidence() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.pid = Some(4242);
    event.project_path = "/tmp/core-project".to_string();
    event.cwd = Some("/tmp/core-project".to_string());
    event.recorded_at = "2026-03-14T20:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 5000,
        cwd: "/tmp".to_string(),
        tty: "/dev/ttys099".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("shared".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%1".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-14T20:00:01Z".to_string(),
    });
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/tmp/core-project".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "tmux".to_string(),
        tmux_session: Some("core".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-14T20:00:02Z".to_string(),
    });

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/tmp/core-project")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("core"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
}

#[test]
fn routing_parity_matches_persisted_attached_tmux_terminal_app_inferred_from_host_tty() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.pid = Some(4242);
    event.project_path = "/tmp/core-project".to_string();
    event.cwd = Some("/tmp/core-project".to_string());
    event.recorded_at = "2026-03-14T20:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 5000,
        cwd: "/tmp".to_string(),
        tty: "/dev/ttys099".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("shared".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%1".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-14T20:00:01Z".to_string(),
    });
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/tmp/core-project".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "tmux".to_string(),
        tmux_session: Some("core".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-03-14T20:00:02Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&state, "/tmp/core-project");
}

#[test]
fn routing_derives_non_active_tmux_pane_from_inventory() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.pid = Some(4242);
    event.project_path = "/users/petepetrash/code/aui/mcp-app-studio-starter".to_string();
    event.cwd = Some("/users/petepetrash/code/aui/mcp-app-studio-starter".to_string());
    event.recorded_at = "2026-03-15T03:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/users/petepetrash/code/pete-2025".to_string(),
        tty: "/dev/ttys005".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("dev".to_string()),
        tmux_client_tty: Some("/dev/ttys009".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%0".to_string(),
                pane_path: "/users/petepetrash/code/pete-2025".to_string(),
                session_attached: true,
            },
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%1".to_string(),
                pane_path: "/users/petepetrash/code/aui/mcp-app-studio-starter".to_string(),
                session_attached: true,
            },
        ],
        recorded_at: "2026-03-15T03:00:01Z".to_string(),
    });

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/users/petepetrash/code/aui/mcp-app-studio-starter")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%1"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys009"));
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
}

#[test]
fn routing_parity_matches_persisted_non_active_tmux_pane_from_inventory() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.pid = Some(4242);
    event.project_path = "/users/petepetrash/code/aui/mcp-app-studio-starter".to_string();
    event.cwd = Some("/users/petepetrash/code/aui/mcp-app-studio-starter".to_string());
    event.recorded_at = "2026-03-15T03:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/users/petepetrash/code/pete-2025".to_string(),
        tty: "/dev/ttys005".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("dev".to_string()),
        tmux_client_tty: Some("/dev/ttys009".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%0".to_string(),
                pane_path: "/users/petepetrash/code/pete-2025".to_string(),
                session_attached: true,
            },
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%1".to_string(),
                pane_path: "/users/petepetrash/code/aui/mcp-app-studio-starter".to_string(),
                session_attached: true,
            },
        ],
        recorded_at: "2026-03-15T03:00:01Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(
        &state,
        "/users/petepetrash/code/aui/mcp-app-studio-starter",
    );
}

#[test]
fn routing_inventory_preference_matching_shell_beats_inventory() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("repo".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            session_name: "repo".to_string(),
            pane_id: "%99".to_string(),
            pane_path: "/repo".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-16T00:00:00Z".to_string(),
    });

    let route = persisted_route_for(&state, "/repo");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("repo"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%42'");
    assert_eq!(route.updated_at, "2026-03-16T00:00:00Z");
}

#[test]
fn routing_managed_worktree_shell_does_not_override_project_root_shell() {
    let main_shell = ShellSignal {
        tmux_session: Some("main".to_string()),
        tmux_client_tty: Some("/dev/ttys110".to_string()),
        tmux_pane: Some("%10".to_string()),
        updated_at: "2026-03-27T00:00:01Z".to_string(),
        ..shell_signal_fixture(10, "/repo")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys210".to_string()),
        tmux_pane: Some("%20".to_string()),
        updated_at: "2026-03-27T00:00:02Z".to_string(),
        ..shell_signal_fixture(20, "/repo/.capacitor/worktrees/delegation-20")
    };

    let state = routing_state_fixture(
        vec![
            session_summary_fixture(
                "session-main",
                10,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2026-03-27T00:00:01Z",
            ),
            session_summary_fixture(
                "session-worker",
                20,
                "/repo",
                "/repo/.capacitor/worktrees/delegation-20",
                SessionState::Working,
                "2026-03-27T00:00:02Z",
            ),
        ],
        vec![main_shell, delegation_shell],
    );

    let route = persisted_route_for(&state, "/repo");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.session_name.as_deref(), Some("main"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%10"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys110"));
}

#[test]
fn routing_managed_worktree_only_shell_produces_unavailable_route() {
    let delegation_shell = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys220".to_string()),
        tmux_pane: Some("%22".to_string()),
        updated_at: "2026-03-27T00:00:03Z".to_string(),
        ..shell_signal_fixture(22, "/repo/.capacitor/worktrees/delegation-22")
    };

    let state = routing_state_fixture(
        vec![session_summary_fixture(
            "session-worker",
            22,
            "/repo",
            "/repo/.capacitor/worktrees/delegation-22",
            SessionState::Working,
            "2026-03-27T00:00:03Z",
        )],
        vec![delegation_shell],
    );

    let route = persisted_route_for(&state, "/repo");

    assert_eq!(route.status, RoutingStatus::Unavailable);
    assert_eq!(route.target.kind, RoutingTargetKind::None);
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.pane_id, None);
    assert_eq!(route.target.host_tty, None);
    assert_eq!(route.reason_code, "NO_TRUSTED_EVIDENCE");
}

#[test]
fn routing_managed_worktree_only_inventory_pane_produces_unavailable_route() {
    let inventory_carrier = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys220".to_string()),
        tmux_pane: Some("%22".to_string()),
        tmux_panes: vec![tmux_pane_fixture(
            "%22",
            "/repo/.capacitor/worktrees/delegation-22",
        )],
        updated_at: "2026-03-27T00:00:03Z".to_string(),
        ..shell_signal_fixture(22, "/other")
    };

    let state = routing_state_fixture(
        vec![session_summary_fixture(
            "session-main",
            10,
            "/repo",
            "/repo",
            SessionState::Idle,
            "2026-03-27T00:00:03Z",
        )],
        vec![inventory_carrier],
    );

    let route = persisted_route_for(&state, "/repo");

    assert_eq!(route.status, RoutingStatus::Unavailable);
    assert_eq!(route.target.kind, RoutingTargetKind::None);
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.pane_id, None);
    assert_eq!(route.target.host_tty, None);
    assert_eq!(route.reason_code, "NO_TRUSTED_EVIDENCE");
}

#[test]
fn test_delegation_worktree_state_priority_doesnt_override() {
    let main_shell = ShellSignal {
        tmux_session: Some("main".to_string()),
        tmux_client_tty: Some("/dev/ttys130".to_string()),
        tmux_pane: Some("%30".to_string()),
        updated_at: "2026-03-27T00:00:04Z".to_string(),
        ..shell_signal_fixture(30, "/repo")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys230".to_string()),
        tmux_pane: Some("%40".to_string()),
        updated_at: "2026-03-27T00:00:05Z".to_string(),
        ..shell_signal_fixture(40, "/repo/.capacitor/worktrees/delegation-40")
    };

    let state = routing_state_fixture(
        vec![
            session_summary_fixture(
                "session-main",
                30,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2026-03-27T00:00:04Z",
            ),
            session_summary_fixture(
                "session-worker",
                40,
                "/repo",
                "/repo/.capacitor/worktrees/delegation-40",
                SessionState::Working,
                "2026-03-27T00:00:05Z",
            ),
        ],
        vec![main_shell, delegation_shell],
    );

    let project = state
        .snapshot()
        .projects
        .into_iter()
        .find(|project| project.project_path == "/repo")
        .expect("project");
    assert_eq!(project.state, SessionState::Working);

    let route = persisted_route_for(&state, "/repo");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.session_name.as_deref(), Some("main"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%30"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys130"));
}

#[test]
fn routing_inventory_preference_matrix_selects_canonical_source() {
    enum ExpectedCanonicalSource<'a> {
        Shell(u32),
        Inventory(&'a str),
        None,
    }

    let matching_shell = shell_signal_fixture(10, "/repo");
    let mismatched_shell = shell_signal_fixture(20, "/other");
    let inventory_carrier = shell_signal_fixture(90, "/inventory-carrier");
    let inventory_pane = tmux_pane_fixture("%9", "/repo");
    let inventory_candidate = TmuxInventoryCandidate {
        carrier: &inventory_carrier,
        pane: &inventory_pane,
        rank: 2,
    };

    let cases = [
        (
            "no shell + inventory -> inventory",
            None,
            Some(inventory_candidate),
            ExpectedCanonicalSource::Inventory("%9"),
        ),
        (
            "matching shell + inventory -> shell",
            Some(&matching_shell),
            Some(inventory_candidate),
            ExpectedCanonicalSource::Shell(10),
        ),
        (
            "mismatched shell + inventory -> inventory",
            Some(&mismatched_shell),
            Some(inventory_candidate),
            ExpectedCanonicalSource::Inventory("%9"),
        ),
        (
            "matching shell without inventory -> shell",
            Some(&matching_shell),
            None,
            ExpectedCanonicalSource::Shell(10),
        ),
        (
            "no evidence -> none",
            None,
            None,
            ExpectedCanonicalSource::None,
        ),
    ];

    for (name, shell, inventory_candidate, expected) in cases {
        let source = select_canonical_routing_source("/repo", shell, inventory_candidate);

        match (source, expected) {
            (
                CanonicalRoutingSource::Shell(shell),
                ExpectedCanonicalSource::Shell(expected_pid),
            ) => {
                assert_eq!(shell.pid, expected_pid, "{name}");
            }
            (
                CanonicalRoutingSource::Inventory(candidate),
                ExpectedCanonicalSource::Inventory(expected_pane_id),
            ) => {
                assert_eq!(candidate.pane.pane_id, expected_pane_id, "{name}");
            }
            (CanonicalRoutingSource::None, ExpectedCanonicalSource::None) => {}
            (actual, _) => panic!("{name}: unexpected canonical source {actual:?}"),
        }
    }
}

#[test]
fn routing_inventory_preference_persisted_mismatched_shell_prefers_inventory() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = "/target".to_string();
    event.cwd = Some("/target".to_string());
    let _ = state.apply_hook_event(event);

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/other".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("dev".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%0".to_string(),
                pane_path: "/other".to_string(),
                session_attached: true,
            },
            TmuxPaneInfo {
                session_name: "dev".to_string(),
                pane_id: "%1".to_string(),
                pane_path: "/target".to_string(),
                session_attached: true,
            },
        ],
        recorded_at: "2026-03-16T00:00:01Z".to_string(),
    });

    let route = persisted_route_for(&state, "/target");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%1"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%1' from pane inventory");
    assert_eq!(route.updated_at, "2026-03-16T00:00:01Z");
}

#[test]
fn routing_inventory_preference_hinted_mismatched_shell_prefers_inventory() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 200,
        cwd: "/other".to_string(),
        tty: "/dev/ttys030".to_string(),
        parent_app: "terminal".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys040".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![
            TmuxPaneInfo {
                session_name: "caps".to_string(),
                pane_id: "%0".to_string(),
                pane_path: "/other".to_string(),
                session_attached: true,
            },
            TmuxPaneInfo {
                session_name: "caps".to_string(),
                pane_id: "%5".to_string(),
                pane_path: "/target".to_string(),
                session_attached: true,
            },
        ],
        recorded_at: "2026-03-16T00:00:02Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/target".to_string(),
        workspace_id: None,
        session_name: Some("caps".to_string()),
        client_tty: Some("/dev/ttys040".to_string()),
    });

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("terminal"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%5"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys040"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%5' from pane inventory");
    assert_eq!(route.updated_at, "2026-03-16T00:00:02Z");
}

#[test]
fn routing_inventory_preference_matching_shell_stays_canonical_for_activation() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 300,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys031".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys041".to_string()),
        tmux_pane: Some("%0".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            session_name: "caps".to_string(),
            pane_id: "%9".to_string(),
            pane_path: "/repo".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-16T00:00:03Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/repo".to_string(),
        workspace_id: None,
        session_name: Some("caps".to_string()),
        client_tty: Some("/dev/ttys041".to_string()),
    });

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%0"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys041"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%0'");
    assert_eq!(route.updated_at, "2026-03-16T00:00:03Z");
}

#[test]
fn routing_parity_matches_persisted_detached_terminal_app_route() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "terminal".to_string(),
        tmux_session: None,
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T06:00:00Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&state, "/repo");
}

#[test]
fn routing_query_prefers_client_tty_match_for_untracked_project() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 100,
        cwd: "/Users/pete/Code/capacitor".to_string(),
        tty: "/dev/ttys010".to_string(),
        parent_app: "Ghostty".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys001".to_string()),
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T05:40:00Z".to_string(),
    });

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 101,
        cwd: "/Users/pete/Code/capacitor".to_string(),
        tty: "/dev/ttys020".to_string(),
        parent_app: "iTerm2".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: Some("/dev/ttys002".to_string()),
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T05:40:01Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/Users/pete/Code/capacitor".to_string(),
        workspace_id: None,
        session_name: Some("caps".to_string()),
        client_tty: Some("/dev/ttys002".to_string()),
    });

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxSession);
    assert_eq!(route.target.terminal_app.as_deref(), Some("iterm2"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys002"));
}

#[test]
fn routing_query_falls_back_to_session_match_for_untracked_project() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 200,
        cwd: "/Users/pete/Code/capacitor".to_string(),
        tty: "/dev/ttys030".to_string(),
        parent_app: "Terminal".to_string(),
        tmux_session: Some("caps".to_string()),
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T05:41:00Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/Users/pete/Code/capacitor".to_string(),
        workspace_id: None,
        session_name: Some("caps".to_string()),
        client_tty: None,
    });

    assert_eq!(route.status, RoutingStatus::Detached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxSession);
    assert_eq!(route.target.terminal_app.as_deref(), Some("terminal"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.host_tty, None);
}

#[test]
fn routing_query_prefers_exact_project_path_when_client_tty_unknown() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 300,
        cwd: "/Users/pete/Code/capacitor".to_string(),
        tty: "/dev/ttys031".to_string(),
        parent_app: "Ghostty".to_string(),
        tmux_session: None,
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T05:42:00Z".to_string(),
    });

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 301,
        cwd: "/Users/pete".to_string(),
        tty: "/dev/ttys029".to_string(),
        parent_app: "Terminal".to_string(),
        tmux_session: Some("capacitor".to_string()),
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-03-15T05:41:00Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/Users/pete/Code/capacitor".to_string(),
        workspace_id: None,
        session_name: Some("capacitor".to_string()),
        client_tty: None,
    });

    assert_eq!(route.status, RoutingStatus::Detached);
    assert_eq!(route.target.kind, RoutingTargetKind::TerminalApp);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.host_tty, None);
}

#[test]
fn routing_ignores_stale_shell_signal_for_same_pid() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/repo".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("repo".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:10Z".to_string(),
    });

    let outcome = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1234,
        cwd: "/somewhere-else".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "terminal".to_string(),
        tmux_session: None,
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
    });

    assert!(outcome.ok);
    assert_eq!(outcome.message, "stale shell signal skipped");
    assert_eq!(state.stale_events_skipped, 1);

    let route = state
        .snapshot()
        .routing
        .into_iter()
        .find(|route| route.project_path == "/repo")
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("repo"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));

    let shell = state.shells.get(&1234).expect("shell");
    assert_eq!(shell.cwd, "/repo");
    assert_eq!(shell.updated_at, "2026-02-28T00:00:10Z");
}

#[test]
fn default_workspace_is_stable() {
    let a = default_workspace_id("/Users/Pete/Code/Repo");
    let b = default_workspace_id("/users/pete/code/repo");
    assert_eq!(a, b);
}

#[test]
fn projects_are_reduced_by_priority_and_recency() {
    let mut state = ReducerState::default();

    let mut first = event_base(HookEventType::PermissionRequest);
    first.session_id = "session-1".to_string();
    first.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(first);

    let mut second = event_base(HookEventType::UserPromptSubmit);
    second.session_id = "session-2".to_string();
    second.recorded_at = "2026-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(second);

    let snapshot = state.snapshot();
    let project = snapshot
        .projects
        .iter()
        .find(|project| project.project_path == "/repo")
        .expect("project");

    assert_eq!(project.state, SessionState::Waiting);
    assert_eq!(project.session_count, 2);
    assert_eq!(project.active_count, 2);
    assert!(project.has_session);
}

#[test]
fn diagnostics_tracks_skip_counters() {
    let mut state = ReducerState::default();

    // Establish a session so we can trigger skip paths
    let start = event_base(HookEventType::UserPromptSubmit);
    let _ = state.apply_hook_event(start);

    // 1) Stale event → stale_events_skipped
    let mut stale = event_base(HookEventType::PermissionRequest);
    stale.recorded_at = "2025-12-01T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(stale);
    assert_eq!(outcome.message, "stale event skipped");

    // 2) Informational event → informational_events_skipped
    let mut config_change = event_base(HookEventType::ConfigChange);
    config_change.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let outcome = state.apply_hook_event(config_change);
    assert!(outcome.message.contains("informational_event"));

    // 3) Another informational event to prove counting
    let mut worktree = event_base(HookEventType::WorktreeCreate);
    worktree.recorded_at = "2026-01-31T00:00:02Z".to_string();
    let outcome = state.apply_hook_event(worktree);
    assert!(outcome.message.contains("informational_event"));

    // 4) Idle prompt while tools in flight → idle_prompt_skipped
    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2026-01-31T00:00:03Z".to_string();
    let _ = state.apply_hook_event(pre_tool);

    let mut idle = event_base(HookEventType::Notification);
    idle.notification_type = Some("idle_prompt".to_string());
    idle.recorded_at = "2026-01-31T00:00:04Z".to_string();
    let outcome = state.apply_hook_event(idle);
    assert!(outcome.message.contains("idle_prompt_tools_in_flight"));

    // Verify skip counters in snapshot
    let diag = state.snapshot().diagnostics;
    assert!(
        diag.events_skipped > 0,
        "events_skipped should be non-zero, got {}",
        diag.events_skipped
    );
    assert!(
        diag.stale_events_skipped > 0,
        "stale_events_skipped should be non-zero"
    );
    assert!(
        diag.informational_events_skipped >= 2,
        "informational_events_skipped should be >= 2, got {}",
        diag.informational_events_skipped
    );
    assert_eq!(
        diag.events_skipped,
        diag.stale_events_skipped + diag.informational_events_skipped + diag.reducer_events_skipped,
        "events_skipped should equal sum of sub-counters"
    );
}

#[test]
fn routing_deprioritizes_managed_worktree_shell_over_project_root_shell() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = "/users/pete/code/capacitor".to_string();
    event.cwd = Some("/users/pete/code/capacitor".to_string());
    event.recorded_at = "2026-03-25T10:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    // Main shell at project root
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 1000,
        cwd: "/users/pete/code/capacitor".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("capacitor".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%1".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            pane_id: "%1".to_string(),
            pane_path: "/users/pete/code/capacitor".to_string(),
            session_name: "capacitor".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-25T10:00:00Z".to_string(),
    });

    // Delegation shell in managed worktree (more recent)
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 2000,
        cwd: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345".to_string(),
        tty: "/dev/ttys002".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("delegation-abc12345".to_string()),
        tmux_client_tty: Some("/dev/ttys098".to_string()),
        tmux_pane: Some("%2".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            pane_id: "%2".to_string(),
            pane_path: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345"
                .to_string(),
            session_name: "delegation-abc12345".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-25T12:00:00Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/users/pete/code/capacitor".to_string(),
        workspace_id: None,
        session_name: None,
        client_tty: None,
    });

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(
        route.target.session_name.as_deref(),
        Some("capacitor"),
        "Should route to main session, not delegation worktree session"
    );
}

#[test]
fn routing_resolved_route_is_unavailable_when_only_managed_worktree_candidate_exists() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = "/users/pete/code/capacitor".to_string();
    event.cwd =
        Some("/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345".to_string());
    event.recorded_at = "2026-03-25T10:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    // Only a delegation worktree shell exists
    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 2000,
        cwd: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345".to_string(),
        tty: "/dev/ttys002".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("delegation-abc12345".to_string()),
        tmux_client_tty: Some("/dev/ttys098".to_string()),
        tmux_pane: Some("%2".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            pane_id: "%2".to_string(),
            pane_path: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345"
                .to_string(),
            session_name: "delegation-abc12345".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-25T12:00:00Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/users/pete/code/capacitor".to_string(),
        workspace_id: None,
        session_name: None,
        client_tty: None,
    });

    assert_eq!(route.status, RoutingStatus::Unavailable);
    assert_eq!(route.target.kind, RoutingTargetKind::None);
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.pane_id, None);
    assert_eq!(route.target.host_tty, None);
    assert_eq!(route.reason_code, "NO_TRUSTED_EVIDENCE");
}

#[test]
fn routing_activation_query_ignores_managed_worktree_only_shell() {
    let mut state = ReducerState::default();

    let _ = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 2000,
        cwd: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345".to_string(),
        tty: "/dev/ttys002".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: Some("delegation-abc12345".to_string()),
        tmux_client_tty: Some("/dev/ttys098".to_string()),
        tmux_pane: Some("%2".to_string()),
        tmux_panes: vec![TmuxPaneInfo {
            pane_id: "%2".to_string(),
            pane_path: "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345"
                .to_string(),
            session_name: "delegation-abc12345".to_string(),
            session_attached: true,
        }],
        recorded_at: "2026-03-25T12:00:00Z".to_string(),
    });

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/users/pete/code/capacitor".to_string(),
        workspace_id: None,
        session_name: Some("delegation-abc12345".to_string()),
        client_tty: Some("/dev/ttys098".to_string()),
    });

    assert_eq!(route.status, RoutingStatus::Unavailable);
    assert_eq!(route.target.kind, RoutingTargetKind::None);
    assert_eq!(route.target.session_name, None);
    assert_eq!(route.target.pane_id, None);
    assert_eq!(route.target.host_tty, None);
    assert_eq!(route.reason_code, "NO_TRUSTED_EVIDENCE");
}

#[test]
fn routing_deprioritizes_working_worktree_over_idle_main_session() {
    let main_shell = ShellSignal {
        tmux_session: Some("capacitor".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%1".to_string()),
        updated_at: "2026-03-25T10:00:00Z".to_string(),
        ..shell_signal_fixture(1000, "/users/pete/code/capacitor")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("delegation-abc12345".to_string()),
        tmux_client_tty: Some("/dev/ttys098".to_string()),
        tmux_pane: Some("%2".to_string()),
        updated_at: "2026-03-25T12:00:00Z".to_string(),
        ..shell_signal_fixture(
            2000,
            "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345",
        )
    };

    let state = routing_state_fixture(
        vec![
            session_summary_fixture(
                "session-main",
                1000,
                "/users/pete/code/capacitor",
                "/users/pete/code/capacitor",
                SessionState::Idle,
                "2026-03-25T10:00:00Z",
            ),
            session_summary_fixture(
                "session-delegation",
                2000,
                "/users/pete/code/capacitor",
                "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345",
                SessionState::Working,
                "2026-03-25T12:00:00Z",
            ),
        ],
        vec![main_shell, delegation_shell],
    );

    let route = state.resolve_routing(ResolveRoutingCommand {
        project_path: "/users/pete/code/capacitor".to_string(),
        workspace_id: None,
        session_name: None,
        client_tty: None,
    });

    assert_eq!(
        route.target.session_name.as_deref(),
        Some("capacitor"),
        "Main session should win routing even when delegation session has higher state priority"
    );
}
