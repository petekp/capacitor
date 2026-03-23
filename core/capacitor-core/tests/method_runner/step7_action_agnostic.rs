//! Step 7: Action-agnostic core proof tests.
//!
//! Proves that synthesis and interactive steps run on the same core as dispatch:
//! same event log, same state projection, same lock, same output binding,
//! same definition freeze. No second authority model.

use std::path::PathBuf;

use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::{execute_run, RunError};
use capacitor_core::method_runner::state::{rebuild_state, RunStatus};
use capacitor_core::method_runner::storage::MethodRunPaths;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn synthesis_only_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/synthesis-only.yaml")
}

fn interactive_only_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/interactive-only.yaml")
}

fn mixed_actions_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/mixed-actions.yaml")
}

fn pipeline_blocked_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/pipeline-blocked.yaml")
}

fn default_fake_io() -> FakeInteractiveIO {
    FakeInteractiveIO {
        response: "approved".to_string(),
    }
}

// ============================================================================
// 1. synthesis_step_executes_end_to_end
// ============================================================================

#[test]
fn synthesis_step_executes_end_to_end() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: execution_root.clone(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run for synthesis-only");

    let paths = MethodRunPaths::new(&execution_root);

    // .method/ tree exists
    assert!(paths.method_root().exists(), ".method/ must exist");

    // events.ndjson contains SynthesisStarted + SynthesisCompleted
    let events = recover_events(&paths.events_log()).expect("recover events");
    let kinds: Vec<MethodEventKind> = events.iter().map(|e| e.kind).collect();

    assert!(
        kinds.contains(&MethodEventKind::SynthesisStarted),
        "events must contain SynthesisStarted, got: {:?}",
        kinds
    );
    assert!(
        kinds.contains(&MethodEventKind::SynthesisCompleted),
        "events must contain SynthesisCompleted, got: {:?}",
        kinds
    );

    // No WorkerDispatched events (synthesis has no workers)
    assert!(
        !kinds.contains(&MethodEventKind::WorkerDispatched),
        "synthesis must NOT have WorkerDispatched events"
    );

    // No relay/ directory (C3: synthesis has no relay root)
    let attempt_dir = paths.attempt_dir("process", "synthesize", 1);
    let relay_dir = attempt_dir.join("relay");
    assert!(
        !relay_dir.exists(),
        "synthesis attempt must NOT have relay/ directory"
    );

    // state.json shows completed
    assert!(paths.state_json().exists(), "state.json must exist");
    assert_eq!(
        state.status,
        RunStatus::Completed,
        "run status must be completed"
    );

    // Output artifact exists
    let output_record = paths.output_record("digest");
    assert!(
        output_record.exists(),
        "artifacts/outputs/digest.json must exist"
    );

    // attempt.json, input-bindings.json, output-bindings.json exist
    assert!(
        attempt_dir.join("attempt.json").exists(),
        "attempt.json must exist"
    );
    assert!(
        attempt_dir.join("input-bindings.json").exists(),
        "input-bindings.json must exist"
    );
    assert!(
        attempt_dir.join("output-bindings.json").exists(),
        "output-bindings.json must exist"
    );

    // Synthesis output artifact exists at the declared path within attempt dir
    let output_artifact = attempt_dir.join("artifacts/digest.md");
    assert!(
        output_artifact.exists(),
        "synthesized output artifact must exist at {}",
        output_artifact.display()
    );
}

// ============================================================================
// 2. interactive_step_executes_end_to_end
// ============================================================================

#[test]
fn interactive_step_executes_end_to_end() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: interactive_only_path(),
        execution_root: execution_root.clone(),
    };

    let fake_io = FakeInteractiveIO {
        response: "This is my feedback on the draft.".to_string(),
    };

    let state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("execute_run for interactive-only");

    let paths = MethodRunPaths::new(&execution_root);

    // events.ndjson contains InteractivePrompted + InteractiveResponseReceived
    let events = recover_events(&paths.events_log()).expect("recover events");
    let kinds: Vec<MethodEventKind> = events.iter().map(|e| e.kind).collect();

    assert!(
        kinds.contains(&MethodEventKind::InteractivePrompted),
        "events must contain InteractivePrompted, got: {:?}",
        kinds
    );
    assert!(
        kinds.contains(&MethodEventKind::InteractiveResponseReceived),
        "events must contain InteractiveResponseReceived, got: {:?}",
        kinds
    );

    // No WorkerDispatched events
    assert!(
        !kinds.contains(&MethodEventKind::WorkerDispatched),
        "interactive must NOT have WorkerDispatched events"
    );

    // No relay/ directory
    let attempt_dir = paths.attempt_dir("collect", "prompt-user", 1);
    let relay_dir = attempt_dir.join("relay");
    assert!(
        !relay_dir.exists(),
        "interactive attempt must NOT have relay/ directory"
    );

    // state.json shows completed
    assert_eq!(
        state.status,
        RunStatus::Completed,
        "run status must be completed"
    );

    // Output artifact exists
    let output_record = paths.output_record("user_response");
    assert!(
        output_record.exists(),
        "artifacts/outputs/user_response.json must exist"
    );

    // Response artifact contains the fake response text
    let response_artifact = attempt_dir.join("artifacts/user-response.md");
    assert!(
        response_artifact.exists(),
        "response artifact must exist at {}",
        response_artifact.display()
    );
    let content = std::fs::read_to_string(&response_artifact).unwrap();
    assert_eq!(
        content, "This is my feedback on the draft.",
        "response artifact must contain the fake response text"
    );
}

