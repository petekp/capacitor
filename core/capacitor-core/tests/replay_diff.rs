use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

mod common;

use capacitor_core::domain::{
    AppSnapshot, HookEventType, IngestHookEventCommand, IngestShellSignalCommand,
    MutateProjectCommand, ProjectMutationKind, SessionState,
};
use capacitor_core::observation::{ObservationRecord, ObservationSourceKind};
use capacitor_core::projection::{SnapshotReadModel, SnapshotReadModelProjector};
use capacitor_core::storage::{InMemoryObservationJournalStore, ObservationJournalStore};
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

#[derive(Debug, Default, PartialEq, Eq)]
struct ShadowParityReport {
    mismatch_reasons: Vec<String>,
}

#[test]
fn replay_diff_corpus_matches_expected_and_is_deterministic() {
    let cases = replay_cases();
    assert!(
        !cases.is_empty(),
        "replay corpus fixtures should not be empty"
    );

    for case in cases {
        let first_snapshot = run_replay_case(&case);
        assert_expected(&case, &first_snapshot);

        let second_snapshot = run_replay_case(&case);
        assert_expected(&case, &second_snapshot);

        assert_eq!(
            normalized_snapshot(first_snapshot),
            normalized_snapshot(second_snapshot),
            "replay case '{}' should be deterministic",
            case.name,
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

fn replay_observations(case: &ReplayCase) -> Vec<ObservationRecord> {
    case.events
        .iter()
        .filter_map(|event| match event {
            ReplayEvent::Hook { command } => {
                Some(ObservationRecord::from_hook_event(command.clone()))
            }
            ReplayEvent::Shell { command } => {
                Some(ObservationRecord::from_shell_signal(command.clone()))
            }
            ReplayEvent::ProjectMutation { .. } => None,
        })
        .collect()
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

    let project_states = snapshot_state_map(snapshot.projects.iter().map(|project| {
        (
            project.project_path.clone(),
            state_label(project.state).to_string(),
        )
    }));

    assert_eq!(
        project_states, case.expected.project_states,
        "project state map mismatch for case '{}'",
        case.name
    );

    let session_states = snapshot_state_map(snapshot.sessions.iter().map(|session| {
        (
            session.session_id.clone(),
            state_label(session.state).to_string(),
        )
    }));

    assert_eq!(
        session_states, case.expected.session_states,
        "session state map mismatch for case '{}'",
        case.name
    );
}

fn snapshot_state_map(pairs: impl Iterator<Item = (String, String)>) -> BTreeMap<String, String> {
    pairs.collect::<BTreeMap<_, _>>()
}

fn normalized_snapshot(mut snapshot: AppSnapshot) -> serde_json::Value {
    snapshot.generated_at.clear();

    serde_json::to_value(snapshot).expect("serialize snapshot")
}

fn shadow_parity_report(
    snapshot: &AppSnapshot,
    read_model: &SnapshotReadModel,
) -> ShadowParityReport {
    let mut mismatch_reasons = Vec::new();

    if snapshot.projects.len() != read_model.snapshot.projects.len() {
        mismatch_reasons.push(format!(
            "project_count:{}!={}",
            snapshot.projects.len(),
            read_model.snapshot.projects.len()
        ));
    }

    if snapshot.sessions.len() != read_model.snapshot.sessions.len() {
        mismatch_reasons.push(format!(
            "session_count:{}!={}",
            snapshot.sessions.len(),
            read_model.snapshot.sessions.len()
        ));
    }

    if snapshot.shells.len() != read_model.snapshot.shells.len() {
        mismatch_reasons.push(format!(
            "shell_count:{}!={}",
            snapshot.shells.len(),
            read_model.snapshot.shells.len()
        ));
    }

    let snapshot_project_states = snapshot_state_map(snapshot.projects.iter().map(|project| {
        (
            project.project_path.clone(),
            state_label(project.state).to_string(),
        )
    }));
    let read_model_project_states =
        snapshot_state_map(read_model.snapshot.projects.iter().map(|project| {
            (
                project.project_path.clone(),
                state_label(project.state).to_string(),
            )
        }));
    if snapshot_project_states != read_model_project_states {
        mismatch_reasons.push("project_states_mismatch".to_string());
    }

    let snapshot_session_states = snapshot_state_map(snapshot.sessions.iter().map(|session| {
        (
            session.session_id.clone(),
            state_label(session.state).to_string(),
        )
    }));
    let read_model_session_states =
        snapshot_state_map(read_model.snapshot.sessions.iter().map(|session| {
            (
                session.session_id.clone(),
                state_label(session.state).to_string(),
            )
        }));
    if snapshot_session_states != read_model_session_states {
        mismatch_reasons.push("session_states_mismatch".to_string());
    }

    ShadowParityReport { mismatch_reasons }
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

fn replay_cases() -> Vec<ReplayCase> {
    replay_fixture_paths()
        .into_iter()
        .map(|fixture| {
            let payload = fs::read_to_string(&fixture).expect("read fixture payload");
            serde_json::from_str(&payload).unwrap_or_else(|error| {
                panic!("parse replay case fixture '{}': {error}", fixture.display())
            })
        })
        .collect()
}

#[test]
fn replay_diff_hook_event_type_deserialization_is_stable() {
    let hook_case = common::valid_hook_event_command(HookEventType::TaskCompleted);

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

#[test]
fn replay_diff_observation_scaffold_collects_non_mutation_events() {
    let cases = replay_cases();
    assert!(
        !cases.is_empty(),
        "replay corpus fixtures should not be empty"
    );

    for case in cases {
        let observations = replay_observations(&case);
        let expected_count = case
            .events
            .iter()
            .filter(|event| matches!(event, ReplayEvent::Hook { .. } | ReplayEvent::Shell { .. }))
            .count();

        assert_eq!(
            observations.len(),
            expected_count,
            "observation scaffold count mismatch for case '{}'",
            case.name
        );
        assert!(observations
            .iter()
            .all(|observation| !observation.recorded_at.is_empty()));
    }
}

#[test]
fn replay_diff_observation_journal_store_round_trips_replay_observations() {
    let case = replay_cases()
        .into_iter()
        .next()
        .expect("expected at least one replay case");
    let observations = replay_observations(&case);
    let store = InMemoryObservationJournalStore::default();

    for observation in observations.clone() {
        store.append(observation).expect("append observation");
    }

    let recorded = store.list().expect("list observations");
    assert_eq!(recorded.len(), observations.len());
    assert!(
        recorded.iter().any(|observation| matches!(
            observation.source_kind,
            ObservationSourceKind::ClaudeHook | ObservationSourceKind::ShellSignal
        )),
        "expected replay observations to retain source kinds"
    );
}

#[test]
fn replay_diff_snapshot_projector_scaffold_tracks_applied_observations() {
    let case = replay_cases()
        .into_iter()
        .next()
        .expect("expected at least one replay case");
    let observations = replay_observations(&case);
    let snapshot = run_replay_case(&case);
    let projector = SnapshotReadModelProjector;

    let read_model = projector.project(&snapshot, &observations);
    let checkpoint = projector.checkpoint(&observations);

    assert_eq!(projector.descriptor().name, "app_snapshot_read_model");
    assert_eq!(read_model.snapshot.projects.len(), snapshot.projects.len());
    assert_eq!(read_model.snapshot.sessions.len(), snapshot.sessions.len());
    assert_eq!(read_model.applied_observation_count, observations.len());
    assert_eq!(checkpoint.applied_observation_count, observations.len());
}

#[test]
fn replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot() {
    let cases = replay_cases();
    assert!(
        !cases.is_empty(),
        "replay corpus fixtures should not be empty"
    );

    for case in cases {
        let observations = replay_observations(&case);
        let snapshot = run_replay_case(&case);
        let projector = SnapshotReadModelProjector;
        let read_model = projector.project(&snapshot, &observations);
        let report = shadow_parity_report(&snapshot, &read_model);

        assert!(
            report.mismatch_reasons.is_empty(),
            "shadow parity mismatch for case '{}': {:?}",
            case.name,
            report.mismatch_reasons
        );
        assert_eq!(
            read_model.applied_observation_count,
            observations.len(),
            "applied observation count mismatch for case '{}'",
            case.name
        );
    }
}
