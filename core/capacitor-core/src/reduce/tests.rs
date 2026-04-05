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
        tools_in_flight: 0,
        ready_reason: None,
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
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|session| session.ready_reason.as_deref()),
        None
    );
}

#[test]
fn test_idle_prompt_no_tools_still_ready() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut notification = event_base(HookEventType::Notification);
    notification.notification_type = Some("idle_prompt".to_string());
    notification.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let applied = state.apply_hook_event(notification);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
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
    second_idle.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let applied = state.apply_hook_event(second_idle);
    assert!(applied.ok);
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Ready)
    );
    assert_eq!(
        state
            .sessions
            .get("session-1")
            .and_then(|session| session.ready_reason.as_deref()),
        Some("idle_prompt")
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
fn subagent_stop_skips_when_working_with_no_tools_in_flight() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

    let mut post = event_base(HookEventType::PostToolUse);
    post.event_id = "evt-2".to_string();
    post.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let _ = state.apply_hook_event(post);

    // Capture updated_at after PostToolUse — SubagentStop should not refresh it.
    let updated_at_before = state
        .sessions
        .get("session-1")
        .map(|s| s.updated_at.clone())
        .unwrap();

    let mut stop = event_base(HookEventType::SubagentStop);
    stop.event_id = "evt-3".to_string();
    stop.recorded_at = "2099-01-31T00:00:02Z".to_string();

    let outcome = state.apply_hook_event(stop);

    // Skip: preserves Working without refreshing the staleness clock.
    assert_eq!(
        outcome.message,
        "event skipped: subagent_stop_working_no_tools"
    );
    assert_eq!(
        state.sessions.get("session-1").map(|session| session.state),
        Some(SessionState::Working)
    );
    // updated_at must NOT have been refreshed.
    let updated_at_after = state
        .sessions
        .get("session-1")
        .map(|s| s.updated_at.clone())
        .unwrap();
    assert_eq!(updated_at_before, updated_at_after);
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

    // Capture timestamp — final SubagentStop should Skip and not refresh it.
    let updated_at_before = state
        .sessions
        .get("session-1")
        .map(|s| s.updated_at.clone())
        .unwrap();

    let mut final_stop = event_base(HookEventType::SubagentStop);
    final_stop.event_id = "evt-6".to_string();
    final_stop.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(final_stop);

    // Last agent: tools_in_flight == 0, so Skip (don't refresh staleness clock).
    assert_eq!(
        outcome.message,
        "event skipped: subagent_stop_working_no_tools"
    );
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
    assert_eq!(updated_at_before, updated_at_after);
}

