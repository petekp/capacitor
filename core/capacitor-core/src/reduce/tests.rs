use chrono::{Duration, Utc};

use super::{
    select_canonical_routing_source, CanonicalRoutingSource, ReducerState, TmuxInventoryCandidate,
};
use crate::domain::{
    default_workspace_id, AppSnapshot, DelegationMutationKind, DelegationReviewDecision,
    DelegationStatus, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
    IngestShellSignalCommand, InvolvementLevel, MutateDelegationCommand, PhaseInstance,
    PhaseStatus, ResolveRoutingCommand, RoutingStatus, RoutingTargetKind, RoutingView, RunState,
    RunStatus, SessionState, SessionSummary, ShellSignal, SignalAuthority, TmuxPaneInfo,
};
fn event_base(event_type: HookEventType) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2099-01-31T00:00:00Z".to_string(),
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
    state: &mut ReducerState,
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

fn persisted_route_for(state: &mut ReducerState, project_path: &str) -> RoutingView {
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
        updated_at: format!("2099-03-16T00:00:{:02}Z", pid % 60),
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
        terminated_at: None,
        tools_in_flight: 0,
        state_source: None,
        last_authoritative_event_at: None,
        is_alive: false,
        gc_reason: None,
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
        generated_at: "2099-03-27T00:00:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
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
fn snapshot_uses_correct_version_constants() {
    let state = ReducerState::default();

    let snapshot = state.snapshot();

    assert_eq!(
        snapshot.snapshot_version,
        crate::storage::CURRENT_SNAPSHOT_SCHEMA_VERSION as u64
    );
    assert_eq!(snapshot.schema_version, crate::domain::SCHEMA_VERSION);
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
    current.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let _ = state.apply_hook_event(current);

    let mut stale = event_base(HookEventType::PermissionRequest);
    stale.recorded_at = "2099-01-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(stale);

    assert!(outcome.ok);
    assert_eq!(outcome.message, "stale event skipped");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn test_idle_prompt_corrects_drift_without_hiding_live_work() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

    let mut notification = event_base(HookEventType::Notification);
    notification.notification_type = Some("idle_prompt".to_string());
    notification.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let applied = state.apply_hook_event(notification);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(0)
    );
    // ADR-005 Phase 3 step 9: the drift-correcting Notification refreshes
    // tools_in_flight and preserves Working state, but state_source remains
    // pinned to the higher-authority PreToolUse — a lower-authority
    // meta-notification does not regress the authority record within the
    // freshness window.
    assert_eq!(
        state.sessions.get("session-1").and_then(|session| session
            .state_source
            .as_ref()
            .map(|source| source.event_kind)),
        Some(HookEventType::PreToolUse)
    );
}

#[test]
fn idle_prompt_skips_when_session_recently_active() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut notification = event_base(HookEventType::Notification);
    notification.notification_type = Some("idle_prompt".to_string());
    notification.recorded_at = "2099-01-31T00:00:02Z".to_string();

    let applied = state.apply_hook_event(notification);
    assert_eq!(
        applied.message,
        "event skipped: idle_prompt_recent_activity"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working),
        "idle_prompt should skip when session is recently active"
    );
}

#[test]
fn idle_prompt_transitions_to_ready_when_stale() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut notification = event_base(HookEventType::Notification);
    notification.notification_type = Some("idle_prompt".to_string());
    notification.recorded_at = "2099-01-31T00:00:15Z".to_string();

    let applied = state.apply_hook_event(notification);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready),
        "idle_prompt should transition when session is stale"
    );
}

#[test]
fn test_idle_prompt_transitions_to_ready_after_drift_correction() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

    let mut first_idle = event_base(HookEventType::Notification);
    first_idle.notification_type = Some("idle_prompt".to_string());
    first_idle.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let applied = state.apply_hook_event(first_idle);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(0)
    );

    let mut second_idle = event_base(HookEventType::Notification);
    second_idle.notification_type = Some("idle_prompt".to_string());
    second_idle.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let applied = state.apply_hook_event(second_idle);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
    );
    assert_eq!(
        state.sessions.get("session-1").and_then(|session| session
            .state_source
            .as_ref()
            .map(|source| source.event_kind)),
        Some(HookEventType::Notification)
    );
}

#[test]
fn test_out_of_order_idle_prompt_does_not_hide_live_tool_work_within_stale_grace() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));

    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let _ = state.apply_hook_event(pre_tool);

    let mut delayed_idle = event_base(HookEventType::Notification);
    delayed_idle.notification_type = Some("idle_prompt".to_string());
    delayed_idle.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let applied = state.apply_hook_event(delayed_idle);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(0)
    );
}

#[test]
fn test_subagent_start_sets_working() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));

    let mut start = event_base(HookEventType::SubagentStart);
    start.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(start);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn subagent_stop_refreshes_when_recently_active() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.event_id = "evt-2".to_string();
    stop.agent_id = Some("agent-1".to_string());
    stop.recorded_at = "2099-01-31T00:00:02Z".to_string();

    let outcome = state.apply_hook_event(stop);

    assert!(outcome.ok, "{outcome:?}");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.updated_at.as_str()),
        Some("2099-01-31T00:00:02Z"),
        "updated_at should be refreshed when recently active"
    );
}

#[test]
fn subagent_stop_skips_when_stale() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.event_id = "evt-2".to_string();
    stop.agent_id = Some("agent-1".to_string());
    stop.recorded_at = "2099-01-31T00:00:15Z".to_string();

    let outcome = state.apply_hook_event(stop);

    assert_eq!(
        outcome.message,
        "event skipped: subagent_stop_working_no_tools_stale"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.updated_at.as_str()),
        Some("2099-01-31T00:00:00Z"),
        "updated_at should not be refreshed when stale"
    );
}

#[test]
fn subagent_stop_preserves_working_with_parallel_agents() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

    let mut second_pre = event_base(HookEventType::PreToolUse);
    second_pre.event_id = "evt-2".to_string();
    second_pre.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(second_pre);

    let mut first_post = event_base(HookEventType::PostToolUse);
    first_post.event_id = "evt-3".to_string();
    first_post.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(first_post);

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.event_id = "evt-4".to_string();
    stop.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let outcome = state.apply_hook_event(stop);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(1)
    );

    let mut second_post = event_base(HookEventType::PostToolUse);
    second_post.event_id = "evt-5".to_string();
    second_post.recorded_at = "2099-01-31T00:00:04Z".to_string();
    let _ = state.apply_hook_event(second_post);

    // Capture timestamp before the last agent stops.
    let updated_at_before = state
        .sessions
        .get("session-1")
        .map(|s| s.updated_at.clone())
        .unwrap();

    let mut final_stop = event_base(HookEventType::SubagentStop);
    final_stop.event_id = "evt-6".to_string();
    final_stop.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(final_stop);

    assert_eq!(outcome.message, "event ingested");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(0)
    );
    let updated_at_after = state
        .sessions
        .get("session-1")
        .map(|s| s.updated_at.clone())
        .unwrap();
    assert_ne!(updated_at_before, updated_at_after);
    assert_eq!(updated_at_after, "2099-01-31T00:00:05Z");
}

#[test]
fn subagent_stop_skips_when_session_is_idle() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.event_id = "evt-2".to_string();
    stop.recorded_at = "2099-01-31T00:00:01Z".to_string();
    stop.stop_hook_active = Some(false);
    let _ = state.apply_hook_event(stop);

    let mut subagent_stop = event_base(HookEventType::SubagentStop);
    subagent_stop.event_id = "evt-3".to_string();
    subagent_stop.recorded_at = "2099-01-31T00:00:02Z".to_string();

    let outcome = state.apply_hook_event(subagent_stop);

    assert_eq!(
        outcome.message,
        "event skipped: subagent_stop_session_not_working"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
    );
}

#[test]
fn subagent_stop_skips_when_session_is_idle_or_absent() {
    let mut state = ReducerState::default();

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(stop);

    assert_eq!(
        outcome.message,
        "event skipped: subagent_stop_session_not_working"
    );
    assert!(!state.sessions.contains_key("session-1"));
}

#[test]
fn test_subagent_start_preserves_waiting() {
    let mut state = ReducerState::default();

    // PreToolUse first so tools_in_flight > 0, then PermissionRequest sets Waiting
    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));
    let mut perm = event_base(HookEventType::PermissionRequest);
    perm.recorded_at = "2099-01-31T00:00:00.5Z".to_string();
    let _ = state.apply_hook_event(perm);

    let mut start = event_base(HookEventType::SubagentStart);
    start.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(start);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Waiting)
    );
}

#[test]
fn test_subagent_start_preserves_compacting() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreCompact));

    let mut start = event_base(HookEventType::SubagentStart);
    start.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(start);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Compacting)
    );
}

#[test]
fn test_subagent_stop_preserves_compacting() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreCompact));

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(stop);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Compacting)
    );
}

#[test]
fn test_subagent_stop_preserves_waiting() {
    let mut state = ReducerState::default();

    // PreToolUse first so tools_in_flight > 0, then PermissionRequest sets Waiting
    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));
    let mut perm = event_base(HookEventType::PermissionRequest);
    perm.recorded_at = "2099-01-31T00:00:00.5Z".to_string();
    let _ = state.apply_hook_event(perm);

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(stop);

    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Waiting)
    );
}

#[test]
fn test_subagent_start_does_not_update_activity() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));

    let mut start = event_base(HookEventType::SubagentStart);
    start.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(start);

    assert!(outcome.ok);
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|session| session.last_activity_at.as_deref()),
        None
    );
}

#[test]
fn reducer_stop_guard_skips_for_subagent() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.agent_id = Some("agent-1".to_string());
    stop.stop_hook_active = Some(false);
    stop.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(stop);
    assert_eq!(outcome.message, "event skipped: stop_guard");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn reducer_parent_stop_transitions_to_idle() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(false);
    stop.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(stop);
    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
    );
    assert_eq!(
        state.sessions.get("session-1").and_then(|session| session
            .state_source
            .as_ref()
            .map(|source| source.event_kind)),
        Some(HookEventType::Stop)
    );
}

#[test]
fn reducer_stop_guard_skips_when_stop_hook_active() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(true);
    stop.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(stop);
    assert_eq!(outcome.message, "event skipped: stop_guard");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
}

#[test]
fn should_skip_stop_is_false_for_parent_session_stop() {
    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(false);

    assert!(!super::should_skip_stop(&stop));
}

#[test]
fn should_skip_stop_is_true_for_stop_hook_active() {
    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(true);

    assert!(super::should_skip_stop(&stop));
}

#[test]
fn should_skip_stop_is_true_for_subagent_stop() {
    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(false);
    stop.agent_id = Some("agent-1".to_string());

    assert!(super::should_skip_stop(&stop));
}

#[test]
fn session_end_produces_idle_regardless_of_pid() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    end.pid = Some(std::process::id());
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(end);
    assert!(outcome.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|s| s.state),
        Some(SessionState::Idle),
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|s| s.state_source.as_ref().map(|source| source.event_kind)),
        Some(HookEventType::SessionEnd),
    );
}

#[test]
fn session_end_with_dead_pid_produces_idle() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    // PID 1234 from event_base is not alive — still produces Idle (no delete)
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(end);
    assert!(outcome.ok);
    assert!(
        state.sessions.contains_key("session-1"),
        "SessionEnd should produce Idle, not delete"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|s| s.state),
        Some(SessionState::Idle),
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|s| s.state_source.as_ref().map(|source| source.event_kind)),
        Some(HookEventType::SessionEnd),
    );
}

#[test]
fn session_end_without_existing_session_is_skipped() {
    let mut state = ReducerState::default();

    let outcome = state.apply_hook_event(event_base(HookEventType::SessionEnd));
    assert!(outcome.ok);
    assert_eq!(state.sessions.len(), 0);
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
        recorded_at: "2099-02-28T00:00:00Z".to_string(),
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
fn test_skip_reasons_for_informational_and_sessionless_events_are_distinct() {
    let mut state = ReducerState::default();

    let cases = [
        (
            HookEventType::TeammateIdle,
            "event skipped: teammate_idle_informational",
        ),
        (
            HookEventType::WorktreeCreate,
            "event skipped: worktree_create_no_session",
        ),
        (
            HookEventType::WorktreeRemove,
            "event skipped: worktree_remove_informational",
        ),
        (
            HookEventType::ConfigChange,
            "event skipped: config_change_no_session",
        ),
        (HookEventType::Unknown, "event skipped: unknown_event_type"),
    ];

    for (index, (event_type, expected_message)) in cases.into_iter().enumerate() {
        let mut event = event_base(event_type);
        event.event_id = format!("evt-{index}");
        event.recorded_at = format!("2099-01-31T00:00:0{index}Z");

        let outcome = state.apply_hook_event(event);
        assert_eq!(outcome.message, expected_message);
    }
}

#[test]
fn worktree_create_refreshes_timestamps() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut worktree = event_base(HookEventType::WorktreeCreate);
    worktree.event_id = "evt-worktree-refresh".to_string();
    worktree.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(worktree);

    assert_eq!(outcome.message, "event ingested");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working),
        "State should be preserved"
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.updated_at.as_str()),
        Some("2099-01-31T00:00:05Z"),
        "Timestamp should be refreshed"
    );
}

#[test]
fn config_change_refreshes_timestamps() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::SessionStart));
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut config_change = event_base(HookEventType::ConfigChange);
    config_change.event_id = "evt-config-refresh".to_string();
    config_change.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(config_change);

    assert_eq!(outcome.message, "event ingested");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working),
        "State should be preserved"
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.updated_at.as_str()),
        Some("2099-01-31T00:00:05Z"),
        "Timestamp should be refreshed"
    );
}

