use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use capacitor_core::domain::{
    AppSnapshot, HookEventType, IngestHookEventCommand, IngestShellSignalCommand,
    MutateProjectCommand, MutationOutcome, ProjectMutationKind, SessionState,
};
use capacitor_core::CoreRuntime;

#[derive(Debug, serde::Deserialize)]
struct ReplayCase {
    name: String,
    events: Vec<ReplayEvent>,
    expected: ReplayExpected,
}

#[derive(Debug, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum ReplayEvent {
    Hook { command: IngestHookEventCommand },
    Shell { command: IngestShellSignalCommand },
    ProjectMutation { command: MutateProjectCommand },
}

#[derive(Debug, serde::Deserialize)]
struct ReplayExpected {
    events_ingested: u64,
    project_states: BTreeMap<String, String>,
    session_states: BTreeMap<String, String>,
    shell_count: usize,
}

#[test]
fn replay_diff_corpus_matches_expected_and_is_deterministic() {
    let fixtures = replay_fixture_paths();
    assert!(
        !fixtures.is_empty(),
        "replay corpus fixtures should not be empty"
    );

    for fixture in fixtures {
        let payload = fs::read_to_string(&fixture).expect("read fixture payload");
        let case: ReplayCase = serde_json::from_str(&payload).expect("parse replay case fixture");

        let first_snapshot = run_replay_case(&case);
        assert_expected(&case, &first_snapshot);

        let second_snapshot = run_replay_case(&case);
        assert_expected(&case, &second_snapshot);

        assert_eq!(
            normalized_snapshot(first_snapshot),
            normalized_snapshot(second_snapshot),
            "replay case '{}' should be deterministic",
            case.name
        );
    }
}

fn run_replay_case(case: &ReplayCase) -> AppSnapshot {
    let runtime = CoreRuntime::new().expect("runtime");

    for event in &case.events {
        let outcome = match event {
            ReplayEvent::Hook { command } => runtime
                .ingest_hook_event(command.clone())
                .expect("ingest hook event"),
            ReplayEvent::Shell { command } => runtime
                .ingest_shell_signal(command.clone())
                .expect("ingest shell signal"),
            ReplayEvent::ProjectMutation { command } => runtime
                .mutate_project(command.clone())
                .expect("mutate project"),
        };
        assert!(
            outcome.ok,
            "replay event should succeed: {}",
            outcome.message
        );
    }

    runtime.app_snapshot().expect("snapshot")
}

fn assert_expected(case: &ReplayCase, snapshot: &AppSnapshot) {
    assert_eq!(
        snapshot.diagnostics.events_ingested, case.expected.events_ingested,
        "events_ingested mismatch for case '{}'",
        case.name
    );
    assert_eq!(
        snapshot.shells.len(),
        case.expected.shell_count,
        "shell_count mismatch for case '{}'",
        case.name
    );

    let project_states = snapshot
        .projects
        .iter()
        .map(|project| {
            (
                project.project_path.clone(),
                state_label(project.state).to_string(),
            )
        })
        .collect::<BTreeMap<_, _>>();

    assert_eq!(
        project_states, case.expected.project_states,
        "project state map mismatch for case '{}'",
        case.name
    );

    let session_states = snapshot
        .sessions
        .iter()
        .map(|session| {
            (
                session.session_id.clone(),
                state_label(session.state).to_string(),
            )
        })
        .collect::<BTreeMap<_, _>>();

    assert_eq!(
        session_states, case.expected.session_states,
        "session state map mismatch for case '{}'",
        case.name
    );
}

fn normalized_snapshot(mut snapshot: AppSnapshot) -> serde_json::Value {
    snapshot.generated_at.clear();

    serde_json::to_value(snapshot).expect("serialize snapshot")
}

fn state_label(state: SessionState) -> &'static str {
    match state {
        SessionState::Working => "working",
        SessionState::Ready => "ready",
        SessionState::Idle => "idle",
        SessionState::Compacting => "compacting",
        SessionState::Waiting => "waiting",
    }
}

fn replay_fixture_paths() -> Vec<PathBuf> {
    let fixture_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/replay");
    let mut paths = fs::read_dir(fixture_dir)
        .expect("read fixture directory")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths
}

#[test]
fn replay_diff_hook_event_type_deserialization_is_stable() {
    let hook_case = IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2026-02-28T00:00:00Z".to_string(),
        event_type: HookEventType::TaskCompleted,
        session_id: "session-1".to_string(),
        pid: Some(42),
        project_path: "/tmp/project".to_string(),
        cwd: Some("/tmp/project".to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    };

    let payload = serde_json::to_value(&hook_case).expect("serialize command");
    let decoded: IngestHookEventCommand =
        serde_json::from_value(payload).expect("deserialize command");

    assert_eq!(decoded.event_type, HookEventType::TaskCompleted);
}

#[test]
fn replay_diff_project_mutation_variant_deserializes() {
    let payload = serde_json::json!({
        "kind": "project_mutation",
        "command": {
            "kind": "add",
            "project_path": "/tmp/demo",
            "display_name": "demo"
        }
    });

    let event: ReplayEvent = serde_json::from_value(payload).expect("deserialize replay event");

    match event {
        ReplayEvent::ProjectMutation { command } => {
            assert_eq!(command.kind, ProjectMutationKind::Add);
            assert_eq!(command.project_path, "/tmp/demo");
            assert_eq!(command.display_name.as_deref(), Some("demo"));
        }
        _ => panic!("expected project mutation event"),
    }
}

#[allow(dead_code)]
fn _assert_outcome_type(_outcome: MutationOutcome) {}