#[test]
fn subagent_stop_skips_when_session_is_ready() {
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
fn reducer_parent_stop_transitions_to_ready() {
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
        state
            .sessions
            .get("session-1")
            .and_then(|session| session.ready_reason.as_deref()),
        Some("stop_gate")
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
fn session_end_with_live_pid_transitions_to_ready() {
    let mut state = ReducerState::default();
    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut end = event_base(HookEventType::SessionEnd);
    // Use the current process PID so is_pid_alive returns true
    end.pid = Some(std::process::id());
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();

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
    end.recorded_at = "2099-01-31T00:00:05Z".to_string();

    let outcome = state.apply_hook_event(end);
    assert!(outcome.ok);
    assert!(!state.sessions.contains_key("session-1"));
}

#[test]
fn test_is_pid_alive_zero_returns_true() {
    assert!(super::pid_alive_from_probe_result(0, None));
}

#[test]
fn test_is_pid_alive_eperm_returns_true() {
    assert!(super::pid_alive_from_probe_result(-1, Some(libc::EPERM)));
}

#[test]
fn test_is_pid_alive_esrch_returns_false() {
    assert!(!super::pid_alive_from_probe_result(-1, Some(libc::ESRCH)));
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
fn test_informational_events_have_distinct_skip_reasons() {
    let mut state = ReducerState::default();

    let cases = [
        (
            HookEventType::TeammateIdle,
            "event skipped: teammate_idle_informational",
        ),
        (
            HookEventType::WorktreeCreate,
            "event skipped: worktree_create_informational",
        ),
        (
            HookEventType::WorktreeRemove,
            "event skipped: worktree_remove_informational",
        ),
        (
            HookEventType::ConfigChange,
            "event skipped: config_change_informational",
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
            expected_skip_reason: Some("subagent_stop_working_no_tools"),
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
            expected_state: Some(SessionState::Ready),
            expected_skip_reason: None,
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
            expected_state: None,
            expected_skip_reason: Some("worktree_create_informational"),
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
            expected_state: None,
            expected_skip_reason: Some("config_change_informational"),
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

    // SessionEnd is intentionally covered by the dedicated PID-sensitive tests:
    // `session_end_with_live_pid_transitions_to_ready` and
    // `session_end_with_dead_pid_deletes_session`.
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

                let expected_ready_reason = match expectation.description {
                    "notification (idle_prompt)" => Some("idle_prompt"),
                    "notification (auth_success)" => Some("auth_success"),
                    "stop (parent session)" => Some("stop_gate"),
                    "task_completed (parent)" => Some("task_completed"),
                    _ => None,
                };
                assert_eq!(
                    session.ready_reason.as_deref(),
                    expected_ready_reason,
                    "{} should have the expected ready_reason semantics",
                    expectation.description
                );

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
    assert_eq!(session.ready_reason, None);
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
    assert_eq!(session.ready_reason, None);
}

#[test]
fn test_task_completed_parent_session_transitions_to_ready() {
    let mut state = ReducerState::default();

    let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

    let mut task_completed = event_base(HookEventType::TaskCompleted);
    task_completed.recorded_at = "2099-01-31T00:00:01Z".to_string();

    let outcome = state.apply_hook_event(task_completed);
    assert!(outcome.ok);
    assert_eq!(outcome.message, "event ingested");

    let session = state
        .sessions
        .get("session-1")
        .expect("session should exist");
    assert_eq!(session.state, SessionState::Ready);
    assert_eq!(session.ready_reason.as_deref(), Some("task_completed"));
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

    shells.insert(
        1000,
        ShellSignal {
            updated_at: (now - Duration::minutes(11)).to_rfc3339(),
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
                updated_at: (now - Duration::minutes(11)).to_rfc3339(),
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
fn snapshot_populates_session_is_alive_from_cleaned_shells() {
    // Use a past timestamp so the hook-activity fallback (60s) does not interfere.
    let now = chrono::DateTime::parse_from_rfc3339("2020-01-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            session_summary_fixture(
                "live-session",
                11,
                "/repo-a",
                "/repo-a",
                SessionState::Idle,
                &(now - Duration::minutes(1)).to_rfc3339(),
            ),
            session_summary_fixture(
                "dead-session",
                22,
                "/repo-b",
                "/repo-b",
                SessionState::Idle,
                &(now - Duration::minutes(1)).to_rfc3339(),
            ),
        ],
        shells: vec![
            ShellSignal {
                updated_at: (now - Duration::minutes(1)).to_rfc3339(),
                ..shell_signal_fixture(11, "/repo-a")
            },
            ShellSignal {
                updated_at: (now - Duration::minutes(11)).to_rfc3339(),
                ..shell_signal_fixture(22, "/repo-b")
            },
        ],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
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

    state.gc_stale_sessions_at(now);

    assert!(
        state
            .sessions
            .get("live-session")
            .is_some_and(|session| session.is_alive),
        "GC should mark shell-corroborated sessions as alive"
    );
    assert!(
        state
            .sessions
            .get("dead-session")
            .is_some_and(|session| !session.is_alive),
        "Expired shell corroboration should not survive GC"
    );
}

#[test]
fn session_is_alive_via_shell_cwd_matching() {
    // Use a controlled `now` and test via gc_stale_sessions_at (which accepts
    // explicit time) rather than snapshot() (which uses Utc::now()).
    // Session updated_at is 1 minute before `now` — outside the 60s hook-activity
    // fallback — so only CWD matching determines is_alive.
    fn gc_is_alive(shell_cwd: &str) -> bool {
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
                &(now - Duration::minutes(2)).to_rfc3339(),
            )],
            vec![],
        );

        let outcome = state.apply_shell_signal(IngestShellSignalCommand {
            pid: 4242,
            cwd: shell_cwd.to_string(),
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
        state.sessions.get("session-1").expect("session").is_alive
    }

    assert!(
        gc_is_alive("/users/pete/code/myproject"),
        "Shell at project root should mark the session alive"
    );
    assert!(
        gc_is_alive("/users/pete/code/myproject/src"),
        "Shell inside a project subdirectory should still mark the session alive"
    );
    assert!(
        !gc_is_alive("/users/pete/code/other"),
        "Unrelated shell cwd should not mark the session alive"
    );
    assert!(
        gc_is_alive("/users/pete/code"),
        "Shell at ancestor of project path should mark session alive"
    );
    assert!(
        !gc_is_alive("/users/pete/code/myproject-v2"),
        "Shell at sibling with shared prefix should not falsely match"
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
fn orphaned_session_gc_uses_stop_timestamp_before_evicting_stale_ready_session() {
    let mut state = ReducerState::default();

    let mut old_work = event_base(HookEventType::UserPromptSubmit);
    old_work.session_id = "old-session".to_string();
    old_work.pid = Some(11);
    old_work.recorded_at = "2099-03-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(old_work);
    assert!(outcome.ok, "{outcome:?}");

    let mut old_stop = event_base(HookEventType::Stop);
    old_stop.session_id = "old-session".to_string();
    old_stop.pid = Some(11);
    old_stop.recorded_at = "2099-03-31T00:05:00Z".to_string();
    old_stop.stop_hook_active = Some(false);
    let outcome = state.apply_hook_event(old_stop);
    assert!(outcome.ok, "{outcome:?}");

    let old_ready = state
        .sessions
        .get("old-session")
        .expect("old ready session");
    assert_eq!(old_ready.state, SessionState::Ready);
    assert_eq!(old_ready.updated_at, "2099-03-31T00:05:00Z");
    assert_eq!(
        old_ready.last_activity_at.as_deref(),
        Some("2099-03-31T00:05:00Z")
    );

    let mut new_start = event_base(HookEventType::SessionStart);
    new_start.session_id = "new-session".to_string();
    new_start.pid = Some(22);
    new_start.recorded_at = "2099-03-31T00:09:59Z".to_string();
    let outcome = state.apply_hook_event(new_start);
    assert!(outcome.ok, "{outcome:?}");
    assert!(
        state.sessions.contains_key("old-session"),
        "ready sibling should survive until it is stale for more than five minutes from Stop"
    );

    let mut new_activity = event_base(HookEventType::UserPromptSubmit);
    new_activity.session_id = "new-session".to_string();
    new_activity.pid = Some(22);
    new_activity.recorded_at = "2099-03-31T00:10:01Z".to_string();
    let outcome = state.apply_hook_event(new_activity);

    assert!(outcome.ok, "{outcome:?}");
    assert!(!state.sessions.contains_key("old-session"));

    let project = state
        .snapshot()
        .projects
        .into_iter()
        .find(|project| project.project_path == "/repo")
        .expect("project");

    assert_eq!(project.state, SessionState::Working);
    assert_eq!(
        project.representative_session_id.as_deref(),
        Some("new-session")
    );
    assert_eq!(project.latest_session_id.as_deref(), Some("new-session"));
    assert_eq!(project.session_count, 1);
}

#[test]
fn orphaned_session_gc_uses_ready_transition_timestamp_for_task_completed() {
    let mut state = ReducerState::default();

    let mut old_work = event_base(HookEventType::UserPromptSubmit);
    old_work.session_id = "old-session".to_string();
    old_work.pid = Some(11);
    old_work.recorded_at = "2099-03-31T00:00:00Z".to_string();
    let outcome = state.apply_hook_event(old_work);
    assert!(outcome.ok, "{outcome:?}");

    let mut completed = event_base(HookEventType::TaskCompleted);
    completed.session_id = "old-session".to_string();
    completed.pid = Some(11);
    completed.recorded_at = "2099-03-31T00:05:00Z".to_string();
    let outcome = state.apply_hook_event(completed);
    assert!(outcome.ok, "{outcome:?}");

    let old_ready = state
        .sessions
        .get("old-session")
        .expect("old ready session");
    assert_eq!(old_ready.state, SessionState::Ready);
    assert_eq!(old_ready.state_changed_at, "2099-03-31T00:05:00Z");
    assert_eq!(
        old_ready.last_activity_at.as_deref(),
        Some("2099-03-31T00:00:00Z")
    );

    let mut new_start = event_base(HookEventType::SessionStart);
    new_start.session_id = "new-session".to_string();
    new_start.pid = Some(22);
    new_start.recorded_at = "2099-03-31T00:09:59Z".to_string();
    let outcome = state.apply_hook_event(new_start);
    assert!(outcome.ok, "{outcome:?}");
    assert!(
        state.sessions.contains_key("old-session"),
        "ready sibling should use the newer Ready-transition timestamp as its GC anchor"
    );

    let mut new_activity = event_base(HookEventType::UserPromptSubmit);
    new_activity.session_id = "new-session".to_string();
    new_activity.pid = Some(22);
    new_activity.recorded_at = "2099-03-31T00:10:01Z".to_string();
    let outcome = state.apply_hook_event(new_activity);
    assert!(outcome.ok, "{outcome:?}");
    assert!(!state.sessions.contains_key("old-session"));
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
    config_change.recorded_at = "2099-01-31T00:00:01Z".to_string();
    let outcome = state.apply_hook_event(config_change);
    assert!(outcome.message.contains("config_change_informational"));

    // 3) Another informational event to prove counting
    let mut worktree = event_base(HookEventType::WorktreeCreate);
    worktree.recorded_at = "2099-01-31T00:00:02Z".to_string();
    let outcome = state.apply_hook_event(worktree);
    assert!(outcome.message.contains("worktree_create_informational"));

    // 4) Idle prompt while tools are drifted in flight should self-correct
    let mut pre_tool = event_base(HookEventType::PreToolUse);
    pre_tool.recorded_at = "2099-01-31T00:00:03Z".to_string();
    let _ = state.apply_hook_event(pre_tool);

    let mut idle = event_base(HookEventType::Notification);
    idle.notification_type = Some("idle_prompt".to_string());
    idle.recorded_at = "2099-01-31T00:00:04Z".to_string();
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
fn snapshot_preserves_sole_stale_working_session() {
    // A sole stale Working session must NOT be evicted — it may be a legitimate
    // long-running worker (e.g., Codex) in a quiet period between hook events.
    // Only evict when a competing session exists for the same project.
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();

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
        "Sole stale working session must survive snapshot GC"
    );
    assert!(state.sessions.contains_key("stale-working"));
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
fn snapshot_preserves_sole_stale_ready_session() {
    // A sole stale Ready session must NOT be evicted — same reasoning as Working.
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
                "stale-ready",
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
        "Sole stale ready session must survive snapshot GC"
    );
    assert!(state.sessions.contains_key("stale-ready"));
}

#[test]
fn snapshot_gc_fixes_project_state_with_orphan_and_idle_session() {
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();
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

    assert_eq!(
        state.sessions.len(),
        1,
        "Only the idle session should survive"
    );
    assert!(state.sessions.contains_key("current-idle"));
    assert!(!state.sessions.contains_key("orphan-working"));

    let project = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project.state,
        SessionState::Idle,
        "Project state should be Idle after orphan eviction"
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
fn snapshot_gc_preserves_all_stale_sessions_when_no_survivor() {
    // Two Working sessions both stale — no survivor would remain if we evicted,
    // so the GC must keep both.  This prevents the bug where all legitimate
    // concurrent workers in a quiet period get wiped.
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();

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
        "Both stale sessions must survive when no survivor would remain"
    );
    assert!(state.sessions.contains_key("worker-a"));
    assert!(state.sessions.contains_key("worker-b"));

    let project = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo")
        .expect("project");
    assert_eq!(
        project.state,
        SessionState::Working,
        "Project should still show Working when both sessions are preserved"
    );
}

#[test]
fn snapshot_gc_evicts_stale_when_fresh_session_exists() {
    // Three sessions for /repo: A and B are stale Working, C is fresh Working.
    // C survives as the fresh survivor, so A and B should be evicted.
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();
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

    assert_eq!(
        state.sessions.len(),
        1,
        "Only the fresh session should survive"
    );
    assert!(!state.sessions.contains_key("stale-a"));
    assert!(!state.sessions.contains_key("stale-b"));
    assert!(state.sessions.contains_key("fresh-c"));

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

/// IMP-9: event-time GC does NOT evict Idle siblings.
///
/// When a Working session sends a new event, the event-time cleanup
/// (`cleanup_orphaned_same_project_sessions`) must preserve Idle siblings
/// even when they are stale (updated > 10 minutes ago).  Idle represents
/// a terminal window the user may return to, so it should never be
/// evicted by the shared `is_session_evictable` predicate.
#[test]
fn orphaned_session_gc_preserves_stale_idle_sibling() {
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

    // The Idle session must survive — it is exempt from eviction.
    assert!(
        state.sessions.contains_key("idle-session"),
        "Idle session should NOT be evicted regardless of staleness"
    );

    // The new session should exist.
    assert!(state.sessions.contains_key("new-session"));

    // The Working session was stale relative to the new event (12:00:00 vs
    // 12:00:01, but only 1 second apart — within grace), so it also survives.
    // If it didn't survive, the Idle assertion above is still the key check.
    // Let's verify the project state reflects all survivors.
    let project = state
        .snapshot()
        .projects
        .into_iter()
        .find(|p| p.project_path == "/repo")
        .expect("project");

    assert!(
        project.session_count >= 2,
        "At least the Idle and new sessions should remain, got {}",
        project.session_count
    );
}

#[test]
fn event_time_cleanup_uses_adjusted_gc_reference_time_when_provided() {
    let stale_anchor = "2099-04-01T12:00:00Z";
    let raw_recorded_at = "2099-04-01T12:06:00Z";
    let adjusted_gc_reference_time = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:04:00Z")
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
        "raw recorded_at should evict the stale sibling once it is 6 minutes old"
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
        "adjusted gc_reference_time should preserve the sibling because its effective age is 4 minutes"
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
    let stale_ts = (base - Duration::minutes(10)).to_rfc3339();
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

    // Stale sessions evicted in both projects.
    assert!(
        !state.sessions.contains_key("a-stale"),
        "/repo-a stale session should be evicted"
    );
    assert!(
        !state.sessions.contains_key("b-stale"),
        "/repo-b stale session should be evicted"
    );

    // Fresh sessions survive.
    assert!(
        state.sessions.contains_key("a-fresh"),
        "/repo-a fresh survivor must remain"
    );
    assert!(
        state.sessions.contains_key("b-fresh"),
        "/repo-b fresh survivor must remain"
    );

    assert_eq!(state.sessions.len(), 2, "Exactly 2 sessions should remain");

    // Each project has exactly 1 session.
    let project_a = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo-a")
        .expect("/repo-a project");
    assert_eq!(
        project_a.session_count, 1,
        "/repo-a should have exactly 1 session"
    );

    let project_b = state
        .projects
        .values()
        .find(|p| p.project_path == "/repo-b")
        .expect("/repo-b project");
    assert_eq!(
        project_b.session_count, 1,
        "/repo-b should have exactly 1 session"
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
///   A) `last_activity_at` fresh, `state_changed_at` stale — not evicted
///   B) `state_changed_at` fresh, `last_activity_at` stale — not evicted
///   C) Both stale — evicted
#[test]
fn snapshot_gc_ready_session_uses_correct_anchor() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-01-01T00:10:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(10)).to_rfc3339();
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
            tools_in_flight: 0,
            ready_reason: None,
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
            tools_in_flight: 0,
            ready_reason: None,
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
            tools_in_flight: 0,
            ready_reason: None,
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

        assert!(
            !state.sessions.contains_key("ready-c"),
            "Scenario C: Ready session with both timestamps stale should be evicted"
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

/// Shell-corroborated Working session survives snapshot-time GC.
///
/// A Working session that is past the grace period but has a matching
/// shell signal (proving the process is still alive) must NOT be evicted.
#[test]
fn shell_corroborated_working_session_survives_snapshot_gc() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(10)).to_rfc3339();
    let fresh_ts = base.to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // Working session: stale (updated 10 minutes ago)
            session_summary_fixture(
                "working-session",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            // Idle session: fresh survivor
            session_summary_fixture(
                "idle-session",
                22,
                "/repo",
                "/repo",
                SessionState::Idle,
                &fresh_ts,
            ),
        ],
        // Shell signal corroborates the Working session's PID
        shells: vec![ShellSignal {
            pid: 11,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys011".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            tmux_panes: vec![],
            updated_at: fresh_ts.clone(),
        }],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 1,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: fresh_ts,
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(base);

    assert_eq!(
        state.sessions.len(),
        2,
        "Shell-corroborated Working session must survive snapshot GC"
    );
    assert!(
        state.sessions.contains_key("working-session"),
        "Working session with shell signal must not be evicted"
    );
}

/// Working session WITHOUT shell signal is evicted at snapshot time
/// (preserves existing behavior for true orphans).
#[test]
fn working_session_without_shell_signal_evicted_at_snapshot() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let stale_ts = (base - Duration::minutes(10)).to_rfc3339();
    let fresh_ts = base.to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // Working session: stale, NO shell signal
            session_summary_fixture(
                "orphan-worker",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                &stale_ts,
            ),
            // Idle session: survivor
            session_summary_fixture(
                "idle-session",
                22,
                "/repo",
                "/repo",
                SessionState::Idle,
                &fresh_ts,
            ),
        ],
        shells: vec![], // No shell signals — no corroboration
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
        generated_at: fresh_ts,
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(base);

    assert_eq!(
        state.sessions.len(),
        1,
        "Working session without shell corroboration should be evicted"
    );
    assert!(
        state.sessions.contains_key("idle-session"),
        "Only the Idle survivor should remain"
    );
}

/// Shell-corroborated Working session survives event-time GC.
///
/// When a new session event arrives, the inline cleanup must also respect
/// shell corroboration for active siblings.
#[test]
fn shell_corroborated_working_session_survives_event_time_gc() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // Working session: stale but has shell signal
            session_summary_fixture(
                "live-worker",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                "2099-04-01T11:50:00Z",
            ),
        ],
        shells: vec![ShellSignal {
            pid: 11,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys011".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            tmux_panes: vec![],
            updated_at: "2099-04-01T12:00:00Z".to_string(),
        }],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 1,
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

    // New session start arrives — triggers event-time cleanup
    let mut event = event_base(HookEventType::SessionStart);
    event.session_id = "new-session".to_string();
    event.pid = Some(33);
    event.recorded_at = "2099-04-01T12:01:00Z".to_string();

    let outcome = state.apply_hook_event(event);
    assert!(outcome.ok, "{outcome:?}");

    assert!(
        state.sessions.contains_key("live-worker"),
        "Shell-corroborated Working session must survive event-time GC"
    );
    assert!(
        state.sessions.contains_key("new-session"),
        "New session must be created"
    );
}

/// Both a stale shell-corroborated Working session and a stale Idle session
/// survive — they are protected by different mechanisms (shell corroboration
/// vs. Idle immunity).
#[test]
fn quiet_live_worker_with_idle_sibling_both_survive() {
    let base = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let worker_ts = (base - Duration::minutes(7)).to_rfc3339();
    let idle_ts = (base - Duration::minutes(15)).to_rfc3339();
    let fresh_ts = base.to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![
            // Working session: stale, has shell signal
            session_summary_fixture(
                "quiet-worker",
                11,
                "/repo",
                "/repo",
                SessionState::Working,
                &worker_ts,
            ),
            // Idle session: stale too
            session_summary_fixture(
                "idle-terminal",
                22,
                "/repo",
                "/repo",
                SessionState::Idle,
                &idle_ts,
            ),
        ],
        shells: vec![ShellSignal {
            pid: 11,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys011".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            tmux_panes: vec![],
            updated_at: fresh_ts.clone(),
        }],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 1,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: fresh_ts,
        snapshot_version: 0,
        schema_version: 0,
    });

    state.gc_stale_sessions_at(base);

    assert_eq!(
        state.sessions.len(),
        2,
        "Both sessions should survive: Working (shell-corroborated) + Idle (always immune)"
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
            tools_in_flight: 1,
            ready_reason: None,
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

/// A sole active session with fresh shell corroboration should remain active
/// even when it is well beyond the grace period.
#[test]
fn snapshot_gc_preserves_sole_stale_working_session_with_shell_corroboration() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(30)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "stale-working-real-pid",
            42,
            "/repo",
            "/repo",
            SessionState::Working,
            &stale_ts,
        )],
        shells: vec![ShellSignal {
            pid: 42,
            updated_at: (now - Duration::minutes(1)).to_rfc3339(),
            ..shell_signal_fixture(42, "/repo")
        }],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 1,
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

    let session = state
        .sessions
        .get("stale-working-real-pid")
        .expect("shell-corroborated session");
    assert_eq!(
        state.sessions.len(),
        1,
        "Shell-corroborated session should remain"
    );
    assert_eq!(session.state, SessionState::Working);
}

/// A sole active session with only stale shell corroboration should lose that
/// protection before GC makes its eviction decision.
#[test]
fn snapshot_gc_transitions_sole_stale_working_session_after_shell_gc() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(30)).to_rfc3339();

    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![session_summary_fixture(
            "stale-worker",
            77,
            "/repo",
            "/repo",
            SessionState::Working,
            &stale_ts,
        )],
        shells: vec![ShellSignal {
            pid: 77,
            updated_at: (now - Duration::minutes(11)).to_rfc3339(),
            ..shell_signal_fixture(77, "/repo")
        }],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 1,
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

    let session = state
        .sessions
        .get("stale-worker")
        .expect("session preserved");
    assert_eq!(
        session.state,
        SessionState::Idle,
        "Expired shell corroboration should not protect a stale sole worker"
    );
    assert!(
        !state.shells.contains_key(&77),
        "GC should purge expired shell corroboration before evaluating sessions"
    );
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
            tools_in_flight: 1,
            ready_reason: None,
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
    assert_eq!(session.gc_reason.as_deref(), Some("sole_dead_no_shell"));
}

#[test]
fn test_gc_reason_cleared_on_hook_event() {
    let mut state = ReducerState::from_snapshot(AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            gc_reason: Some("sole_dead_no_shell".to_string()),
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
fn test_gc_reason_not_set_on_removal() {
    let now = chrono::DateTime::parse_from_rfc3339("2099-04-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let stale_ts = (now - Duration::minutes(10)).to_rfc3339();
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
    assert!(changed, "expected stale sibling eviction");

    assert!(
        !state.sessions.contains_key("stale-worker"),
        "GC should remove stale siblings rather than transitioning them"
    );
    assert!(
        state.sessions.contains_key("idle-survivor"),
        "survivor should remain after GC"
    );
    assert!(
        state
            .sessions
            .values()
            .all(|session| session.gc_reason.is_none()),
        "surviving sessions should not gain a GC reason during removal"
    );
}