#[test]
fn worktree_create_skips_when_no_session() {
    let mut state = ReducerState::default();

    let outcome = state.apply_hook_event(event_base(HookEventType::WorktreeCreate));

    assert_eq!(outcome.message, "event skipped: worktree_create_no_session");
    assert!(!state.sessions.contains_key("session-1"));
}

#[test]
fn test_reducer_17_event_contract_matrix() {
    #[derive(Clone, Copy)]
    struct EventExpectation {
        event_type: HookEventType,
        setup: Option<HookEventType>,
        notification_type: Option<&'static str>,
        expected_state: Option<SessionState>,
        expected_skip_reason: Option<&'static str>,
        description: &'static str,
    }

    let expectations = [
        EventExpectation {
            event_type: HookEventType::SessionStart,
            setup: None,
            notification_type: None,
            expected_state: Some(SessionState::Ready),
            expected_skip_reason: None,
            description: "session_start (no prior state)",
        },
        EventExpectation {
            event_type: HookEventType::SessionStart,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("session_start_already_active"),
            description: "session_start (already Working)",
        },
        EventExpectation {
            event_type: HookEventType::UserPromptSubmit,
            setup: Some(HookEventType::SessionStart),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "user_prompt_submit",
        },
        EventExpectation {
            event_type: HookEventType::PreToolUse,
            setup: Some(HookEventType::SessionStart),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "pre_tool_use",
        },
        EventExpectation {
            event_type: HookEventType::PostToolUse,
            setup: Some(HookEventType::PreToolUse),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "post_tool_use",
        },
        EventExpectation {
            event_type: HookEventType::PostToolUseFailure,
            setup: Some(HookEventType::PreToolUse),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "post_tool_use_failure",
        },
        EventExpectation {
            event_type: HookEventType::PermissionRequest,
            setup: Some(HookEventType::PreToolUse),
            notification_type: None,
            expected_state: Some(SessionState::Waiting),
            expected_skip_reason: None,
            description: "permission_request",
        },
        EventExpectation {
            event_type: HookEventType::PreCompact,
            setup: Some(HookEventType::PreToolUse),
            notification_type: None,
            expected_state: Some(SessionState::Compacting),
            expected_skip_reason: None,
            description: "pre_compact",
        },
        EventExpectation {
            event_type: HookEventType::Notification,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: Some("idle_prompt"),
            expected_state: Some(SessionState::Ready),
            expected_skip_reason: None,
            description: "notification (idle_prompt)",
        },
        EventExpectation {
            event_type: HookEventType::Notification,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: Some("auth_success"),
            expected_state: Some(SessionState::Ready),
            expected_skip_reason: None,
            description: "notification (auth_success)",
        },
        EventExpectation {
            event_type: HookEventType::Notification,
            setup: Some(HookEventType::PreToolUse),
            notification_type: Some("permission_prompt"),
            expected_state: Some(SessionState::Waiting),
            expected_skip_reason: None,
            description: "notification (permission_prompt)",
        },
        EventExpectation {
            event_type: HookEventType::Notification,
            setup: Some(HookEventType::PreToolUse),
            notification_type: Some("elicitation_dialog"),
            expected_state: Some(SessionState::Waiting),
            expected_skip_reason: None,
            description: "notification (elicitation_dialog)",
        },
        EventExpectation {
            event_type: HookEventType::Notification,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: Some("other"),
            expected_state: None,
            expected_skip_reason: Some("notification_non_stateful"),
            description: "notification (other)",
        },
        EventExpectation {
            event_type: HookEventType::SubagentStart,
            setup: Some(HookEventType::SessionStart),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "subagent_start (from Ready)",
        },
        EventExpectation {
            event_type: HookEventType::SubagentStart,
            setup: Some(HookEventType::PermissionRequest),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("subagent_start_higher_priority_active"),
            description: "subagent_start (from Waiting)",
        },
        EventExpectation {
            event_type: HookEventType::SubagentStop,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("subagent_stop_working_no_tools_stale"),
            description: "subagent_stop (from Working, no tools)",
        },
        EventExpectation {
            event_type: HookEventType::SubagentStop,
            setup: Some(HookEventType::PreToolUse),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "subagent_stop (from Working, tools in flight)",
        },
        EventExpectation {
            event_type: HookEventType::SubagentStop,
            setup: Some(HookEventType::PermissionRequest),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("subagent_stop_higher_priority_active"),
            description: "subagent_stop (from Waiting)",
        },
        EventExpectation {
            event_type: HookEventType::Stop,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: Some(SessionState::Ready),
            expected_skip_reason: None,
            description: "stop (parent session)",
        },
        EventExpectation {
            event_type: HookEventType::Stop,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("stop_guard"),
            description: "stop (subagent, agent_id present)",
        },
        EventExpectation {
            event_type: HookEventType::Stop,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("stop_guard"),
            description: "stop (stop_hook_active)",
        },
        EventExpectation {
            event_type: HookEventType::TaskCompleted,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: Some("task_completed_intent_preserved"),
            description: "task_completed (parent)",
        },
        EventExpectation {
            event_type: HookEventType::TaskCompleted,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("auxiliary_task_metadata"),
            description: "task_completed (auxiliary, agent_id present)",
        },
        EventExpectation {
            event_type: HookEventType::TeammateIdle,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("teammate_idle_informational"),
            description: "teammate_idle",
        },
        EventExpectation {
            event_type: HookEventType::WorktreeCreate,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "worktree_create",
        },
        EventExpectation {
            event_type: HookEventType::WorktreeRemove,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("worktree_remove_informational"),
            description: "worktree_remove",
        },
        EventExpectation {
            event_type: HookEventType::ConfigChange,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: Some(SessionState::Working),
            expected_skip_reason: None,
            description: "config_change",
        },
        EventExpectation {
            event_type: HookEventType::Unknown,
            setup: Some(HookEventType::UserPromptSubmit),
            notification_type: None,
            expected_state: None,
            expected_skip_reason: Some("unknown_event_type"),
            description: "unknown",
        },
    ];

    assert_eq!(expectations.len(), 28);

    // SessionEnd is intentionally covered by the dedicated tests:
    // `session_end_produces_idle_regardless_of_pid` and
    // `session_end_with_dead_pid_produces_idle`.
    for event_type in [
        HookEventType::SessionStart,
        HookEventType::UserPromptSubmit,
        HookEventType::PreToolUse,
        HookEventType::PostToolUse,
        HookEventType::PostToolUseFailure,
        HookEventType::PermissionRequest,
        HookEventType::PreCompact,
        HookEventType::Notification,
        HookEventType::SubagentStart,
        HookEventType::SubagentStop,
        HookEventType::Stop,
        HookEventType::TeammateIdle,
        HookEventType::TaskCompleted,
        HookEventType::WorktreeCreate,
        HookEventType::WorktreeRemove,
        HookEventType::ConfigChange,
        HookEventType::Unknown,
    ] {
        assert!(
            expectations.iter().any(|row| row.event_type == event_type),
            "{event_type:?} should appear in the matrix",
        );
    }

    for (index, expectation) in expectations.iter().enumerate() {
        let mut state = ReducerState::default();

        if let Some(setup_event_type) = expectation.setup {
            // PermissionRequest and waiting-state notifications require tools_in_flight > 0.
            // Fire a PreToolUse first when the setup event needs it.
            if setup_event_type == HookEventType::PermissionRequest {
                let mut pre = event_base(HookEventType::PreToolUse);
                pre.event_id = format!("pre-setup-{index}");
                pre.recorded_at = "2099-01-30T23:59:59Z".to_string();
                let _ = state.apply_hook_event(pre);
            }

            let mut setup = event_base(setup_event_type);
            setup.event_id = format!("setup-{index}");
            setup.recorded_at = "2099-01-31T00:00:00Z".to_string();

            let outcome = state.apply_hook_event(setup);
            assert!(outcome.ok, "setup failed for {}", expectation.description);
        }

        let before = state.sessions.get("session-1").cloned();

        let mut event = event_base(expectation.event_type);
        event.event_id = format!("matrix-{index}");
        event.recorded_at = format!("2099-01-31T00:00:{:02}Z", index + 1);
        event.notification_type = expectation.notification_type.map(str::to_string);

        match expectation.description {
            "stop (parent session)" | "stop (subagent, agent_id present)" => {
                event.stop_hook_active = Some(false);
            }
            "stop (stop_hook_active)" => {
                event.stop_hook_active = Some(true);
            }
            _ => {}
        }

        match expectation.description {
            "stop (subagent, agent_id present)"
            | "task_completed (auxiliary, agent_id present)" => {
                event.agent_id = Some("agent-1".to_string());
            }
            _ => {}
        }

        let outcome = state.apply_hook_event(event);
        assert!(
            outcome.ok,
            "{} should produce a successful mutation outcome: {:?}",
            expectation.description, outcome
        );

        if let Some(skip_reason) = expectation.expected_skip_reason {
            assert_eq!(
                outcome.message,
                format!("event skipped: {skip_reason}"),
                "{} should skip with the expected reason",
                expectation.description
            );
        } else {
            assert_eq!(
                outcome.message, "event ingested",
                "{} should be ingested",
                expectation.description
            );
        }

        let after = state.sessions.get("session-1").cloned();
        match expectation.expected_state {
            Some(expected_state) => {
                let session = after
                    .as_ref()
                    .unwrap_or_else(|| panic!("{} should keep a session", expectation.description));
                assert_eq!(
                    session.state, expected_state,
                    "{} should produce the expected session state",
                    expectation.description
                );

                let expected_event_kind = match expectation.description {
                    "notification (idle_prompt)" => Some(HookEventType::Notification),
                    "notification (auth_success)" => Some(HookEventType::Notification),
                    "stop (parent session)" => Some(HookEventType::Stop),
                    _ => None,
                };
                if let Some(expected) = expected_event_kind {
                    assert_eq!(
                        session
                            .state_source
                            .as_ref()
                            .map(|source| source.event_kind),
                        Some(expected),
                        "{} should record the event_kind via state_source",
                        expectation.description
                    );
                }

                match expectation.description {
                    "pre_tool_use" => assert_eq!(session.tools_in_flight, 1),
                    "post_tool_use" | "post_tool_use_failure" | "pre_compact" => {
                        assert_eq!(session.tools_in_flight, 0)
                    }
                    "subagent_stop (from Working, tools in flight)" => {
                        assert_eq!(session.tools_in_flight, 1)
                    }
                    _ => {}
                }
            }
            None => {
                assert_eq!(
                    after, before,
                    "{} should leave the session unchanged",
                    expectation.description
                );
            }
        }
    }
}

#[test]
fn test_stale_idle_prompt_does_not_overwrite_fresh_working() {
    let mut state = ReducerState::default();

    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(pre_tool);
    assert!(outcome.ok);

    let before = state
        .sessions
        .get("session-1")
        .cloned()
        .expect("session should exist after pre_tool_use");

    let mut idle_prompt = event_base(HookEventType::Notification);
    idle_prompt.event_id = "evt-stale-idle".to_string();
    idle_prompt.recorded_at = "2099-01-30T23:59:54Z".to_string();
    idle_prompt.notification_type = Some("idle_prompt".to_string());

    let outcome = state.apply_hook_event(idle_prompt);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "stale event skipped");
    assert_eq!(state.stale_events_skipped, 1);
    assert_eq!(state.sessions.get("session-1"), Some(&before));
}

#[test]
fn test_near_boundary_idle_prompt_applies() {
    let mut state = ReducerState::default();

    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(pre_tool);
    assert!(outcome.ok);

    let mut idle_prompt = event_base(HookEventType::Notification);
    idle_prompt.event_id = "evt-near-boundary-idle".to_string();
    idle_prompt.recorded_at = "2099-01-30T23:59:56Z".to_string();
    idle_prompt.notification_type = Some("idle_prompt".to_string());

    let outcome = state.apply_hook_event(idle_prompt);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "event ingested");

    let session = state
        .sessions
        .get("session-1")
        .expect("session should exist");
    assert_eq!(session.state, SessionState::Working);
    assert_eq!(session.tools_in_flight, 0);
}

#[test]
fn test_out_of_order_pretool_then_idle_prompt() {
    let mut state = ReducerState::default();

    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(pre_tool);
    assert!(outcome.ok);

    let mut idle_prompt = event_base(HookEventType::Notification);
    idle_prompt.event_id = "evt-out-of-order-idle".to_string();
    idle_prompt.recorded_at = "2099-01-31T00:00:01Z".to_string();
    idle_prompt.notification_type = Some("idle_prompt".to_string());

    let outcome = state.apply_hook_event(idle_prompt);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "event ingested");

    let session = state
        .sessions
        .get("session-1")
        .expect("session should exist");
    assert_eq!(session.state, SessionState::Working);
    assert_eq!(session.tools_in_flight, 0);
}

#[test]
fn test_task_completed_parent_session_transitions_to_idle() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut task_completed = event_base(HookEventType::TaskCompleted);
    task_completed.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(task_completed);
    assert!(outcome.ok);
    assert_eq!(
        outcome.message,
        "event skipped: task_completed_intent_preserved"
    );

    let session = state
        .sessions
        .get("session-1")
        .expect("session should exist");
    assert_eq!(session.state, SessionState::Working);
}

mod flicker_regression {
    use super::*;

    #[test]
    fn live_session_never_reaches_idle_between_tool_bursts() {
        let mut state = ReducerState::default();
        let events = [
            HookEventType::PreToolUse,
            HookEventType::PostToolUse,
            HookEventType::Stop,
            HookEventType::PreToolUse,
            HookEventType::PostToolUse,
        ];

        for (index, event_type) in events.into_iter().enumerate() {
            let mut event = event_base(event_type);
            event.recorded_at = format!("2099-01-31T00:00:0{index}Z");
            if event_type == HookEventType::Stop {
                event.stop_hook_active = Some(false);
            }

            let outcome = state.apply_hook_event(event);
            assert!(outcome.ok, "event {event_type:?} should be accepted");

            let session = state
                .sessions
                .get("session-1")
                .expect("session should exist");
            assert_ne!(
                session.state,
                SessionState::Idle,
                "session should never flicker to Idle after {event_type:?}"
            );
        }

        let session = state
            .sessions
            .get("session-1")
            .expect("session should exist");
        assert_eq!(session.state, SessionState::Working);
    }

