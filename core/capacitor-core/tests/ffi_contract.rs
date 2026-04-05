use std::fs;

mod common;

use capacitor_core::domain::{
    HookEventType, IdeaMutationKind, IngestHookEventCommand, IngestShellSignalCommand,
    MutateIdeaCommand, MutateProjectCommand, MutateWorktreeCommand, ProjectMutationKind,
    ResolveRoutingCommand, RoutingStatus, RoutingTargetKind, TmuxPaneInfo, WorktreeMutationKind,
};
use capacitor_core::CoreRuntime;

fn valid_hook_event_command() -> IngestHookEventCommand {
    common::valid_hook_event_command(HookEventType::UserPromptSubmit)
}

fn valid_shell_signal_command() -> IngestShellSignalCommand {
    IngestShellSignalCommand {
        pid: 4242,
        cwd: "/tmp/core-project".to_string(),
        tty: "/dev/ttys001".to_string(),
        parent_app: "Ghostty".to_string(),
        tmux_session: Some("core".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%42".to_string()),
        tmux_panes: vec![],
        recorded_at: "2099-02-28T19:00:00Z".to_string(),
    }
}

fn assert_rejected(ok: bool, message: &str, expected_message: &str) {
    assert!(!ok);
    assert_eq!(message, expected_message);
}

fn snapshot(runtime: &CoreRuntime) -> capacitor_core::domain::AppSnapshot {
    runtime.app_snapshot().expect("snapshot")
}

fn assert_last_error(runtime: &CoreRuntime, expected: &str) {
    assert_eq!(
        snapshot(runtime).diagnostics.last_error.as_deref(),
        Some(expected)
    );
}

fn assert_rejected_with_last_error(
    runtime: &CoreRuntime,
    ok: bool,
    message: &str,
    expected_message: &str,
    expected_last_error: &str,
    context: &str,
) {
    assert_rejected(ok, message, expected_message);
    assert_eq!(
        snapshot(runtime).diagnostics.last_error.as_deref(),
        Some(expected_last_error),
        "{context} should update diagnostics.last_error",
    );
}

fn mutate_project(
    runtime: &CoreRuntime,
    kind: ProjectMutationKind,
    project_path: &str,
    display_name: Option<&str>,
) -> capacitor_core::domain::MutationOutcome {
    runtime
        .mutate_project(MutateProjectCommand {
            kind,
            project_path: project_path.to_string(),
            display_name: display_name.map(str::to_string),
        })
        .expect("mutation outcome")
}

#[test]
fn ffi_constructor_rejects_blank_snapshot_path() {
    let error = match CoreRuntime::new_with_snapshot_file(" \n\t ".to_string()) {
        Ok(_) => panic!("blank path must fail"),
        Err(error) => error,
    };
    assert!(error
        .to_string()
        .contains("snapshot_file path cannot be empty"));
}

#[test]
fn ffi_constructor_loads_snapshot_file_shape() {
    let temp_dir = tempfile::tempdir().expect("temp dir");
    let snapshot_path = temp_dir.path().join("app_snapshot.json");

    fs::write(&snapshot_path, fixture_snapshot_json()).expect("write snapshot fixture");

    let runtime = CoreRuntime::new_with_snapshot_file(snapshot_path.to_string_lossy().to_string())
        .expect("runtime from snapshot");
    let snapshot = runtime.app_snapshot().expect("app snapshot");

    assert_eq!(snapshot.projects.len(), 1);
    assert_eq!(snapshot.sessions.len(), 1);
    assert_eq!(snapshot.shells.len(), 1);
    assert_eq!(snapshot.routing.len(), 1);
    assert_eq!(snapshot.projects[0].project_path, "/tmp/core-project");
    assert_eq!(snapshot.sessions[0].session_id, "session-core");
    assert_eq!(snapshot.routing[0].target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(snapshot.routing[0].target.pane_id.as_deref(), Some("%42"));
    assert_eq!(
        snapshot.routing[0].target.session_name.as_deref(),
        Some("core")
    );
    assert_eq!(snapshot.diagnostics.events_ingested, 7);
}

#[test]
fn ffi_ingest_hook_event_validates_required_fields() {
    let runtime = CoreRuntime::new().expect("runtime");
    let cases = [
        (
            "missing_event_id",
            IngestHookEventCommand {
                event_id: "".to_string(),
                ..valid_hook_event_command()
            },
            "missing event_id",
        ),
        (
            "missing_session_id",
            IngestHookEventCommand {
                session_id: "".to_string(),
                recorded_at: "2099-02-28T19:00:01Z".to_string(),
                ..valid_hook_event_command()
            },
            "missing session_id",
        ),
    ];

    for (name, command, expected_message) in cases {
        let outcome = runtime
            .ingest_hook_event(command)
            .expect("mutation outcome");
        assert_rejected_with_last_error(
            &runtime,
            outcome.ok,
            &outcome.message,
            expected_message,
            &format!("ingest_hook_event {expected_message}"),
            name,
        );
    }

    assert_last_error(&runtime, "ingest_hook_event missing session_id");
}

#[test]
fn ffi_ingest_shell_signal_validates_required_fields() {
    let runtime = CoreRuntime::new().expect("runtime");
    let cases = [
        (
            "missing_cwd",
            IngestShellSignalCommand {
                cwd: "".to_string(),
                ..valid_shell_signal_command()
            },
            "missing cwd or tty",
        ),
        (
            "missing_tty",
            IngestShellSignalCommand {
                tty: "".to_string(),
                recorded_at: "2099-02-28T19:00:01Z".to_string(),
                ..valid_shell_signal_command()
            },
            "missing cwd or tty",
        ),
    ];

    for (name, command, expected_message) in cases {
        let outcome = runtime
            .ingest_shell_signal(command)
            .expect("mutation outcome");
        assert_rejected_with_last_error(
            &runtime,
            outcome.ok,
            &outcome.message,
            expected_message,
            &format!("ingest_shell_signal {expected_message}"),
            name,
        );
    }

    assert_last_error(&runtime, "ingest_shell_signal missing cwd or tty");
}

#[test]
fn ffi_ingest_shell_signal_derives_tmux_pane_routing() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .ingest_hook_event(valid_hook_event_command())
        .expect("hook event outcome");

    let outcome = runtime
        .ingest_shell_signal(valid_shell_signal_command())
        .expect("shell signal outcome");

    assert!(outcome.ok);

    let snapshot = snapshot(&runtime);
    let route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/tmp/core-project")
        .expect("route");
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.session_name.as_deref(), Some("core"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
}

#[test]
fn ffi_ingest_shell_signal_infers_attached_tmux_terminal_app_from_host_tty_evidence() {
    let runtime = CoreRuntime::new().expect("runtime");
    runtime
        .ingest_hook_event(valid_hook_event_command())
        .expect("hook event outcome");

    let host_shell = IngestShellSignalCommand {
        pid: 9000,
        cwd: "/tmp".to_string(),
        tty: "/dev/ttys099".to_string(),
        parent_app: "Ghostty".to_string(),
        tmux_session: Some("shared".to_string()),
        tmux_client_tty: Some("/dev/ttys099".to_string()),
        tmux_pane: Some("%1".to_string()),
        tmux_panes: vec![],
        recorded_at: "2099-02-28T18:59:59Z".to_string(),
    };
    assert!(
        runtime
            .ingest_shell_signal(host_shell)
            .expect("host shell signal outcome")
            .ok
    );

    let project_shell = IngestShellSignalCommand {
        parent_app: "tmux".to_string(),
        ..valid_shell_signal_command()
    };
    let outcome = runtime
        .ingest_shell_signal(project_shell)
        .expect("project shell signal outcome");

    assert!(outcome.ok);

    let snapshot = snapshot(&runtime);
    let route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/tmp/core-project")
        .expect("route");
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.session_name.as_deref(), Some("core"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
}

#[test]
fn ffi_ingest_shell_signal_derives_non_active_tmux_pane_from_inventory() {
    let runtime = CoreRuntime::new().expect("runtime");
    let mut hook_event = valid_hook_event_command();
    hook_event.project_path = "/tmp/aui/mcp-app-studio-starter".to_string();
    hook_event.cwd = Some("/tmp/aui/mcp-app-studio-starter".to_string());
    runtime
        .ingest_hook_event(hook_event)
        .expect("hook event outcome");

    let outcome = runtime
        .ingest_shell_signal(IngestShellSignalCommand {
            pid: 4242,
            cwd: "/tmp/pete-2025".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "Ghostty".to_string(),
            tmux_session: Some("dev".to_string()),
            tmux_client_tty: Some("/dev/ttys099".to_string()),
            tmux_pane: Some("%0".to_string()),
            tmux_panes: vec![
                TmuxPaneInfo {
                    session_name: "dev".to_string(),
                    pane_id: "%0".to_string(),
                    pane_path: "/tmp/pete-2025".to_string(),
                    session_attached: true,
                },
                TmuxPaneInfo {
                    session_name: "dev".to_string(),
                    pane_id: "%1".to_string(),
                    pane_path: "/tmp/aui/mcp-app-studio-starter".to_string(),
                    session_attached: true,
                },
            ],
            recorded_at: "2099-02-28T19:00:00Z".to_string(),
        })
        .expect("shell signal outcome");

    assert!(outcome.ok);

    let snapshot = snapshot(&runtime);
    let route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/tmp/aui/mcp-app-studio-starter")
        .expect("route");
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%1"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
}

#[test]
fn ffi_routing_inventory_preference_snapshot_prefers_inventory_for_mismatched_shell() {
    let runtime = CoreRuntime::new().expect("runtime");
    let mut hook_event = valid_hook_event_command();
    hook_event.pid = Some(4242);
    hook_event.project_path = "/tmp/target".to_string();
    hook_event.cwd = Some("/tmp/target".to_string());
    runtime
        .ingest_hook_event(hook_event)
        .expect("hook event outcome");

    let outcome = runtime
        .ingest_shell_signal(IngestShellSignalCommand {
            pid: 4242,
            cwd: "/tmp/other".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "Ghostty".to_string(),
            tmux_session: Some("dev".to_string()),
            tmux_client_tty: Some("/dev/ttys099".to_string()),
            tmux_pane: Some("%0".to_string()),
            tmux_panes: vec![
                TmuxPaneInfo {
                    session_name: "dev".to_string(),
                    pane_id: "%0".to_string(),
                    pane_path: "/tmp/other".to_string(),
                    session_attached: true,
                },
                TmuxPaneInfo {
                    session_name: "dev".to_string(),
                    pane_id: "%1".to_string(),
                    pane_path: "/tmp/target".to_string(),
                    session_attached: true,
                },
            ],
            recorded_at: "2099-03-16T01:00:00Z".to_string(),
        })
        .expect("shell signal outcome");

    assert!(outcome.ok);

    let snapshot = snapshot(&runtime);
    let route = snapshot
        .routing
        .iter()
        .find(|route| route.project_path == "/tmp/target")
        .expect("route");
    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("dev"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%1"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys099"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%1' from pane inventory");
    assert_eq!(route.updated_at, "2099-03-16T01:00:00Z");
}

#[test]
fn ffi_routing_inventory_preference_resolve_prefers_inventory_for_hinted_mismatched_shell() {
    let runtime = CoreRuntime::new().expect("runtime");

    let outcome = runtime
        .ingest_shell_signal(IngestShellSignalCommand {
            pid: 5252,
            cwd: "/tmp/other".to_string(),
            tty: "/dev/ttys030".to_string(),
            parent_app: "Terminal".to_string(),
            tmux_session: Some("caps".to_string()),
            tmux_client_tty: Some("/dev/ttys040".to_string()),
            tmux_pane: Some("%0".to_string()),
            tmux_panes: vec![
                TmuxPaneInfo {
                    session_name: "caps".to_string(),
                    pane_id: "%0".to_string(),
                    pane_path: "/tmp/other".to_string(),
                    session_attached: true,
                },
                TmuxPaneInfo {
                    session_name: "caps".to_string(),
                    pane_id: "%5".to_string(),
                    pane_path: "/tmp/target".to_string(),
                    session_attached: true,
                },
            ],
            recorded_at: "2099-03-16T01:00:01Z".to_string(),
        })
        .expect("shell signal outcome");

    assert!(outcome.ok);

    let route = runtime
        .resolve_routing(ResolveRoutingCommand {
            project_path: "/tmp/target".to_string(),
            workspace_id: None,
            session_name: Some("caps".to_string()),
            client_tty: Some("/dev/ttys040".to_string()),
        })
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("terminal"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%5"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys040"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%5' from pane inventory");
    assert_eq!(route.updated_at, "2099-03-16T01:00:01Z");
}

#[test]
fn ffi_routing_inventory_preference_resolve_keeps_matching_shell_canonical() {
    let runtime = CoreRuntime::new().expect("runtime");

    let outcome = runtime
        .ingest_shell_signal(IngestShellSignalCommand {
            pid: 6262,
            cwd: "/tmp/repo".to_string(),
            tty: "/dev/ttys031".to_string(),
            parent_app: "Ghostty".to_string(),
            tmux_session: Some("caps".to_string()),
            tmux_client_tty: Some("/dev/ttys041".to_string()),
            tmux_pane: Some("%42".to_string()),
            tmux_panes: vec![TmuxPaneInfo {
                session_name: "caps".to_string(),
                pane_id: "%9".to_string(),
                pane_path: "/tmp/repo".to_string(),
                session_attached: true,
            }],
            recorded_at: "2099-03-16T01:00:02Z".to_string(),
        })
        .expect("shell signal outcome");

    assert!(outcome.ok);

    let route = runtime
        .resolve_routing(ResolveRoutingCommand {
            project_path: "/tmp/repo".to_string(),
            workspace_id: None,
            session_name: Some("caps".to_string()),
            client_tty: Some("/dev/ttys041".to_string()),
        })
        .expect("route");

    assert_eq!(route.status, RoutingStatus::Attached);
    assert_eq!(route.target.kind, RoutingTargetKind::TmuxPane);
    assert_eq!(route.target.terminal_app.as_deref(), Some("ghostty"));
    assert_eq!(route.target.session_name.as_deref(), Some("caps"));
    assert_eq!(route.target.pane_id.as_deref(), Some("%42"));
    assert_eq!(route.target.host_tty.as_deref(), Some("/dev/ttys041"));
    assert_eq!(route.reason_code, "TMUX_PANE_ATTACHED");
    assert_eq!(route.reason, "Matched tmux pane '%42'");
    assert_eq!(route.updated_at, "2099-03-16T01:00:02Z");
}

#[test]
fn ffi_mutate_project_validates_and_applies_add_rename_remove() {
    let runtime = CoreRuntime::new().expect("runtime");

    let empty_add = mutate_project(&runtime, ProjectMutationKind::Add, "", Some("ignored"));
    assert!(!empty_add.ok);
    assert_eq!(empty_add.message, "project_path cannot be empty");

    let added = mutate_project(
        &runtime,
        ProjectMutationKind::Add,
        "/tmp/rewrite-contract",
        Some("rewrite-contract"),
    );
    assert!(added.ok);
    assert_eq!(added.message, "project added");

    let renamed = mutate_project(
        &runtime,
        ProjectMutationKind::Rename,
        "/tmp/rewrite-contract",
        Some("rewrite-contract-renamed"),
    );
    assert!(renamed.ok);
    assert_eq!(renamed.message, "project renamed");

    let snapshot_after_rename = snapshot(&runtime);
    let project = snapshot_after_rename
        .projects
        .iter()
        .find(|project| project.project_path == "/tmp/rewrite-contract")
        .expect("project exists");
    assert_eq!(project.display_name, "rewrite-contract-renamed");

    let removed = mutate_project(
        &runtime,
        ProjectMutationKind::Remove,
        "/tmp/rewrite-contract",
        None,
    );
    assert!(removed.ok);
    assert_eq!(removed.message, "project removed");

    let snapshot_after_remove = snapshot(&runtime);
    assert!(snapshot_after_remove
        .projects
        .iter()
        .all(|project| project.project_path != "/tmp/rewrite-contract"));
}

#[test]
fn ffi_mutate_idea_and_worktree_update_command_envelope_contracts() {
    let runtime = CoreRuntime::new().expect("runtime");

    let idea = runtime
        .mutate_idea(MutateIdeaCommand {
            kind: IdeaMutationKind::Add,
            project_path: "/tmp/rewrite-contract".to_string(),
            idea_id: "idea-1".to_string(),
            title: Some("Idea".to_string()),
            description: Some("Description".to_string()),
            status: Some("todo".to_string()),
        })
        .expect("idea mutation");
    assert!(idea.ok);
    assert!(idea.message.contains(
        "idea mutation accepted kind=Add project_path=/tmp/rewrite-contract idea_id=idea-1"
    ));

    let worktree = runtime
        .mutate_worktree(MutateWorktreeCommand {
            kind: WorktreeMutationKind::Create,
            repo_path: "/tmp/rewrite-contract".to_string(),
            worktree_name: "feature-1".to_string(),
            force: true,
        })
        .expect("worktree mutation");
    assert!(worktree.ok);
    assert!(
        worktree.message.contains(
            "worktree mutation accepted kind=Create repo_path=/tmp/rewrite-contract worktree_name=feature-1 force=true",
        )
    );

    let snapshot = snapshot(&runtime);
    assert_eq!(snapshot.diagnostics.events_ingested, 2);
}

fn fixture_snapshot_json() -> &'static str {
    r#"{
  "projects": [
    {
      "project_id": "/tmp/core-project/.git",
      "workspace_id": "workspace-core",
      "project_path": "/tmp/core-project",
      "display_name": "core-project",
      "state": "working",
      "updated_at": "2099-02-28T19:00:00Z",
      "state_changed_at": "2099-02-28T19:00:00Z",
      "representative_session_id": "session-core",
      "latest_session_id": "session-core",
      "session_count": 1,
      "active_count": 1,
      "has_session": true
    }
  ],
  "sessions": [
    {
      "session_id": "session-core",
      "pid": 4242,
      "cwd": "/tmp/core-project",
      "project_id": "/tmp/core-project/.git",
      "project_path": "/tmp/core-project",
      "workspace_id": "workspace-core",
      "state": "working",
      "state_changed_at": "2099-02-28T19:00:00Z",
      "updated_at": "2099-02-28T19:00:00Z",
      "last_event": "user_prompt_submit",
      "last_activity_at": "2099-02-28T19:00:00Z",
      "tools_in_flight": 1,
      "ready_reason": null
    }
  ],
  "shells": [
    {
      "pid": 4242,
      "cwd": "/tmp/core-project",
      "tty": "/dev/ttys001",
      "parent_app": "Ghostty",
      "tmux_session": "core",
      "tmux_pane": "%42",
      "updated_at": "2099-02-28T19:00:00Z"
    }
  ],
  "routing": [
    {
      "workspace_id": "workspace-core",
      "project_path": "/tmp/core-project",
      "status": "attached",
      "target": {
        "kind": "tmux_pane",
        "terminal_app": "Ghostty",
        "session_name": "core",
        "pane_id": "%42",
        "host_tty": null
      },
      "reason_code": "TMUX_PANE_ATTACHED",
      "reason": "Matched tmux pane '%42'",
      "updated_at": "2099-02-28T19:00:00Z"
    }
  ],
  "delegations": [],
  "diagnostics": {
    "events_ingested": 7,
    "sessions_tracked": 1,
    "shell_signals_tracked": 1,
    "events_skipped": 0,
    "stale_events_skipped": 0,
    "informational_events_skipped": 0,
    "reducer_events_skipped": 0,
    "last_error": null
  },
  "generated_at": "2099-02-28T19:00:00Z",
  "schema_version": 1
}"#
}