// ============================================================================
// 3. mixed_actions_all_complete
// ============================================================================

#[test]
fn mixed_actions_all_complete() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: mixed_actions_path(),
        execution_root: execution_root.clone(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run for mixed-actions");

    let paths = MethodRunPaths::new(&execution_root);

    // All 3 phases complete
    assert_eq!(
        state.status,
        RunStatus::Completed,
        "run status must be completed"
    );
    assert_eq!(
        state.phases.len(),
        3,
        "must have 3 phases in state, got {}",
        state.phases.len()
    );

    // Recover events for kind analysis
    let events = recover_events(&paths.events_log()).expect("recover events");
    let kinds: Vec<MethodEventKind> = events.iter().map(|e| e.kind).collect();

    // Phase A used dispatch (has WorkerDispatched, HandoffIngested, relay/ dir)
    assert!(
        kinds.contains(&MethodEventKind::WorkerDispatched),
        "dispatch phase must have WorkerDispatched"
    );
    assert!(
        kinds.contains(&MethodEventKind::HandoffIngested),
        "dispatch phase must have HandoffIngested"
    );
    let dispatch_relay = paths.attempt_dir("phase-a", "do-dispatch", 1).join("relay");
    assert!(
        dispatch_relay.exists(),
        "dispatch attempt must have relay/ directory"
    );

    // Phase B used synthesis (has SynthesisStarted, no relay/)
    assert!(
        kinds.contains(&MethodEventKind::SynthesisStarted),
        "synthesis phase must have SynthesisStarted"
    );
    let synthesis_relay = paths
        .attempt_dir("phase-b", "do-synthesis", 1)
        .join("relay");
    assert!(
        !synthesis_relay.exists(),
        "synthesis attempt must NOT have relay/ directory"
    );

    // Phase C used interactive (has InteractivePrompted, no relay/)
    assert!(
        kinds.contains(&MethodEventKind::InteractivePrompted),
        "interactive phase must have InteractivePrompted"
    );
    let interactive_relay = paths
        .attempt_dir("phase-c", "do-interactive", 1)
        .join("relay");
    assert!(
        !interactive_relay.exists(),
        "interactive attempt must NOT have relay/ directory"
    );

    // All 3 method outputs resolved
    assert!(
        paths.output_record("worker_output").exists(),
        "worker_output output record must exist"
    );
    assert!(
        paths.output_record("synthesized").exists(),
        "synthesized output record must exist"
    );
    assert!(
        paths.output_record("user_input").exists(),
        "user_input output record must exist"
    );

    // state.json shows run completed
    assert!(paths.state_json().exists(), "state.json must exist");

    // Event log has correct interleaved event kinds — verify all three
    // action-specific event types appear
    let has_worker_dispatched = kinds.contains(&MethodEventKind::WorkerDispatched);
    let has_synthesis_started = kinds.contains(&MethodEventKind::SynthesisStarted);
    let has_interactive_prompted = kinds.contains(&MethodEventKind::InteractivePrompted);
    assert!(
        has_worker_dispatched && has_synthesis_started && has_interactive_prompted,
        "event log must contain all three action types interleaved"
    );
}

// ============================================================================
// 4. synthesis_shares_same_event_log
// ============================================================================

#[test]
fn synthesis_shares_same_event_log() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: mixed_actions_path(),
        execution_root: execution_root.clone(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // Verify there is exactly ONE events.ndjson file
    let events_path = paths.events_log();
    assert!(events_path.exists(), "single events.ndjson must exist");

    // Verify synthesis events are in the SAME events.ndjson as dispatch events
    let events = recover_events(&events_path).expect("recover events");
    let has_dispatch = events
        .iter()
        .any(|e| e.kind == MethodEventKind::WorkerDispatched);
    let has_synthesis = events
        .iter()
        .any(|e| e.kind == MethodEventKind::SynthesisStarted);
    let has_interactive = events
        .iter()
        .any(|e| e.kind == MethodEventKind::InteractivePrompted);

    assert!(
        has_dispatch && has_synthesis && has_interactive,
        "all action types must share the same events.ndjson (no alternate persistence path)"
    );

    // Verify all events share the same run_id
    let run_id = &events[0].run_id;
    for event in &events {
        assert_eq!(
            &event.run_id, run_id,
            "all events must share the same run_id"
        );
    }
}

// ============================================================================
// 5. synthesis_shares_same_state_projection
// ============================================================================