    #[test]
    fn task_completed_preserves_working_state() {
        let mut state = ReducerState::default();
        let events = [
            HookEventType::PreToolUse,
            HookEventType::PostToolUse,
            HookEventType::TaskCompleted,
            HookEventType::PreToolUse,
            HookEventType::PostToolUse,
        ];

        for (index, event_type) in events.into_iter().enumerate() {
            let mut event = event_base(event_type);
            event.recorded_at = format!("2099-01-31T00:00:1{index}Z");

            let outcome = state.apply_hook_event(event);
            assert!(outcome.ok, "event {event_type:?} should be accepted");

            let session = state
                .sessions
                .get("session-1")
                .expect("session should exist");
            assert_eq!(
                session.state,
                SessionState::Working,
                "session should remain Working after {event_type:?}"
            );
        }
    }

    #[test]
    fn terminated_session_retained_across_project_switch() {
        let mut state = ReducerState::default();

        let mut prompt = event_base(HookEventType::UserPromptSubmit);
        prompt.session_id = "terminated-session".to_string();
        prompt.pid = Some(11);
        prompt.recorded_at = "2099-03-31T00:00:00Z".to_string();
        let outcome = state.apply_hook_event(prompt);
        assert!(outcome.ok, "{outcome:?}");

        let mut session_end = event_base(HookEventType::SessionEnd);
        session_end.session_id = "terminated-session".to_string();
        session_end.pid = Some(11);
        session_end.recorded_at = "2099-03-31T00:05:00Z".to_string();
        let outcome = state.apply_hook_event(session_end);
        assert!(outcome.ok, "{outcome:?}");

        let terminated = state
            .sessions
            .get("terminated-session")
            .expect("terminated session");
        assert_eq!(terminated.state, SessionState::Idle);
        assert!(
            terminated.terminated_at.is_some(),
            "SessionEnd must set terminated_at"
        );

        let mut new_start = event_base(HookEventType::SessionStart);
        new_start.session_id = "fresh-session".to_string();
        new_start.pid = Some(22);
        new_start.recorded_at = "2099-03-31T01:00:00Z".to_string();
        let outcome = state.apply_hook_event(new_start);
        assert!(outcome.ok, "{outcome:?}");

        assert!(
            state.sessions.contains_key("terminated-session"),
            "terminated session must be retained via terminated_at, not evicted by orphan GC"
        );
        assert!(
            state.sessions.contains_key("fresh-session"),
            "new session should also be present"
        );
    }

    #[test]
    fn state_source_populated_on_stop() {
        let mut state = ReducerState::default();

        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let mut stop = event_base(HookEventType::Stop);
        stop.recorded_at = "2099-01-31T00:00:05Z".to_string();
        stop.stop_hook_active = Some(false);

        let outcome = state.apply_hook_event(stop);
        assert!(outcome.ok, "{outcome:?}");

        let session = state.sessions.get("session-1").expect("session");
        let source = session.state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::Stop);
        assert_eq!(source.authority, SignalAuthority::AmbiguousPerTurn);
        assert_eq!(source.observed_at, "2099-01-31T00:00:05Z");
        assert_eq!(
            session.last_authoritative_event_at.as_deref(),
            Some("2099-01-31T00:00:00Z"),
            "ambiguous events should preserve the last definitive timestamp"
        );
    }

    #[test]
    fn state_source_populated_on_session_end() {
        let mut state = ReducerState::default();

        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let mut end = event_base(HookEventType::SessionEnd);
        end.recorded_at = "2099-01-31T00:00:05Z".to_string();

        let outcome = state.apply_hook_event(end);
        assert!(outcome.ok, "{outcome:?}");

        let session = state.sessions.get("session-1").expect("session");
        let source = session.state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::SessionEnd);
        assert_eq!(source.authority, SignalAuthority::DefinitiveTerminal);
        assert_eq!(source.observed_at, "2099-01-31T00:00:05Z");
        assert_eq!(
            session.last_authoritative_event_at.as_deref(),
            Some("2099-01-31T00:00:05Z")
        );
    }
}

#[test]
fn test_task_completed_with_agent_id_skipped() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let before = state
        .sessions
        .get("session-1")
        .cloned()
        .expect("session should exist");

    let mut task_completed = event_base(HookEventType::TaskCompleted);
    task_completed.recorded_at = "2099-01-31T00:00:01Z".to_string();
    task_completed.agent_id = Some("agent-1".to_string());

    let outcome = state.apply_hook_event(task_completed);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "event skipped: auxiliary_task_metadata");
    assert_eq!(state.sessions.get("session-1"), Some(&before));
}

#[test]
fn test_task_completed_with_teammate_name_skipped() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let before = state
        .sessions
        .get("session-1")
        .cloned()
        .expect("session should exist");

    let mut task_completed = event_base(HookEventType::TaskCompleted);
    task_completed.recorded_at = "2099-01-31T00:00:01Z".to_string();
    task_completed.teammate_name = Some("teammate-1".to_string());

    let outcome = state.apply_hook_event(task_completed);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "event skipped: auxiliary_task_metadata");
    assert_eq!(state.sessions.get("session-1"), Some(&before));
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
        recorded_at: "2099-02-28T00:00:00Z".to_string(),
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
        recorded_at: "2099-02-28T00:00:00Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&mut state, "/repo");
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
        recorded_at: "2099-02-28T00:00:00Z".to_string(),
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

    assert_persisted_routing_matches_resolved_routing(&mut state, "/repo");
}

#[test]
fn routing_does_not_match_parent_directory_shells_to_descendant_projects() {
    let mut state = ReducerState::default();

    let mut attune = event_base(HookEventType::UserPromptSubmit);
    attune.session_id = "session-attune".to_string();
    attune.pid = Some(4100);
    attune.project_path = "/users/petepetrash/code/attune".to_string();
    attune.cwd = Some("/users/petepetrash/code/attune".to_string());
    attune.recorded_at = "2099-03-13T02:35:00Z".to_string();
    let _ = state.apply_hook_event(attune);

    let mut pete = event_base(HookEventType::UserPromptSubmit);
    pete.session_id = "session-pete".to_string();
    pete.pid = Some(4200);
    pete.project_path = "/users/petepetrash/code/pete-2025".to_string();
    pete.cwd = Some("/users/petepetrash/code/pete-2025".to_string());
    pete.recorded_at = "2099-03-13T02:35:01Z".to_string();
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
        recorded_at: "2099-03-13T02:35:59Z".to_string(),
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
        recorded_at: "2099-03-13T02:40:41Z".to_string(),
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
    event.recorded_at = "2099-03-13T02:45:00Z".to_string();
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
        recorded_at: "2099-03-13T02:45:30Z".to_string(),
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
    event.recorded_at = "2099-03-14T20:00:00Z".to_string();
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
        recorded_at: "2099-03-14T20:00:01Z".to_string(),
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
        recorded_at: "2099-03-14T20:00:02Z".to_string(),
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
    event.recorded_at = "2099-03-14T20:00:00Z".to_string();
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
        recorded_at: "2099-03-14T20:00:01Z".to_string(),
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
        recorded_at: "2099-03-14T20:00:02Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&mut state, "/tmp/core-project");
}

#[test]
fn routing_derives_non_active_tmux_pane_from_inventory() {
    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.pid = Some(4242);
    event.project_path = "/users/petepetrash/code/aui/mcp-app-studio-starter".to_string();
    event.cwd = Some("/users/petepetrash/code/aui/mcp-app-studio-starter".to_string());
    event.recorded_at = "2099-03-15T03:00:00Z".to_string();
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
        recorded_at: "2099-03-15T03:00:01Z".to_string(),
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
    event.recorded_at = "2099-03-15T03:00:00Z".to_string();
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
        recorded_at: "2099-03-15T03:00:01Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(
        &mut state,
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
        recorded_at: "2099-03-16T00:00:00Z".to_string(),
    });

    let route = persisted_route_for(&mut state, "/repo");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("repo"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%42'");
    assert_eq!(route.updated_at, "2099-03-16T00:00:00Z");
}

#[test]
fn routing_managed_worktree_shell_does_not_override_project_root_shell() {
    let main_shell = ShellSignal {
        tmux_session: Some("main".to_string()),
        tmux_client_tty: Some("/dev/ttys110".to_string()),
        tmux_pane: Some("%10".to_string()),
        updated_at: "2099-03-27T00:00:01Z".to_string(),
        ..shell_signal_fixture(10, "/repo")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys210".to_string()),
        tmux_pane: Some("%20".to_string()),
        updated_at: "2099-03-27T00:00:02Z".to_string(),
        ..shell_signal_fixture(20, "/repo/.capacitor/worktrees/delegation-20")
    };

    let mut state = routing_state_fixture(
        vec![
            session_summary_fixture(
                "session-main",
                10,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2099-03-27T00:00:01Z",
            ),
            session_summary_fixture(
                "session-worker",
                20,
                "/repo",
                "/repo/.capacitor/worktrees/delegation-20",
                SessionState::Working,
                "2099-03-27T00:00:02Z",
            ),
        ],
        vec![main_shell, delegation_shell],
    );

    let route = persisted_route_for(&mut state, "/repo");

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
        updated_at: "2099-03-27T00:00:03Z".to_string(),
        ..shell_signal_fixture(22, "/repo/.capacitor/worktrees/delegation-22")
    };

    let mut state = routing_state_fixture(
        vec![session_summary_fixture(
            "session-worker",
            22,
            "/repo",
            "/repo/.capacitor/worktrees/delegation-22",
            SessionState::Working,
            "2099-03-27T00:00:03Z",
        )],
        vec![delegation_shell],
    );

    let route = persisted_route_for(&mut state, "/repo");

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
        updated_at: "2099-03-27T00:00:03Z".to_string(),
        ..shell_signal_fixture(22, "/other")
    };

    let mut state = routing_state_fixture(
        vec![session_summary_fixture(
            "session-main",
            10,
            "/repo",
            "/repo",
            SessionState::Idle,
            "2099-03-27T00:00:03Z",
        )],
        vec![inventory_carrier],
    );

    let route = persisted_route_for(&mut state, "/repo");

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
        updated_at: "2099-03-27T00:00:04Z".to_string(),
        ..shell_signal_fixture(30, "/repo")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("worker".to_string()),
        tmux_client_tty: Some("/dev/ttys230".to_string()),
        tmux_pane: Some("%40".to_string()),
        updated_at: "2099-03-27T00:00:05Z".to_string(),
        ..shell_signal_fixture(40, "/repo/.capacitor/worktrees/delegation-40")
    };

    let mut state = routing_state_fixture(
        vec![
            session_summary_fixture(
                "session-main",
                30,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2099-03-27T00:00:04Z",
            ),
            session_summary_fixture(
                "session-worker",
                40,
                "/repo",
                "/repo/.capacitor/worktrees/delegation-40",
                SessionState::Working,
                "2099-03-27T00:00:05Z",
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

    let route = persisted_route_for(&mut state, "/repo");

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
        recorded_at: "2099-03-16T00:00:01Z".to_string(),
    });

    let route = persisted_route_for(&mut state, "/target");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%1"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%1' from pane inventory");
    assert_eq!(route.updated_at, "2099-03-16T00:00:01Z");
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
        recorded_at: "2099-03-16T00:00:02Z".to_string(),
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
    assert_eq!(route.updated_at, "2099-03-16T00:00:02Z");
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
        recorded_at: "2099-03-16T00:00:03Z".to_string(),
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
    assert_eq!(route.updated_at, "2099-03-16T00:00:03Z");
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
        recorded_at: "2099-03-15T06:00:00Z".to_string(),
    });

    assert_persisted_routing_matches_resolved_routing(&mut state, "/repo");
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
        recorded_at: "2099-03-15T05:40:00Z".to_string(),
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
        recorded_at: "2099-03-15T05:40:01Z".to_string(),
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
        recorded_at: "2099-03-15T05:41:00Z".to_string(),
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
        recorded_at: "2099-03-15T05:42:00Z".to_string(),
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
        recorded_at: "2099-03-15T05:41:00Z".to_string(),
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
        recorded_at: "2099-02-28T00:00:10Z".to_string(),
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
        recorded_at: "2099-02-28T00:00:00Z".to_string(),
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
    assert_eq!(shell.updated_at, "2099-02-28T00:00:10Z");
}

#[test]
fn cleanup_shells_evicts_expired_entries() {
    let now = Utc::now();
    let mut shells = std::collections::HashMap::new();

    // SHELL_RETENTION is 15 minutes
    shells.insert(
        1000,
        ShellSignal {
            updated_at: (now - Duration::minutes(16)).to_rfc3339(),
            ..shell_signal_fixture(1000, "/stale")
        },
    );
    shells.insert(
        2000,
        ShellSignal {
            updated_at: (now - Duration::minutes(5)).to_rfc3339(),
            ..shell_signal_fixture(2000, "/fresh")
        },
    );

    super::cleanup_shells_at(&mut shells, now);

    assert!(!shells.contains_key(&1000), "stale shell should be evicted");
    assert!(shells.contains_key(&2000), "fresh shell should remain");
}

#[test]
fn snapshot_omits_expired_shells() {
    let now = Utc::now();
    let state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![],
        shells: vec![
            ShellSignal {
                updated_at: (now - Duration::minutes(16)).to_rfc3339(),
                ..shell_signal_fixture(1000, "/stale")
            },
            ShellSignal {
                updated_at: (now - Duration::minutes(5)).to_rfc3339(),
                ..shell_signal_fixture(2000, "/fresh")
            },
        ],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 0,
            shell_signals_tracked: 2,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let snapshot = state.snapshot();

    assert_eq!(snapshot.shells.len(), 1);
    assert_eq!(snapshot.shells[0].pid, 2000);
    assert_eq!(snapshot.diagnostics.shell_signals_tracked, 1);
}

#[test]
fn snapshot_populates_session_is_alive_from_last_activity_at() {
    // Liveness is now driven by last_activity_at, not shell CWD matching.
    // A Working session with recent last_activity_at should be alive;
    // an Idle session is always not alive regardless of timestamps.
    let now = chrono::DateTime::parse_from_rfc3339("2020-01-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            SessionSummary {
                last_activity_at: Some((now - Duration::seconds(60)).to_rfc3339()),
                ..session_summary_fixture(
                    "live-working",
                    11,
                    "/repo-a",
                    "/repo-a",
                    SessionState::Working,
                    &(now - Duration::seconds(60)).to_rfc3339(),
                )
            },
            session_summary_fixture(
                "idle-session",
                22,
                "/repo-b",
                "/repo-b",
                SessionState::Idle,
                &(now - Duration::seconds(60)).to_rfc3339(),
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert!(
        state
            .sessions
            .get("live-working")
            .is_some_and(|session| session.is_alive),
        "Working session with recent last_activity_at should be alive"
    );
    assert!(
        state
            .sessions
            .get("idle-session")
            .is_some_and(|session| !session.is_alive),
        "Idle session should always be not alive"
    );
}

#[test]
fn shell_cwd_match_does_not_affect_liveness() {
    // Shell CWD matching was removed — liveness is now driven exclusively by
    // last_activity_at. Verify that even a matching shell CWD does not mark
    // a session alive when last_activity_at is stale.
    let now = chrono::DateTime::parse_from_rfc3339("2020-01-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let mut state = routing_state_fixture(
        vec![session_summary_fixture(
            "session-1",
            0,
            "/users/pete/code/myproject",
            "/users/pete/code/myproject",
            SessionState::Working,
            &(now - Duration::minutes(4)).to_rfc3339(),
        )],
        vec![],
    );

    // Shell CWD matches the project root
    let outcome = state.apply_shell_signal(IngestShellSignalCommand {
        pid: 4242,
        cwd: "/users/pete/code/myproject".to_string(),
        tty: "/dev/ttys4242".to_string(),
        parent_app: "ghostty".to_string(),
        tmux_session: None,
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: (now - Duration::seconds(30)).to_rfc3339(),
    });
    assert!(outcome.ok, "{outcome:?}");

    state.gc_stale_sessions_at(now);
    assert!(
        !state.sessions.get("session-1").expect("session").is_alive,
        "Shell CWD should not mark session alive — liveness uses last_activity_at only"
    );
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

    // PreToolUse first so tools_in_flight > 0 when PermissionRequest arrives
    let mut pre = event_base(HookEventType::PreToolUse);
    pre.session_id = "session-1".to_string();
    pre.recorded_at = "2099-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(pre);

    let mut first = event_base(HookEventType::PermissionRequest);
    first.session_id = "session-1".to_string();
    first.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(first);

    let mut second = event_base(HookEventType::UserPromptSubmit);
    second.session_id = "session-2".to_string();
    second.recorded_at = "2099-01-31T00:00:02Z".to_string();
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
fn orphaned_session_gc_evicts_stale_same_project_sibling_on_new_session_start() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "ghost-session",
            11,
            "/repo",
            "/repo",
            SessionState::Working,
            "2099-03-27T12:00:00Z",
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2099-03-31T00:00:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let mut fresh_start = event_base(HookEventType::SessionStart);
    fresh_start.session_id = "fresh-session".to_string();
    fresh_start.pid = Some(22);
    fresh_start.recorded_at = "2099-03-31T12:00:00Z".to_string();

    let outcome = state.apply_hook_event(fresh_start);

    assert!(outcome.ok, "{outcome:?}");
    assert!(!state.sessions.contains_key("ghost-session"));

    let fresh = state.sessions.get("fresh-session").expect("fresh session");
    assert_eq!(fresh.state, SessionState::Ready);

    let project = state
        .snapshot()
        .projects
        .into_iter()
        .find(|project| project.project_path == "/repo")
        .expect("project");

    assert_eq!(project.state, SessionState::Ready);
    assert_eq!(
        project.representative_session_id.as_deref(),
        Some("fresh-session")
    );
    assert_eq!(project.latest_session_id.as_deref(), Some("fresh-session"));
    assert_eq!(project.session_count, 1);
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

    // 2) Config changes now refresh the session instead of being skipped
    let mut config_change = event_base(HookEventType::ConfigChange);
    config_change.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let outcome = state.apply_hook_event(config_change);
    assert_eq!(outcome.message, "event ingested");

    // 3) Worktree creates also refresh the session instead of being skipped
    let mut worktree = event_base(HookEventType::WorktreeCreate);
    worktree.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let outcome = state.apply_hook_event(worktree);
    assert_eq!(outcome.message, "event ingested");

    // 4) Informational events still count when they genuinely skip
    let mut teammate_idle = event_base(HookEventType::TeammateIdle);
    teammate_idle.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let outcome = state.apply_hook_event(teammate_idle);
    assert!(outcome.message.contains("teammate_idle_informational"));

    let mut worktree_remove = event_base(HookEventType::WorktreeRemove);
    worktree_remove.recorded_at = "2099-01-31T00:00:04Z".to_string();
    let outcome = state.apply_hook_event(worktree_remove);
    assert!(outcome.message.contains("worktree_remove_informational"));

    // 5) Idle prompt while tools are drifted in flight should self-correct
    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(pre_tool);

    let mut idle = event_base(HookEventType::Notification);
    idle.notification_type = Some("idle_prompt".to_string());
    idle.recorded_at = "2099-01-31T00:00:06Z".to_string();
    let outcome = state.apply_hook_event(idle);
    assert_eq!(outcome.message, "event ingested");
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .map(|session| session.tools_in_flight),
        Some(0)
    );

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
    event.recorded_at = "2099-03-25T10:00:00Z".to_string();
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
        recorded_at: "2099-03-25T10:00:00Z".to_string(),
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
        recorded_at: "2099-03-25T12:00:00Z".to_string(),
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
    event.recorded_at = "2099-03-25T10:00:00Z".to_string();
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
        recorded_at: "2099-03-25T12:00:00Z".to_string(),
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
        recorded_at: "2099-03-25T12:00:00Z".to_string(),
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
        updated_at: "2099-03-25T10:00:00Z".to_string(),
        ..shell_signal_fixture(1000, "/users/pete/code/capacitor")
    };
    let delegation_shell = ShellSignal {
        tmux_session: Some("delegation-abc12345".to_string()),
        tmux_client_tty: Some("/dev/ttys098".to_string()),
        tmux_pane: Some("%2".to_string()),
        updated_at: "2099-03-25T12:00:00Z".to_string(),
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
                "2099-03-25T10:00:00Z",
            ),
            session_summary_fixture(
                "session-delegation",
                2000,
                "/users/pete/code/capacitor",
                "/users/pete/code/capacitor/.capacitor/worktrees/delegation-abc12345",
                SessionState::Working,
                "2099-03-25T12:00:00Z",
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

// ────────────────────────────────────────────────────────────
// Late-arriving waiting-state notification guard
// ────────────────────────────────────────────────────────────

#[test]
fn test_elicitation_dialog_skipped_when_tools_not_in_flight() {
    // Scenario: PreToolUse → PostToolUse → late Notification(elicitation_dialog)
    // The notification arrives AFTER the tool completed, so tools_in_flight == 0.
    // It should be skipped rather than overwriting Working back to Waiting.
    let mut state = ReducerState::default();

    // 1. Start session and begin working
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Working);
    assert_eq!(session.tools_in_flight, 0);

    // 2. PreToolUse → tools_in_flight = 1
    let mut pre = event_base(HookEventType::PreToolUse);
    pre.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(pre);
    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Working);
    assert_eq!(session.tools_in_flight, 1);

    // 3. PostToolUse → tools_in_flight = 0, state = Working
    let mut post = event_base(HookEventType::PostToolUse);
    post.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(post);
    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Working);
    assert_eq!(session.tools_in_flight, 0);

    // 4. Late-arriving Notification(elicitation_dialog) — should NOT overwrite Working
    let mut notif = event_base(HookEventType::Notification);
    notif.notification_type = Some("elicitation_dialog".to_string());
    notif.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let outcome = state.apply_hook_event(notif);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "Late elicitation_dialog with tools_in_flight=0 should not overwrite Working"
    );
}

#[test]
fn test_permission_prompt_skipped_when_tools_not_in_flight() {
    // Same scenario but with permission_prompt notification
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut pre = event_base(HookEventType::PreToolUse);
    pre.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(pre);

    let mut post = event_base(HookEventType::PostToolUse);
    post.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(post);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.tools_in_flight, 0);

    let mut notif = event_base(HookEventType::Notification);
    notif.notification_type = Some("permission_prompt".to_string());
    notif.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let outcome = state.apply_hook_event(notif);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "Late permission_prompt with tools_in_flight=0 should not overwrite Working"
    );
}

#[test]
fn test_elicitation_dialog_allowed_when_tools_in_flight() {
    // Normal flow: PreToolUse → Notification(elicitation_dialog) (tool is still running)
    // tools_in_flight > 0, so the notification should be processed normally.
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut pre = event_base(HookEventType::PreToolUse);
    pre.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(pre);
    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.tools_in_flight, 1);

    // Notification arrives while tool is in flight — this is the normal case
    let mut notif = event_base(HookEventType::Notification);
    notif.notification_type = Some("elicitation_dialog".to_string());
    notif.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let outcome = state.apply_hook_event(notif);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Waiting,
        "elicitation_dialog with tools_in_flight=1 should set Waiting (normal flow)"
    );
}

#[test]
fn test_permission_request_skipped_when_tools_not_in_flight() {
    // PermissionRequest arriving after tool completed — defensive guard
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut pre = event_base(HookEventType::PreToolUse);
    pre.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(pre);

    let mut post = event_base(HookEventType::PostToolUse);
    post.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(post);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.tools_in_flight, 0);

    let mut perm = event_base(HookEventType::PermissionRequest);
    perm.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let outcome = state.apply_hook_event(perm);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "Late PermissionRequest with tools_in_flight=0 should not overwrite Working"
    );
}

// --- Cross-project state leak regression tests ---
//
// These tests verify that derive_project_identity() does not re-attribute
// a session to a foreign project when file_path or cwd points elsewhere.
// They use tempfile-backed git repos so resolve_project_identity() actually
// resolves real project boundaries rather than falling through to raw strings.

fn make_git_repo(base: &std::path::Path, name: &str) -> std::path::PathBuf {
    let repo = base.join(name);
    std::fs::create_dir_all(repo.join(".git")).expect("create .git dir");
    std::fs::create_dir_all(repo.join("src")).expect("create src dir");
    std::fs::write(repo.join("src").join("lib.rs"), "// placeholder").expect("write file");
    // Canonicalize to resolve macOS /var -> /private/var symlinks so test
    // assertions match the canonicalized paths produced by resolve_project_identity.
    std::fs::canonicalize(&repo).expect("canonicalize repo path")
}

#[test]
fn file_path_in_different_project_does_not_reassign_session() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_a = make_git_repo(tmp.path(), "project-a");
    let repo_b = make_git_repo(tmp.path(), "project-b");

    let repo_a_str = repo_a.to_string_lossy().to_string();
    let repo_b_str = repo_b.to_string_lossy().to_string();

    let mut state = ReducerState::default();

    // First event establishes the session in project-a.
    let mut start = event_base(HookEventType::SessionStart);
    start.project_path = repo_a_str.clone();
    start.cwd = Some(repo_a_str.clone());
    start.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(start);

    let session = state
        .sessions
        .get("session-1")
        .expect("session after start");
    let initial_project = session.project_path.clone();

    // Second event has a file_path in a completely different project.
    let foreign_file = repo_b.join("src").join("lib.rs");
    let mut tool_event = event_base(HookEventType::PreToolUse);
    tool_event.project_path = repo_a_str.clone();
    tool_event.cwd = Some(repo_a_str.clone());
    tool_event.file_path = Some(foreign_file.to_string_lossy().to_string());
    tool_event.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(tool_event);

    let session = state
        .sessions
        .get("session-1")
        .expect("session after tool event");
    assert_eq!(
        session.project_path, initial_project,
        "Session should stay in project-a, not leak to project-b via file_path"
    );
    // Verify it did NOT get assigned to project-b.
    let repo_b_normalized = crate::domain::normalize_path_for_matching(&repo_b_str);
    assert_ne!(
        session.project_path, repo_b_normalized,
        "Session must not be attributed to project-b"
    );
}

#[test]
fn cwd_in_different_project_does_not_reassign_when_project_path_set() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_a = make_git_repo(tmp.path(), "project-a");
    let repo_b = make_git_repo(tmp.path(), "project-b");

    let repo_a_str = repo_a.to_string_lossy().to_string();
    let repo_b_str = repo_b.to_string_lossy().to_string();

    let mut state = ReducerState::default();

    // Event with project_path pointing at project-a, but cwd at project-b.
    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = repo_a_str.clone();
    event.cwd = Some(repo_b_str.clone());
    event.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let session = state.sessions.get("session-1").expect("session");
    let repo_a_normalized = crate::domain::normalize_path_for_matching(&repo_a_str);
    assert_eq!(
        session.project_path, repo_a_normalized,
        "Session should be attributed to project-a (from project_path), not project-b (from cwd)"
    );
}