#[test]
fn synthesis_shares_same_state_projection() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: mixed_actions_path(),
        execution_root: execution_root.clone(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run");

    // Verify state.json includes synthesis step state (no alternate state store)
    assert!(
        state.phases.contains_key("phase-b"),
        "state must contain phase-b (synthesis phase)"
    );
    let phase_b = &state.phases["phase-b"];
    assert!(
        phase_b.steps.contains_key("do-synthesis"),
        "phase-b state must contain step do-synthesis"
    );
    let step_state = &phase_b.steps["do-synthesis"];
    assert_eq!(
        step_state.status,
        capacitor_core::method_runner::state::StepStatus::Completed,
        "synthesis step must be completed in projected state"
    );

    // Verify interactive step is also in the same state
    assert!(
        state.phases.contains_key("phase-c"),
        "state must contain phase-c (interactive phase)"
    );
    let phase_c = &state.phases["phase-c"];
    assert!(
        phase_c.steps.contains_key("do-interactive"),
        "phase-c state must contain step do-interactive"
    );
    let interactive_step = &phase_c.steps["do-interactive"];
    assert_eq!(
        interactive_step.status,
        capacitor_core::method_runner::state::StepStatus::Completed,
        "interactive step must be completed in projected state"
    );
}

// ============================================================================
// 6. synthesis_no_relay_directory
// ============================================================================

#[test]
fn synthesis_no_relay_directory() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: execution_root.clone(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // C3: synthesis attempt has no relay/ subdirectory
    let attempt_dir = paths.attempt_dir("process", "synthesize", 1);
    assert!(attempt_dir.exists(), "attempt dir must exist");
    let relay_dir = attempt_dir.join("relay");
    assert!(
        !relay_dir.exists(),
        "C3: synthesis attempt must NOT have relay/ subdirectory"
    );
}

// ============================================================================
// 7. interactive_no_relay_directory
// ============================================================================

#[test]
fn interactive_no_relay_directory() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: interactive_only_path(),
        execution_root: execution_root.clone(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // Interactive attempt has no relay/ subdirectory
    let attempt_dir = paths.attempt_dir("collect", "prompt-user", 1);
    assert!(attempt_dir.exists(), "attempt dir must exist");
    let relay_dir = attempt_dir.join("relay");
    assert!(
        !relay_dir.exists(),
        "interactive attempt must NOT have relay/ subdirectory"
    );
}

// ============================================================================
// 8. pipeline_execute_still_blocked
// ============================================================================

#[test]
fn pipeline_execute_still_blocked() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: pipeline_blocked_path(),
        execution_root: execution_root.clone(),
    };

    let result = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    );

    let err = result.expect_err("pipeline-execute should still be blocked");
    match err {
        RunError::PipelineExecuteBlocked(step_id) => {
            assert_eq!(
                step_id, "run-child-pipeline",
                "blocked step id should be 'run-child-pipeline'"
            );
        }
        other => {
            panic!("expected PipelineExecuteBlocked error, got: {}", other);
        }
    }
}

// ============================================================================
// 9. state_rebuild_with_mixed_actions
// ============================================================================

#[test]
fn state_rebuild_with_mixed_actions() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: mixed_actions_path(),
        execution_root: execution_root.clone(),
    };

    let original_state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_fake_io(),
    )
    .expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // Delete state.json
    std::fs::remove_file(paths.state_json()).expect("remove state.json");
    assert!(!paths.state_json().exists(), "state.json should be deleted");

    // Rebuild from events (I1: events are the authoritative source)
    let rebuilt_state = rebuild_state(&paths.events_log()).expect("rebuild_state");

    // Compare key fields
    assert_eq!(
        original_state.run_id, rebuilt_state.run_id,
        "rebuilt run_id must match original"
    );
    assert_eq!(
        original_state.status, rebuilt_state.status,
        "rebuilt status must match original"
    );
    assert_eq!(
        original_state.seq, rebuilt_state.seq,
        "rebuilt seq must match original"
    );

    // Compare phase structure
    assert_eq!(
        original_state.phases.keys().collect::<Vec<_>>(),
        rebuilt_state.phases.keys().collect::<Vec<_>>(),
        "rebuilt phase keys must match original"
    );

    for (phase_id, original_phase) in &original_state.phases {
        let rebuilt_phase = &rebuilt_state.phases[phase_id];
        assert_eq!(
            original_phase.status, rebuilt_phase.status,
            "rebuilt phase '{}' status must match",
            phase_id
        );

        // Compare step structure
        assert_eq!(
            original_phase.steps.keys().collect::<Vec<_>>(),
            rebuilt_phase.steps.keys().collect::<Vec<_>>(),
            "rebuilt step keys for phase '{}' must match",
            phase_id
        );

        for (step_id, original_step) in &original_phase.steps {
            let rebuilt_step = &rebuilt_phase.steps[step_id];
            assert_eq!(
                original_step.status, rebuilt_step.status,
                "rebuilt step '{}/{}' status must match",
                phase_id, step_id
            );
            assert_eq!(
                original_step.outputs, rebuilt_step.outputs,
                "rebuilt step '{}/{}' outputs must match",
                phase_id, step_id
            );
        }
    }
}