#[test]
fn empty_project_path_falls_back_to_cwd() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo = make_git_repo(tmp.path(), "fallback-repo");
    let repo_str = repo.to_string_lossy().to_string();

    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = String::new();
    event.cwd = Some(repo_str.clone());
    event.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let session = state.sessions.get("session-1").expect("session");
    let repo_normalized = crate::domain::normalize_path_for_matching(&repo_str);
    assert_eq!(
        session.project_path, repo_normalized,
        "With empty project_path, session should fall back to cwd-resolved identity"
    );
}

#[test]
fn gc_transitions_stale_working_to_idle_after_signal_absence() {
    // A Working session with no activity for 10+ minutes is transitioned to Idle
    // via the unified signal absence GC. No sole-vs-multi distinction.
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "stale-working",
            10,
            "/repo",
            "/repo",
            SessionState::Working,
            &stale_ts,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 1);

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Session should be preserved as Idle"
    );
    let session = state
        .sessions
        .get("stale-working")
        .expect("session preserved");
    assert_eq!(
        session.state,
        SessionState::Idle,
        "Stale Working session should transition to Idle after signal absence"
    );
    assert_eq!(session.gc_reason.as_deref(), Some("signal_absence"),);
}

#[test]
fn snapshot_preserves_fresh_working_session() {
    let now = Utc::now();
    let fresh_ts = (now - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "fresh-working",
            10,
            "/repo",
            "/repo",
            SessionState::Working,
            &fresh_ts,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Fresh working session should survive snapshot GC"
    );
    let session = state.sessions.get("fresh-working").expect("session");
    assert_eq!(session.state, SessionState::Working);
}

#[test]
fn gc_boundary_at_signal_absence_grace() {
    // At exactly 10 minutes (boundary), the session should survive because
    // SIGNAL_ABSENCE_GRACE uses strict greater-than (>10min).
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            state: SessionState::Ready,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_activity_at: Some(stale_ts.clone()),
            is_alive: false,
            ..session_summary_fixture(
                "boundary-ready",
                10,
                "/repo",
                "/repo",
                SessionState::Ready,
                &stale_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 1);

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Session at exact boundary should survive (strict greater-than)"
    );
    let session = state.sessions.get("boundary-ready").expect("session");
    assert_eq!(
        session.state,
        SessionState::Ready,
        "Session at 10-minute boundary should NOT be transitioned to Idle"
    );
}

#[test]
fn snapshot_gc_fixes_project_state_with_orphan_and_idle_session() {
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();
    let fresh_ts = (now - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "orphan-working",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "current-idle",
                20,
                "/repo",
                "/repo",
                SessionState::Idle,
                &fresh_ts,
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 2);

    let project_before = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project_before.state,
        SessionState::Working,
        "Project should show Working before GC due to orphan session"
    );

    state.gc_stale_sessions_at(now);

    // New GC transitions the orphan Working to Idle (rather than removing it).
    // Both sessions end up Idle.
    assert_eq!(state.sessions.len(), 2, "Both sessions should be preserved");
    let orphan = state
        .sessions
        .get("orphan-working")
        .expect("orphan preserved");
    assert_eq!(
        orphan.state,
        SessionState::Idle,
        "Orphan should be transitioned to Idle"
    );
    assert_eq!(orphan.gc_reason.as_deref(), Some("signal_absence"));

    let project = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project.state,
        SessionState::Idle,
        "Project state should be Idle after orphan transition"
    );
}

#[test]
fn project_path_anchors_identity_across_multiple_events() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_a = make_git_repo(tmp.path(), "stable-project");
    let repo_b = make_git_repo(tmp.path(), "foreign-project");

    let repo_a_str = repo_a.to_string_lossy().to_string();
    let repo_a_normalized = crate::domain::normalize_path_for_matching(&repo_a_str);

    let foreign_file = repo_b.join("src").join("lib.rs");

    let mut state = ReducerState::default();

    // SessionStart in project-a.
    let mut start = event_base(HookEventType::SessionStart);
    start.project_path = repo_a_str.clone();
    start.cwd = Some(repo_a_str.clone());
    start.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(start);

    let session = state.sessions.get("session-1").expect("after start");
    assert_eq!(session.project_path, repo_a_normalized);

    // PreToolUse with foreign file_path.
    let mut pre = event_base(HookEventType::PreToolUse);
    pre.project_path = repo_a_str.clone();
    pre.cwd = Some(repo_a_str.clone());
    pre.file_path = Some(foreign_file.to_string_lossy().to_string());
    pre.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(pre);

    let session = state.sessions.get("session-1").expect("after pre-tool");
    assert_eq!(
        session.project_path, repo_a_normalized,
        "PreToolUse with foreign file_path should not reassign session"
    );

    // PostToolUse with foreign file_path.
    let mut post = event_base(HookEventType::PostToolUse);
    post.project_path = repo_a_str.clone();
    post.cwd = Some(repo_a_str.clone());
    post.file_path = Some(foreign_file.to_string_lossy().to_string());
    post.recorded_at = "2026-01-31T00:00:02Z".to_string();
    let _ = state.apply_hook_event(post);

    let session = state.sessions.get("session-1").expect("after post-tool");
    assert_eq!(
        session.project_path, repo_a_normalized,
        "PostToolUse with foreign file_path should not reassign session"
    );

    // UserPromptSubmit without file_path — should still be in project-a.
    let mut prompt = event_base(HookEventType::UserPromptSubmit);
    prompt.project_path = repo_a_str.clone();
    prompt.cwd = Some(repo_a_str.clone());
    prompt.recorded_at = "2026-01-31T00:00:03Z".to_string();
    let _ = state.apply_hook_event(prompt);

    let session = state.sessions.get("session-1").expect("after prompt");
    assert_eq!(
        session.project_path, repo_a_normalized,
        "Session project_path must remain stable across all event types"
    );
}

#[test]
fn monorepo_sibling_package_file_path_does_not_reassign_session() {
    // Single git repo with two sibling package boundaries.
    // A session anchored to packages/api must NOT be reassigned when
    // file_path points into packages/web (same project_id, but sibling).
    let tmp = tempfile::tempdir().expect("tempdir");
    let monorepo = tmp.path().join("monorepo");
    std::fs::create_dir_all(monorepo.join(".git")).expect("create .git");

    let pkg_api = monorepo.join("packages").join("api");
    let pkg_web = monorepo.join("packages").join("web");
    std::fs::create_dir_all(pkg_api.join("src")).expect("create api/src");
    std::fs::create_dir_all(pkg_web.join("src")).expect("create web/src");

    // package.json is a project boundary marker (priority 2)
    std::fs::write(pkg_api.join("package.json"), "{}").expect("write api marker");
    std::fs::write(pkg_web.join("package.json"), "{}").expect("write web marker");
    std::fs::write(pkg_web.join("src").join("index.ts"), "// placeholder").expect("write web file");

    let pkg_api = std::fs::canonicalize(&pkg_api).expect("canonicalize api");
    let pkg_web = std::fs::canonicalize(&pkg_web).expect("canonicalize web");
    let pkg_api_str = pkg_api.to_string_lossy().to_string();
    let pkg_web_str = pkg_web.to_string_lossy().to_string();

    let mut state = ReducerState::default();

    // Session starts in packages/api
    let mut start = event_base(HookEventType::SessionStart);
    start.project_path = pkg_api_str.clone();
    start.cwd = Some(pkg_api_str.clone());
    start.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(start);

    let session = state.sessions.get("session-1").expect("after start");
    let api_normalized = crate::domain::normalize_path_for_matching(&pkg_api_str);
    assert_eq!(session.project_path, api_normalized);

    // Tool event touches a file in the sibling package (packages/web)
    let foreign_file = pkg_web.join("src").join("index.ts");
    let mut tool_event = event_base(HookEventType::PreToolUse);
    tool_event.project_path = pkg_api_str.clone();
    tool_event.cwd = Some(pkg_api_str.clone());
    tool_event.file_path = Some(foreign_file.to_string_lossy().to_string());
    tool_event.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(tool_event);

    let session = state.sessions.get("session-1").expect("after tool");
    assert_eq!(
        session.project_path, api_normalized,
        "Session in packages/api must not leak to sibling packages/web via file_path"
    );
    let web_normalized = crate::domain::normalize_path_for_matching(&pkg_web_str);
    assert_ne!(
        session.project_path, web_normalized,
        "Session must not be attributed to sibling package"
    );
}

#[test]
fn test_project_path_drift_across_sibling_packages_blocked() {
    // Monorepo with two sibling packages.
    // Session starts in packages/api. A later event arrives with
    // project_path pointing at packages/web (sibling). Session must
    // stay in packages/api — lateral sibling moves are blocked.
    let tmp = tempfile::tempdir().expect("tempdir");
    let monorepo = tmp.path().join("monorepo");
    std::fs::create_dir_all(monorepo.join(".git")).expect("create .git");

    let pkg_api = monorepo.join("packages").join("api");
    let pkg_web = monorepo.join("packages").join("web");
    std::fs::create_dir_all(&pkg_api).expect("create api");
    std::fs::create_dir_all(&pkg_web).expect("create web");
    std::fs::write(pkg_api.join("package.json"), "{}").expect("api marker");
    std::fs::write(pkg_web.join("package.json"), "{}").expect("web marker");

    let pkg_api = std::fs::canonicalize(&pkg_api).expect("canonicalize api");
    let pkg_web = std::fs::canonicalize(&pkg_web).expect("canonicalize web");
    let pkg_api_str = pkg_api.to_string_lossy().to_string();
    let pkg_web_str = pkg_web.to_string_lossy().to_string();

    let mut state = ReducerState::default();

    // SessionStart in packages/api
    let mut start = event_base(HookEventType::SessionStart);
    start.project_path = pkg_api_str.clone();
    start.cwd = Some(pkg_api_str.clone());
    start.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(start);

    let session = state.sessions.get("session-1").expect("after start");
    let api_normalized = crate::domain::normalize_path_for_matching(&pkg_api_str);
    assert_eq!(session.project_path, api_normalized);

    // Later event arrives with project_path pointing at the sibling package
    let mut prompt = event_base(HookEventType::UserPromptSubmit);
    prompt.project_path = pkg_web_str.clone();
    prompt.cwd = Some(pkg_web_str.clone());
    prompt.recorded_at = "2026-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(prompt);

    let session = state.sessions.get("session-1").expect("after prompt");
    assert_eq!(
        session.project_path, api_normalized,
        "Session in packages/api must not drift to sibling packages/web via project_path change"
    );
}

#[test]
fn test_stale_project_path_falls_back_to_file_path() {
    // When event.project_path points to a nonexistent directory but
    // file_path points to a valid file in a real repo, the session
    // should get identity from file_path rather than being stranded.
    let tmp = tempfile::tempdir().expect("tempdir");
    let real_repo = make_git_repo(tmp.path(), "real-repo");
    let real_repo_str = real_repo.to_string_lossy().to_string();
    let real_file = real_repo.join("src").join("lib.rs");

    let mut state = ReducerState::default();

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.project_path = "/nonexistent/stale/project/path".to_string();
    event.cwd = Some(real_repo_str.clone());
    event.file_path = Some(real_file.to_string_lossy().to_string());
    event.recorded_at = "2026-01-31T00:00:00Z".to_string();
    let _ = state.apply_hook_event(event);

    let session = state.sessions.get("session-1").expect("session");
    let real_normalized = crate::domain::normalize_path_for_matching(&real_repo_str);
    assert_eq!(
        session.project_path, real_normalized,
        "Stale project_path should fall back to file_path-derived identity"
    );
    assert_ne!(
        session.project_path, "/nonexistent/stale/project/path",
        "Session must not be stranded on a nonexistent path"
    );
}

#[test]
fn gc_transitions_all_stale_sessions_to_idle() {
    // Two Working sessions both stale past the grace period. The new unified GC
    // transitions both to Idle (no sole-vs-multi distinction, no removal).
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "worker-a",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "worker-b",
                20,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 2);

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        2,
        "Both sessions should be preserved (transitioned to Idle, not removed)"
    );
    for key in ["worker-a", "worker-b"] {
        let session = state.sessions.get(key).expect(key);
        assert_eq!(
            session.state,
            SessionState::Idle,
            "{key} should be transitioned to Idle"
        );
        assert_eq!(session.gc_reason.as_deref(), Some("signal_absence"));
    }

    let project = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project.state,
        SessionState::Idle,
        "Project should show Idle after both sessions are transitioned"
    );
}

#[test]
fn snapshot_gc_evicts_stale_when_fresh_session_exists() {
    // Three sessions for /repo: A and B are stale Working, C is fresh Working.
    // A and B are transitioned to Idle by the unified GC. C stays Working.
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();
    let fresh_ts = (now - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "stale-a",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "stale-b",
                20,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "fresh-c",
                30,
                "/repo",
                "/repo",
                SessionState::Working,
                &fresh_ts,
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 3,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 3);

    state.gc_stale_sessions_at(now);

    // Stale sessions are transitioned to Idle, not removed.
    assert_eq!(state.sessions.len(), 3, "All sessions should be preserved");
    let stale_a = state.sessions.get("stale-a").expect("stale-a");
    assert_eq!(stale_a.state, SessionState::Idle, "stale-a should be Idle");
    let stale_b = state.sessions.get("stale-b").expect("stale-b");
    assert_eq!(stale_b.state, SessionState::Idle, "stale-b should be Idle");
    let fresh_c = state.sessions.get("fresh-c").expect("fresh-c");
    assert_eq!(
        fresh_c.state,
        SessionState::Working,
        "fresh-c should remain Working"
    );

    let project = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project.state,
        SessionState::Working,
        "Project should still show Working from the fresh survivor"
    );
}

/// IMP-9: event-time GC evicts stale non-terminated Idle siblings.
///
/// Under the structured provenance slice, orphan retention is keyed on
/// `terminated_at`, not `state == Idle`. A stale idle sibling without a
/// terminal marker must be evicted on a fresh same-project session start.
#[test]
fn orphaned_session_gc_evicts_stale_idle_sibling_without_terminated_at() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // Working session: fresh
            session_summary_fixture(
                "working-session",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                "2099-04-01T12:00:00Z",
            ),
            // Idle session: stale (updated 10+ minutes ago)
            session_summary_fixture(
                "idle-session",
                22,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2099-04-01T11:45:00Z",
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2099-04-01T12:00:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
    });

    // Send a SessionStart from a brand-new session on the same project.
    // The incoming timestamp is 15 minutes after the Idle session's last
    // update — well past the 5-minute grace window.
    let mut fresh_start = event_base(HookEventType::SessionStart);
    fresh_start.session_id = "new-session".to_string();
    fresh_start.pid = Some(33);
    fresh_start.recorded_at = "2099-04-01T12:00:01Z".to_string();

    let outcome = state.apply_hook_event(fresh_start);
    assert!(outcome.ok, "{outcome:?}");

    // The stale non-terminated Idle session must be evicted.
    assert!(
        !state.sessions.contains_key("idle-session"),
        "stale idle session without terminated_at should be evicted"
    );

    // The new session should exist.
    assert!(state.sessions.contains_key("new-session"));

    // The Working session was within grace, so it survives alongside the new session.
    let project = state
        .snapshot()
        .projects
        .into_iter()
        .find(|p| p.project_path == "/repo")
        .expect("project");

    assert_eq!(project.session_count, 2);
}

#[test]
fn event_time_cleanup_uses_adjusted_gc_reference_time_when_provided() {
    // SIGNAL_ABSENCE_GRACE is 10 minutes. raw_recorded_at is 11 min after stale_anchor,
    // which exceeds the grace. adjusted_gc_reference_time is only 8 min after, which
    // is within the grace.
    let stale_anchor = "2099-04-01T12:00:00Z";
    let raw_recorded_at = "2099-04-01T12:11:00Z";
    let adjusted_gc_reference_time = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:08:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let snapshot = AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "stale-worker",
            11,
            "/repo",
            "/repo",
            SessionState::Working,
            stale_anchor,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: raw_recorded_at.to_string(),
        snapshot_version: 0,
        schema_version: 0,
    };

    let mut raw_state = ReducerState::from_snapshot(snapshot.clone());
    let mut raw_event = event_base(HookEventType::SessionStart);
    raw_event.session_id = "fresh-session".to_string();
    raw_event.pid = Some(22);
    raw_event.recorded_at = raw_recorded_at.to_string();

    let outcome = raw_state.apply_hook_event(raw_event);
    assert!(outcome.ok, "{outcome:?}");
    assert!(
        !raw_state.sessions.contains_key("stale-worker"),
        "raw recorded_at should evict the stale sibling once it is 11 minutes old"
    );

    let mut adjusted_state = ReducerState::from_snapshot(snapshot);
    let mut adjusted_event = event_base(HookEventType::SessionStart);
    adjusted_event.session_id = "fresh-session".to_string();
    adjusted_event.pid = Some(22);
    adjusted_event.recorded_at = raw_recorded_at.to_string();

    let outcome = adjusted_state
        .apply_hook_event_with_gc_reference_time(adjusted_event, Some(adjusted_gc_reference_time));
    assert!(outcome.ok, "{outcome:?}");
    assert!(
        adjusted_state.sessions.contains_key("stale-worker"),
        "adjusted gc_reference_time should preserve the sibling because its effective age is 8 minutes"
    );
    assert!(adjusted_state.sessions.contains_key("fresh-session"));
}

/// IMP-2: Snapshot-time GC isolates eviction decisions per project.
///
/// Two projects each have a stale Working session and a fresh survivor.
/// GC must evict the stale session in each project independently while
/// preserving the fresh survivors, and each project must end up with
/// exactly 1 session.
#[test]
fn snapshot_gc_cross_project_isolation() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-01-01T00:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(11)).to_rfc3339();
    let fresh_ts = (base - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // /repo-a: stale Working + fresh Working
            session_summary_fixture(
                "a-stale",
                10,
                "/repo-a",
                "/repo-a",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "a-fresh",
                11,
                "/repo-a",
                "/repo-a",
                SessionState::Working,
                &fresh_ts,
            ),
            // /repo-b: stale Working + fresh Idle
            session_summary_fixture(
                "b-stale",
                20,
                "/repo-b",
                "/repo-b",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "b-fresh",
                21,
                "/repo-b",
                "/repo-b",
                SessionState::Idle,
                &fresh_ts,
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 4,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: base.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 4);

    state.gc_stale_sessions_at(base);

    // Stale sessions are transitioned to Idle (not removed).
    assert_eq!(state.sessions.len(), 4, "All sessions should be preserved");
    assert_eq!(
        state.sessions.get("a-stale").expect("a-stale").state,
        SessionState::Idle,
        "/repo-a stale session should be transitioned to Idle"
    );
    assert_eq!(
        state.sessions.get("b-stale").expect("b-stale").state,
        SessionState::Idle,
        "/repo-b stale session should be transitioned to Idle"
    );

    // Fresh sessions stay in their original state.
    assert_eq!(
        state.sessions.get("a-fresh").expect("a-fresh").state,
        SessionState::Working,
    );
    assert_eq!(
        state.sessions.get("b-fresh").expect("b-fresh").state,
        SessionState::Idle,
    );
}

/// IMP-3: Event-time GC never evicts the current session even if it is
/// the sole session for its project.
///
/// When a `SessionStart` event arrives for a session that is the only
/// session in its project, the `session_id != current_session_id` filter
/// in `cleanup_orphaned_same_project_sessions` must exclude it.
#[test]
fn orphaned_session_gc_sole_session_no_eviction() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "sole-session",
            10,
            "/repo",
            "/repo",
            SessionState::Working,
            "2099-01-01T00:00:00Z",
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2099-01-01T00:00:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 1);

    // Ingest a SessionStart for the same session.
    let mut event = event_base(HookEventType::SessionStart);
    event.session_id = "sole-session".to_string();
    event.pid = Some(10);
    event.recorded_at = "2099-01-01T00:10:00Z".to_string();

    let outcome = state.apply_hook_event(event);
    assert!(outcome.ok, "{outcome:?}");

    // The sole session must NOT be evicted.
    assert!(
        state.sessions.contains_key("sole-session"),
        "Sole session should survive event-time GC"
    );
    assert_eq!(state.sessions.len(), 1, "Session count should still be 1");
}

/// IMP-4: Snapshot-time GC uses the correct anchor for Ready sessions.
///
/// For Ready sessions the eviction anchor is `max(state_changed_at,
/// last_activity_at)`.  This test covers three scenarios:
///   A) `updated_at` fresh — not transitioned
///   B) `updated_at` fresh — not transitioned
///   C) `updated_at` stale — transitioned to Idle
#[test]
fn snapshot_gc_ready_session_uses_correct_anchor() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-01-01T00:11:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(11)).to_rfc3339();
    let fresh_ts = (base - Duration::minutes(1)).to_rfc3339();

    // --- Scenario A: last_activity_at is fresh, state_changed_at is stale ---
    {
        let ready_session = SessionSummary {
            session_id: "ready-a".to_string(),
            pid: 10,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Ready,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_event: None,
            last_activity_at: Some(fresh_ts.clone()),
            terminated_at: None,
            tools_in_flight: 0,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        };
        let survivor = session_summary_fixture(
            "idle-survivor-a",
            11,
            "/repo",
            "/repo",
            SessionState::Idle,
            &fresh_ts,
        );

        let mut state = ReducerState::from_snapshot(AppSnapshot {
            projects: vec![],
            sessions: vec![ready_session, survivor],
            shells: vec![],
            routing: vec![],
            delegations: vec![],
            runs: vec![],
            diagnostics: DiagnosticsSummary {
                events_ingested: 0,
                sessions_tracked: 2,
                shell_signals_tracked: 0,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
                last_hook_event_at: None,
            },
            generated_at: base.to_rfc3339(),
            snapshot_version: 0,
            schema_version: 0,
        });

        state.gc_stale_sessions_at(base);

        assert!(
            state.sessions.contains_key("ready-a"),
            "Scenario A: Ready session with fresh last_activity_at should survive"
        );
    }

    // --- Scenario B: state_changed_at is fresh, last_activity_at is stale ---
    {
        let ready_session = SessionSummary {
            session_id: "ready-b".to_string(),
            pid: 20,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Ready,
            state_changed_at: fresh_ts.clone(),
            updated_at: fresh_ts.clone(),
            last_event: None,
            last_activity_at: Some(stale_ts.clone()),
            terminated_at: None,
            tools_in_flight: 0,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        };
        let survivor = session_summary_fixture(
            "idle-survivor-b",
            21,
            "/repo",
            "/repo",
            SessionState::Idle,
            &fresh_ts,
        );

        let mut state = ReducerState::from_snapshot(AppSnapshot {
            projects: vec![],
            sessions: vec![ready_session, survivor],
            shells: vec![],
            routing: vec![],
            delegations: vec![],
            runs: vec![],
            diagnostics: DiagnosticsSummary {
                events_ingested: 0,
                sessions_tracked: 2,
                shell_signals_tracked: 0,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
                last_hook_event_at: None,
            },
            generated_at: base.to_rfc3339(),
            snapshot_version: 0,
            schema_version: 0,
        });

        state.gc_stale_sessions_at(base);

        assert!(
            state.sessions.contains_key("ready-b"),
            "Scenario B: Ready session with fresh state_changed_at should survive"
        );
    }

    // --- Scenario C: Both timestamps stale — should be evicted ---
    {
        let ready_session = SessionSummary {
            session_id: "ready-c".to_string(),
            pid: 30,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Ready,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_event: None,
            last_activity_at: Some(stale_ts.clone()),
            terminated_at: None,
            tools_in_flight: 0,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        };
        let survivor = session_summary_fixture(
            "idle-survivor-c",
            31,
            "/repo",
            "/repo",
            SessionState::Idle,
            &fresh_ts,
        );

        let mut state = ReducerState::from_snapshot(AppSnapshot {
            projects: vec![],
            sessions: vec![ready_session, survivor],
            shells: vec![],
            routing: vec![],
            delegations: vec![],
            runs: vec![],
            diagnostics: DiagnosticsSummary {
                events_ingested: 0,
                sessions_tracked: 2,
                shell_signals_tracked: 0,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
                last_hook_event_at: None,
            },
            generated_at: base.to_rfc3339(),
            snapshot_version: 0,
            schema_version: 0,
        });

        state.gc_stale_sessions_at(base);

        let ready_c = state.sessions.get("ready-c").expect("ready-c preserved");
        assert_eq!(
            ready_c.state,
            SessionState::Idle,
            "Scenario C: Ready session with stale updated_at should be transitioned to Idle"
        );
        assert!(
            state.sessions.contains_key("idle-survivor-c"),
            "Scenario C: Idle survivor should remain"
        );
    }
}

/// BA-4: `recompute_projects` must normalize path variants so that
/// sessions with `/repo` and `/repo/` collapse into a single project
/// entry rather than creating two separate project rows.
#[test]
fn recompute_projects_normalizes_path_variants() {
    let state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "session-no-slash",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                "2099-01-01T00:00:00Z",
            ),
            session_summary_fixture(
                "session-trailing-slash",
                20,
                "/repo/",
                "/repo/",
                SessionState::Idle,
                "2099-01-01T00:01:00Z",
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2099-01-01T00:01:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
    });

    // There must be exactly one project entry.
    assert_eq!(
        state.projects.len(),
        1,
        "Path variants should collapse into a single project, got: {:?}",
        state.projects.keys().collect::<Vec<_>>()
    );

    let project = state.projects.values().next().unwrap();
    assert_eq!(
        project.session_count, 2,
        "Both sessions should be counted under the single project"
    );
}

#[test]
fn gc_does_not_touch_alive_sessions() {
    // A Working session with recent last_activity_at should not be
    // transitioned to Idle by GC, regardless of updated_at staleness.
    let base = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(11)).to_rfc3339();
    let recent_activity_ts = (base - Duration::seconds(60)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            last_activity_at: Some(recent_activity_ts),
            ..session_summary_fixture(
                "alive-working",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: base.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(base);

    let session = state
        .sessions
        .get("alive-working")
        .expect("session preserved");
    assert_eq!(
        session.state,
        SessionState::Working,
        "Alive session should not be transitioned to Idle"
    );
    assert!(session.is_alive);
}

#[test]
fn gc_transitions_stale_orphan_to_idle() {
    // A Working session past the grace period with no activity → Idle.
    let base = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(11)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "orphan-worker",
            11,
            "/repo",
            "/repo",
            SessionState::Working,
            &stale_ts,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: base.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(base);

    let session = state
        .sessions
        .get("orphan-worker")
        .expect("session preserved");
    assert_eq!(
        session.state,
        SessionState::Idle,
        "Stale orphan Working session should be transitioned to Idle"
    );
    assert_eq!(session.gc_reason.as_deref(), Some("signal_absence"));
}

#[test]
fn session_start_after_idle_produces_ready() {
    // After a definitive SessionEnd (→ Idle), a SessionStart should resurrect
    // the session to Ready. This is the /clear resurrection path.
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    end.pid = Some(std::process::id());
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(end);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Idle);

    let mut restart = event_base(HookEventType::SessionStart);
    restart.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let outcome = state.apply_hook_event(restart);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Ready,
        "SessionStart after Idle should produce Ready"
    );
}

#[test]
fn session_start_after_session_end_clears_terminal_metadata_and_accepts_prompt() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    end.pid = Some(std::process::id());
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(end);

    let mut restart = event_base(HookEventType::SessionStart);
    restart.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let outcome = state.apply_hook_event(restart);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Ready);
    assert!(
        session.terminated_at.is_none(),
        "SessionStart must clear terminal metadata"
    );
    let source = session.state_source.as_ref().expect("state_source");
    assert_eq!(source.event_kind, HookEventType::SessionStart);
    assert_eq!(source.authority, SignalAuthority::DefinitiveTransient);
    assert_eq!(
        session.last_authoritative_event_at.as_deref(),
        Some("2099-01-31T00:00:10Z")
    );

    let mut prompt = event_base(HookEventType::UserPromptSubmit);
    prompt.recorded_at = "2099-01-31T00:00:12Z".to_string();
    let outcome = state.apply_hook_event(prompt);
    assert!(outcome.ok);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "Prompt after resurrection should not be blocked by terminal authority"
    );
}

#[test]
/// After a definitive Stop (with stop hook inactive), the session is Idle and
/// should come back to Ready after SessionStart.
fn session_start_after_stop_idle_produces_ready() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(false);
    stop.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(stop);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Ready,
        "Stop should route the session to Ready"
    );
    assert_eq!(
        session
            .state_source
            .as_ref()
            .map(|source| source.event_kind),
        Some(HookEventType::Stop),
        "Stop should record the originating event in state_source"
    );

    let mut restart = event_base(HookEventType::SessionStart);
    restart.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let outcome = state.apply_hook_event(restart);
    assert!(
        outcome.ok,
        "SessionStart should be accepted after definitive stop idle"
    );

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Ready,
        "SessionStart after Stop-ready should produce Ready"
    );
}

#[test]
/// TaskCompleted is a vetoable intent, so it should preserve the current state.
fn session_start_after_task_completed_idle_produces_ready() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut completed = event_base(HookEventType::TaskCompleted);
    completed.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(completed);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "TaskCompleted should preserve the current state"
    );

    let mut restart = event_base(HookEventType::SessionStart);
    restart.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let outcome = state.apply_hook_event(restart);
    assert!(
        outcome.ok,
        "SessionStart should be accepted after task completion preserves working state"
    );

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(
        session.state,
        SessionState::Working,
        "SessionStart after TaskCompleted-preserved-working should remain Working"
    );
}

#[test]
fn stop_event_does_not_update_last_activity_at() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
    let activity_before = state
        .sessions
        .get("session-1")
        .and_then(|s| s.last_activity_at.clone());

    let mut stop = event_base(HookEventType::Stop);
    stop.stop_hook_active = Some(false);
    stop.recorded_at = "2099-01-31T00:00:10Z".to_string();
    let _ = state.apply_hook_event(stop);

    let activity_after = state
        .sessions
        .get("session-1")
        .and_then(|s| s.last_activity_at.clone());
    assert_eq!(
        activity_before, activity_after,
        "Stop should not update last_activity_at"
    );
}

#[test]
fn session_alive_via_recent_last_activity_at() {
    let now = chrono::DateTime::parse_from_rfc3339("2020-01-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            last_activity_at: Some((now - Duration::seconds(60)).to_rfc3339()),
            ..session_summary_fixture(
                "session-1",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &(now - Duration::seconds(60)).to_rfc3339(),
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);
    assert!(
        state.sessions.get("session-1").expect("session").is_alive,
        "Session with recent last_activity_at should be alive"
    );
}

#[test]
fn session_not_alive_when_last_activity_stale() {
    let now = chrono::DateTime::parse_from_rfc3339("2020-01-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            last_activity_at: Some((now - Duration::minutes(5)).to_rfc3339()),
            ..session_summary_fixture(
                "session-1",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &(now - Duration::minutes(5)).to_rfc3339(),
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);
    assert!(
        !state.sessions.get("session-1").expect("session").is_alive,
        "Session with stale last_activity_at (5min > 180s) should not be alive"
    );
}

#[test]
fn session_not_alive_after_definitive_session_end() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    end.pid = Some(std::process::id());
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();
    let _ = state.apply_hook_event(end);

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.state, SessionState::Idle);
    assert!(
        !session.is_alive,
        "Idle session from definitive SessionEnd should not be alive"
    );
}

/// A sole active session without shell corroboration that is well beyond the
/// dead-session grace period should transition to Idle instead of disappearing.
#[test]
fn snapshot_gc_transitions_sole_dead_session_to_idle() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(30)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            session_id: "dead-waiting".to_string(),
            pid: 0,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Waiting,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(stale_ts.clone()),
            terminated_at: None,
            tools_in_flight: 1,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    assert_eq!(state.sessions.len(), 1);

    state.gc_stale_sessions_at(now);

    let session = state
        .sessions
        .get("dead-waiting")
        .expect("session preserved");
    assert_eq!(state.sessions.len(), 1, "Project card should be preserved");
    assert_eq!(
        session.state,
        SessionState::Idle,
        "Conclusively dead sole session should become Idle"
    );
    assert_eq!(
        session.state_changed_at,
        now.to_rfc3339(),
        "Idle transition should be timestamped at GC time"
    );
}

#[test]
fn classify_signal_covers_all_event_types() {
    use super::classify_signal;
    assert_eq!(
        classify_signal(HookEventType::SessionEnd),
        SignalAuthority::DefinitiveTerminal
    );
    assert_eq!(
        classify_signal(HookEventType::SessionStart),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::PreToolUse),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::PostToolUse),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::PostToolUseFailure),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::UserPromptSubmit),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::PermissionRequest),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::SubagentStart),
        SignalAuthority::DefinitiveTransient
    );
    assert_eq!(
        classify_signal(HookEventType::Stop),
        SignalAuthority::AmbiguousPerTurn
    );
    assert_eq!(
        classify_signal(HookEventType::TaskCompleted),
        SignalAuthority::AmbiguousPerTurn
    );
    assert_eq!(
        classify_signal(HookEventType::SubagentStop),
        SignalAuthority::AmbiguousPerTurn
    );
    assert_eq!(
        classify_signal(HookEventType::Notification),
        SignalAuthority::MetaAwaitingInput
    );
    assert_eq!(
        classify_signal(HookEventType::PreCompact),
        SignalAuthority::Inferential
    );
    assert_eq!(
        classify_signal(HookEventType::TeammateIdle),
        SignalAuthority::Inferential
    );
    assert_eq!(
        classify_signal(HookEventType::WorktreeCreate),
        SignalAuthority::Inferential
    );
    assert_eq!(
        classify_signal(HookEventType::WorktreeRemove),
        SignalAuthority::Inferential
    );
    assert_eq!(
        classify_signal(HookEventType::ConfigChange),
        SignalAuthority::Inferential
    );
    assert_eq!(
        classify_signal(HookEventType::Unknown),
        SignalAuthority::Inferential
    );
}

mod authority_matrix_contract_tests {
    use super::super::classify_signal;
    use super::super::session::AUTHORITY_MATRIX;
    use super::*;

    /// The full list of HookEventType variants. MUST be updated in lockstep
    /// with the enum. The covers-every-variant test ensures this stays in sync.
    const ALL_HOOK_EVENT_TYPES: &[HookEventType] = &[
        HookEventType::SessionStart,
        HookEventType::UserPromptSubmit,
        HookEventType::PreToolUse,
        HookEventType::PostToolUse,
        HookEventType::PostToolUseFailure,
        HookEventType::PermissionRequest,
        HookEventType::PreCompact,
        HookEventType::Notification,
        HookEventType::SubagentStart,
        HookEventType::SubagentStop,
        HookEventType::Stop,
        HookEventType::TeammateIdle,
        HookEventType::TaskCompleted,
        HookEventType::WorktreeCreate,
        HookEventType::WorktreeRemove,
        HookEventType::ConfigChange,
        HookEventType::TranscriptActivity,
        HookEventType::SessionEnd,
        HookEventType::Unknown,
    ];

    const ALL_SIGNAL_AUTHORITIES: &[SignalAuthority] = &[
        SignalAuthority::DefinitiveTerminal,
        SignalAuthority::DefinitiveTransient,
        SignalAuthority::AmbiguousPerTurn,
        SignalAuthority::MetaAwaitingInput,
        SignalAuthority::Inferential,
    ];

    fn apply_events(events: Vec<IngestHookEventCommand>) -> ReducerState {
        let mut state = ReducerState::default();
        for event in events {
            let outcome = state.apply_hook_event(event.clone());
            assert!(outcome.ok, "{event:?} should be accepted: {outcome:?}");
        }
        state
    }

    fn session(state: &ReducerState) -> &SessionSummary {
        state
            .sessions
            .get("session-1")
            .expect("session should exist")
    }

    fn representative_event(
        authority: SignalAuthority,
        recorded_at: &str,
    ) -> Vec<IngestHookEventCommand> {
        match authority {
            SignalAuthority::DefinitiveTerminal => {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();

                let mut end = event_base(HookEventType::SessionEnd);
                end.recorded_at = recorded_at.to_string();
                vec![prompt, end]
            }
            SignalAuthority::DefinitiveTransient => {
                let mut event = event_base(HookEventType::PreToolUse);
                event.recorded_at = recorded_at.to_string();
                vec![event]
            }
            SignalAuthority::AmbiguousPerTurn => {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();

                let mut stop = event_base(HookEventType::Stop);
                stop.recorded_at = recorded_at.to_string();
                stop.stop_hook_active = Some(false);
                vec![prompt, stop]
            }
            SignalAuthority::MetaAwaitingInput => {
                let mut notification = event_base(HookEventType::Notification);
                notification.recorded_at = recorded_at.to_string();
                notification.notification_type = Some("idle_prompt".to_string());
                vec![notification]
            }
            SignalAuthority::Inferential => {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();

                let mut worktree = event_base(HookEventType::WorktreeCreate);
                worktree.recorded_at = recorded_at.to_string();
                vec![prompt, worktree]
            }
        }
    }

    #[test]
    fn test_authority_matrix_covers_every_hook_event_type_exactly_once() {
        for variant in ALL_HOOK_EVENT_TYPES {
            let count = AUTHORITY_MATRIX
                .iter()
                .filter(|(kind, _)| kind == variant)
                .count();
            assert_eq!(
                count, 1,
                "HookEventType::{variant:?} appears {count} times in AUTHORITY_MATRIX (expected exactly 1)"
            );
        }
        assert_eq!(
            AUTHORITY_MATRIX.len(),
            ALL_HOOK_EVENT_TYPES.len(),
            "AUTHORITY_MATRIX length ({}) diverged from ALL_HOOK_EVENT_TYPES length ({})",
            AUTHORITY_MATRIX.len(),
            ALL_HOOK_EVENT_TYPES.len(),
        );
    }

    #[test]
    fn test_classify_signal_agrees_with_authority_matrix_for_every_variant() {
        for variant in ALL_HOOK_EVENT_TYPES {
            let via_function = classify_signal(*variant);
            let via_table = AUTHORITY_MATRIX
                .iter()
                .find_map(|(kind, authority)| {
                    if kind == variant {
                        Some(*authority)
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| panic!("{variant:?} absent from AUTHORITY_MATRIX"));
            assert_eq!(
                via_function, via_table,
                "classify_signal({variant:?}) returned {via_function:?} but table says {via_table:?}",
            );
        }
    }

    #[test]
    fn test_every_signal_authority_tier_has_at_least_one_mapped_event() {
        for tier in ALL_SIGNAL_AUTHORITIES {
            let any = AUTHORITY_MATRIX
                .iter()
                .any(|(_, authority)| authority == tier);
            assert!(any, "SignalAuthority::{tier:?} has no mapped HookEventType");
        }
    }

    #[test]
    fn test_authority_recorded_as_definitive_terminal_for_session_end() {
        let state = apply_events(representative_event(
            SignalAuthority::DefinitiveTerminal,
            "2099-01-31T00:00:05Z",
        ));

        let source = session(&state).state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::SessionEnd);
        assert_eq!(source.authority, SignalAuthority::DefinitiveTerminal);
    }

    #[test]
    fn test_authority_recorded_as_definitive_transient_for_pre_tool_use() {
        let state = apply_events(representative_event(
            SignalAuthority::DefinitiveTransient,
            "2099-01-31T00:00:05Z",
        ));

        let source = session(&state).state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::PreToolUse);
        assert_eq!(source.authority, SignalAuthority::DefinitiveTransient);
    }

    #[test]
    fn test_authority_recorded_as_ambiguous_per_turn_for_stop() {
        let state = apply_events(representative_event(
            SignalAuthority::AmbiguousPerTurn,
            "2099-01-31T00:00:05Z",
        ));

        let source = session(&state).state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::Stop);
        assert_eq!(source.authority, SignalAuthority::AmbiguousPerTurn);
    }

    #[test]
    fn test_authority_recorded_as_meta_awaiting_input_for_notification() {
        let state = apply_events(representative_event(
            SignalAuthority::MetaAwaitingInput,
            "2099-01-31T00:00:10Z",
        ));

        let source = session(&state).state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::Notification);
        assert_eq!(source.authority, SignalAuthority::MetaAwaitingInput);
    }

    #[test]
    fn test_authority_recorded_as_inferential_for_worktree_create() {
        let state = apply_events(representative_event(
            SignalAuthority::Inferential,
            "2099-01-31T00:00:05Z",
        ));

        let source = session(&state).state_source.as_ref().expect("state_source");
        assert_eq!(source.event_kind, HookEventType::WorktreeCreate);
        assert_eq!(source.authority, SignalAuthority::Inferential);
    }

    #[test]
    fn test_last_authoritative_event_at_not_bumped_by_ambiguous_per_turn() {
        let state = apply_events(vec![
            {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();
                prompt
            },
            {
                let mut end = event_base(HookEventType::SessionEnd);
                end.recorded_at = "2099-01-31T00:00:10Z".to_string();
                end
            },
            {
                let mut stop = event_base(HookEventType::Stop);
                stop.recorded_at = "2099-01-31T00:00:20Z".to_string();
                stop.stop_hook_active = Some(false);
                stop
            },
        ]);

        assert_eq!(
            session(&state).last_authoritative_event_at.as_deref(),
            Some("2099-01-31T00:00:10Z")
        );
    }

    #[test]
    fn test_definitive_terminal_blocks_meta_awaiting_input_override() {
        let state = apply_events(vec![
            {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();
                prompt
            },
            {
                let mut end = event_base(HookEventType::SessionEnd);
                end.recorded_at = "2099-01-31T00:00:10Z".to_string();
                end
            },
            {
                let mut notification = event_base(HookEventType::Notification);
                notification.recorded_at = "2099-01-31T00:00:30Z".to_string();
                notification.notification_type = Some("idle_prompt".to_string());
                notification
            },
        ]);

        let current = session(&state);
        assert_eq!(current.state, SessionState::Idle);
        assert_eq!(
            current
                .state_source
                .as_ref()
                .expect("state_source")
                .event_kind,
            HookEventType::SessionEnd
        );
    }

    #[test]
    fn test_definitive_transient_upgrades_from_inferential() {
        let state = apply_events(vec![
            {
                let mut prompt = event_base(HookEventType::UserPromptSubmit);
                prompt.recorded_at = "2099-01-31T00:00:00Z".to_string();
                prompt
            },
            {
                let mut worktree = event_base(HookEventType::WorktreeCreate);
                worktree.recorded_at = "2099-01-31T00:00:05Z".to_string();
                worktree
            },
            {
                let mut pre_tool = event_base(HookEventType::PreToolUse);
                pre_tool.recorded_at = "2099-01-31T00:00:10Z".to_string();
                pre_tool
            },
        ]);

        let current = session(&state);
        let source = current.state_source.as_ref().expect("state_source");
        assert_eq!(current.state, SessionState::Working);
        assert_eq!(source.authority, SignalAuthority::DefinitiveTransient);
        assert_eq!(source.event_kind, HookEventType::PreToolUse);
    }

    #[test]
    fn test_authority_hierarchy_transitive_ordering() {
        let ordered_pairs = [
            (
                SignalAuthority::DefinitiveTerminal,
                SignalAuthority::DefinitiveTransient,
            ),
            (
                SignalAuthority::DefinitiveTerminal,
                SignalAuthority::AmbiguousPerTurn,
            ),
            (
                SignalAuthority::DefinitiveTerminal,
                SignalAuthority::MetaAwaitingInput,
            ),
            (
                SignalAuthority::DefinitiveTerminal,
                SignalAuthority::Inferential,
            ),
            (
                SignalAuthority::DefinitiveTransient,
                SignalAuthority::AmbiguousPerTurn,
            ),
            (
                SignalAuthority::DefinitiveTransient,
                SignalAuthority::MetaAwaitingInput,
            ),
            (
                SignalAuthority::DefinitiveTransient,
                SignalAuthority::Inferential,
            ),
            (
                SignalAuthority::AmbiguousPerTurn,
                SignalAuthority::MetaAwaitingInput,
            ),
            (
                SignalAuthority::AmbiguousPerTurn,
                SignalAuthority::Inferential,
            ),
            (
                SignalAuthority::MetaAwaitingInput,
                SignalAuthority::Inferential,
            ),
        ];

        for (index, (higher, lower)) in ordered_pairs.into_iter().enumerate() {
            let higher_recorded_at = format!("2099-01-31T00:00:{:02}Z", index * 2);
            let lower_recorded_at = format!("2099-01-31T00:00:{:02}Z", index * 2 + 1);

            let higher_events = representative_event(higher, &higher_recorded_at);
            let higher_kind = higher_events
                .last()
                .expect("higher event exists")
                .event_type;
            let lower_events = representative_event(lower, &lower_recorded_at);

            let state = apply_events(higher_events.into_iter().chain(lower_events).collect());
            let source = session(&state).state_source.as_ref().expect("state_source");

            assert_eq!(
                source.authority, higher,
                "higher authority {higher:?} should survive lower authority {lower:?}"
            );
            assert_eq!(
                source.event_kind, higher_kind,
                "higher event kind should be retained when {higher:?} precedes {lower:?}"
            );
        }
    }
}

/// A sole dead session (pid=0) that is only recently stale must survive —
/// the tool call might still be in progress.
#[test]
fn snapshot_gc_preserves_recently_dead_sole_session() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let recent_ts = (now - Duration::minutes(9)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            session_id: "recent-waiting".to_string(),
            pid: 0,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Waiting,
            state_changed_at: recent_ts.clone(),
            updated_at: recent_ts.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(recent_ts.clone()),
            terminated_at: None,
            tools_in_flight: 1,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Recently dead sole session should survive within the 10-minute grace period"
    );
}

/// A sole Idle session with pid=0 must never be evicted — Idle is a terminal
/// state representing a terminal window the user may return to.
#[test]
fn snapshot_gc_preserves_sole_idle_session_even_with_pid_zero() {
    let now = Utc::now();
    let stale_ts = (now - Duration::hours(2)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "idle-pid-zero",
            0,
            "/repo",
            "/repo",
            SessionState::Idle,
            &stale_ts,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Sole Idle session must never be evicted, even with pid=0"
    );
}

#[test]
fn gc_removes_idle_sessions_past_retention() {
    let now = Utc::now();
    let stale_ts = (now - Duration::hours(25)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            state: SessionState::Idle,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_activity_at: Some(stale_ts.clone()),
            ..session_summary_fixture(
                "idle-session",
                10,
                "/repo",
                "/repo",
                SessionState::Idle,
                &stale_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        0,
        "Idle session beyond retention window should be removed"
    );
}

#[test]
fn gc_retains_recent_idle_sessions() {
    let now = Utc::now();
    let fresh_ts = (now - Duration::hours(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            state: SessionState::Idle,
            state_changed_at: fresh_ts.clone(),
            updated_at: fresh_ts.clone(),
            last_activity_at: Some(fresh_ts.clone()),
            ..session_summary_fixture(
                "idle-session",
                10,
                "/repo",
                "/repo",
                SessionState::Idle,
                &fresh_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(now);

    assert_eq!(
        state.sessions.len(),
        1,
        "Recent Idle session should remain in retention window"
    );
    assert_eq!(
        state
            .sessions
            .get("idle-session")
            .expect("session retained")
            .state,
        SessionState::Idle
    );
}

#[test]
fn test_gc_returns_true_on_change() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(30)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            pid: 0,
            state: SessionState::Waiting,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(stale_ts.clone()),
            tools_in_flight: 1,
            ..session_summary_fixture(
                "dead-waiting",
                0,
                "/repo",
                "/repo",
                SessionState::Waiting,
                &stale_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let changed = state.gc_stale_sessions_at(now);

    assert!(changed, "expected GC to report a state change");
}

#[test]
fn test_gc_returns_false_on_no_change() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let fresh_ts = (now - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "fresh-working",
            10,
            "/repo",
            "/repo",
            SessionState::Working,
            &fresh_ts,
        )],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let changed = state.gc_stale_sessions_at(now);

    assert!(!changed, "fresh sessions should not trigger a GC change");
}

#[test]
fn test_gc_reason_set_on_idle_transition() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(30)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            pid: 0,
            state: SessionState::Waiting,
            state_changed_at: stale_ts.clone(),
            updated_at: stale_ts.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(stale_ts.clone()),
            tools_in_flight: 1,
            ..session_summary_fixture(
                "dead-waiting",
                0,
                "/repo",
                "/repo",
                SessionState::Waiting,
                &stale_ts,
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let changed = state.gc_stale_sessions_at(now);
    assert!(changed, "expected GC to transition the session");

    let session = state
        .sessions
        .get("dead-waiting")
        .expect("session preserved");
    assert_eq!(session.state, SessionState::Idle);
    assert_eq!(session.gc_reason.as_deref(), Some("signal_absence"));
}

#[test]
fn test_gc_reason_cleared_on_hook_event() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            gc_reason: Some("signal_absence".to_string()),
            ..session_summary_fixture(
                "session-1",
                0,
                "/repo",
                "/repo",
                SessionState::Idle,
                "2099-04-01T11:30:00Z",
            )
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: "2099-04-01T12:00:00Z".to_string(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let mut event = event_base(HookEventType::UserPromptSubmit);
    event.recorded_at = "2099-04-01T12:00:00Z".to_string();

    let outcome = state.apply_hook_event(event);
    assert!(outcome.ok, "{outcome:?}");

    let session = state.sessions.get("session-1").expect("session");
    assert_eq!(session.gc_reason, None);
}

#[test]
fn test_gc_transitions_stale_to_idle_with_gc_reason() {
    // The new GC transitions stale non-Idle sessions to Idle (rather than
    // removing them), and sets gc_reason = "signal_absence" on transitioned
    // sessions. The idle survivor's gc_reason remains None.
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();
    let fresh_ts = (now - Duration::minutes(1)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "stale-worker",
                10,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            session_summary_fixture(
                "idle-survivor",
                20,
                "/repo",
                "/repo",
                SessionState::Idle,
                &fresh_ts,
            ),
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    });

    let changed = state.gc_stale_sessions_at(now);
    assert!(changed, "expected GC to transition the stale session");

    let stale = state
        .sessions
        .get("stale-worker")
        .expect("stale session preserved as Idle");
    assert_eq!(stale.state, SessionState::Idle);
    assert_eq!(stale.gc_reason.as_deref(), Some("signal_absence"));

    let survivor = state.sessions.get("idle-survivor").expect("idle survivor");
    assert_eq!(
        survivor.gc_reason, None,
        "Idle survivor should not gain a gc_reason"
    );
}

mod transcript_discovery_contract_tests {
    use super::*;
    use crate::observation::transcript::TranscriptDiscovery;
    use std::path::PathBuf;

    fn discovery(session_id: &str, project_path: &str, mtime: &str) -> TranscriptDiscovery {
        TranscriptDiscovery {
            session_id: session_id.to_string(),
            project_path: project_path.to_string(),
            file_path: PathBuf::from(format!("/fake/{session_id}.jsonl")),
            file_mtime_rfc3339: mtime.to_string(),
            file_size_bytes: 1024,
        }
    }

    #[test]
    fn transcript_discovery_creates_session_when_absent() {
        let mut state = ReducerState::default();
        let outcome =
            state.apply_transcript_discovery(discovery("sess-1", "/repo", "2099-01-01T00:00:00Z"));

        assert!(outcome.ok);
        assert_eq!(outcome.message, "transcript_discovery_applied");

        let session = state.sessions.get("sess-1").expect("session created");
        assert_eq!(session.state, SessionState::Idle);
        assert_eq!(session.project_path, "/repo");
        let source = session.state_source.as_ref().expect("has state_source");
        assert_eq!(source.event_kind, HookEventType::TranscriptActivity);
        assert_eq!(source.authority, SignalAuthority::Inferential);
    }

    #[test]
    fn transcript_discovery_skips_when_hook_state_exists() {
        let mut state = ReducerState::default();
        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let outcome = state.apply_transcript_discovery(discovery(
            "session-1",
            "/repo",
            "2099-01-01T00:00:00Z",
        ));

        assert!(outcome.ok);
        assert_eq!(
            outcome.message,
            "transcript_discovery_skipped_higher_authority"
        );
        let session = state.sessions.get("session-1").expect("session exists");
        assert_eq!(session.state, SessionState::Working);
        let source = session.state_source.as_ref().expect("has state_source");
        assert_eq!(
            source.authority,
            SignalAuthority::DefinitiveTransient,
            "hook authority preserved"
        );
    }

    #[test]
    fn transcript_discovery_updates_inferential_session() {
        let mut state = ReducerState::default();
        let _ =
            state.apply_transcript_discovery(discovery("sess-1", "/repo", "2099-01-01T00:00:00Z"));
        let _ =
            state.apply_transcript_discovery(discovery("sess-1", "/repo", "2099-01-01T01:00:00Z"));

        let session = state.sessions.get("sess-1").expect("session exists");
        assert_eq!(session.updated_at, "2099-01-01T01:00:00Z");
        assert_eq!(
            session.last_activity_at.as_deref(),
            Some("2099-01-01T01:00:00Z")
        );
    }

    #[test]
    fn hook_event_upgrades_transcript_created_session() {
        let mut state = ReducerState::default();
        let _ = state.apply_transcript_discovery(discovery(
            "session-1",
            "/repo",
            "2099-01-01T00:00:00Z",
        ));

        let session = state.sessions.get("session-1").expect("transcript session");
        assert_eq!(
            session.state_source.as_ref().unwrap().authority,
            SignalAuthority::Inferential
        );

        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let session = state.sessions.get("session-1").expect("upgraded session");
        assert_eq!(session.state, SessionState::Working);
        let source = session.state_source.as_ref().expect("has state_source");
        assert_eq!(
            source.authority,
            SignalAuthority::DefinitiveTransient,
            "hook upgrades authority from Inferential"
        );
    }

    #[test]
    fn transcript_discovery_after_session_end_is_skipped() {
        let mut state = ReducerState::default();
        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));
        let mut end = event_base(HookEventType::SessionEnd);
        end.recorded_at = "2099-01-31T00:00:05Z".to_string();
        let _ = state.apply_hook_event(end);

        let outcome = state.apply_transcript_discovery(discovery(
            "session-1",
            "/repo",
            "2099-01-31T00:00:10Z",
        ));

        assert!(outcome.ok);
        assert_eq!(
            outcome.message,
            "transcript_discovery_skipped_higher_authority"
        );
        let session = state.sessions.get("session-1").expect("session exists");
        assert_eq!(
            session.state_source.as_ref().unwrap().authority,
            SignalAuthority::DefinitiveTerminal,
            "terminal authority not overridden by transcript"
        );
    }
}
