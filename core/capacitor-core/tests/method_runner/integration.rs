//! Integration tests for the method runner tracer bullet.
//!
//! These tests exercise end-to-end flows: full lifecycle runs, event sequence
//! validation, state rebuild, artifact cross-referencing, normalize-only paths,
//! real method normalization, pipeline-execute blocking, and run isolation.

use std::collections::BTreeSet;
use std::path::PathBuf;

use capacitor_core::method_runner::adapters::{FakePromptBuilder, FakeWorkerDispatcher};
use capacitor_core::method_runner::definition::{ActionKind, DefinitionLoader, DefinitionSource};
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::{execute_normalize, execute_run, RunError};
use capacitor_core::method_runner::state::rebuild_state;
use capacitor_core::method_runner::storage::MethodRunPaths;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn minimal_dispatch_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/minimal-dispatch.yaml")
}

fn pipeline_blocked_path() -> PathBuf {
    crate_root().join("../../methods/fixtures/pipeline-blocked.yaml")
}

fn spec_hardening_path() -> PathBuf {
    crate_root().join("../../methods/library/spec-hardening.yaml")
}

// ============================================================================
// 1. integration_full_lifecycle
// ============================================================================

#[test]
fn integration_full_lifecycle() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: execution_root.clone(),
    };

    let state =
        execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher).expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // -- Every expected file exists --

    // definition.snapshot.yaml
    let snapshot_path = paths.definition_snapshot();
    assert!(
        snapshot_path.exists(),
        "definition.snapshot.yaml must exist"
    );

    // events.ndjson
    let events_path = paths.events_log();
    assert!(events_path.exists(), "events.ndjson must exist");

    // state.json
    let state_path = paths.state_json();
    assert!(state_path.exists(), "state.json must exist");

    // step.json for bootstrap/dispatch
    let step_json_path = paths.step_dir("bootstrap", "dispatch").join("step.json");
    assert!(step_json_path.exists(), "step.json must exist");

    // attempt.json for bootstrap/dispatch/001
    let attempt_dir = paths.attempt_dir("bootstrap", "dispatch", 1);
    let attempt_json_path = attempt_dir.join("attempt.json");
    assert!(attempt_json_path.exists(), "attempt.json must exist");

    // input-bindings.json
    let input_bindings_path = attempt_dir.join("input-bindings.json");
    assert!(
        input_bindings_path.exists(),
        "input-bindings.json must exist"
    );

    // output-bindings.json
    let output_bindings_path = attempt_dir.join("output-bindings.json");
    assert!(
        output_bindings_path.exists(),
        "output-bindings.json must exist"
    );

    // parsed-handoffs/primary.json
    let parsed_handoff_path = attempt_dir.join("parsed-handoffs").join("primary.json");
    assert!(
        parsed_handoff_path.exists(),
        "parsed-handoffs/primary.json must exist"
    );

    // artifacts/outputs/dispatch_summary.json
    let output_record_path = paths.output_record("dispatch_summary");
    assert!(
        output_record_path.exists(),
        "artifacts/outputs/dispatch_summary.json must exist"
    );

    // artifacts/handoffs/bootstrap--dispatch--001--primary.md
    let handoff_canonical = paths.canonical_handoff("bootstrap", "dispatch", 1, "primary");
    assert!(handoff_canonical.exists(), "canonical handoff must exist");

    // -- Validate file contents are well-formed --

    // definition.snapshot.yaml is valid YAML
    let snapshot_content = std::fs::read_to_string(&snapshot_path).unwrap();
    let _: serde_yaml::Value = serde_yaml::from_str(&snapshot_content)
        .expect("definition.snapshot.yaml must be valid YAML");

    // events.ndjson has valid JSON on every line
    let events_content = std::fs::read_to_string(&events_path).unwrap();
    for (i, line) in events_content.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        serde_json::from_str::<serde_json::Value>(trimmed)
            .unwrap_or_else(|e| panic!("events.ndjson line {} is invalid JSON: {}", i + 1, e));
    }

    // state.json is valid JSON
    let state_content = std::fs::read_to_string(&state_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&state_content)
        .expect("state.json must be valid JSON");

    // step.json is valid JSON
    let step_content = std::fs::read_to_string(&step_json_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&step_content).expect("step.json must be valid JSON");

    // attempt.json is valid JSON
    let attempt_content = std::fs::read_to_string(&attempt_json_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&attempt_content)
        .expect("attempt.json must be valid JSON");

    // input-bindings.json is valid JSON
    let input_bindings_content = std::fs::read_to_string(&input_bindings_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&input_bindings_content)
        .expect("input-bindings.json must be valid JSON");

    // output-bindings.json is valid JSON
    let output_bindings_content = std::fs::read_to_string(&output_bindings_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&output_bindings_content)
        .expect("output-bindings.json must be valid JSON");

    // parsed-handoffs/primary.json is valid JSON
    let parsed_handoff_content = std::fs::read_to_string(&parsed_handoff_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&parsed_handoff_content)
        .expect("parsed-handoffs/primary.json must be valid JSON");

    // artifacts/outputs/dispatch_summary.json is valid JSON
    let output_record_content = std::fs::read_to_string(&output_record_path).unwrap();
    serde_json::from_str::<serde_json::Value>(&output_record_content)
        .expect("artifacts/outputs/dispatch_summary.json must be valid JSON");

    // Sanity check the returned state
    assert!(!state.run_id.is_empty(), "run_id must not be empty");
}

// ============================================================================
// 2. integration_event_sequence_correctness
// ============================================================================

#[test]
fn integration_event_sequence_correctness() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: execution_root.clone(),
    };

    let _state =
        execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher).expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);
    let events = recover_events(&paths.events_log()).expect("recover events");

    // Verify seq numbers are 1..N monotonically
    assert!(!events.is_empty(), "events must not be empty");
    for (i, event) in events.iter().enumerate() {
        let expected_seq = (i as u64) + 1;
        assert_eq!(
            event.seq, expected_seq,
            "event {} has seq {} but expected {}",
            i, event.seq, expected_seq
        );
    }

    // Verify timestamps are all non-empty
    for event in &events {
        assert!(
            !event.timestamp.is_empty(),
            "event seq {} must have a non-empty timestamp",
            event.seq
        );
    }

    // Verify run_id is consistent across all events
    let run_id = &events[0].run_id;
    assert!(!run_id.is_empty(), "run_id must not be empty");
    for event in &events {
        assert_eq!(
            &event.run_id, run_id,
            "event seq {} has inconsistent run_id '{}' vs expected '{}'",
            event.seq, event.run_id, run_id
        );
    }

    // Verify the expected event kind order for minimal-dispatch.yaml:
    // definition_frozen, run_started, phase_started, step_started,
    // attempt_started, worker_dispatched, worker_completed, handoff_ingested,
    // output_bound, attempt_completed, step_completed, phase_completed,
    // output_bound (method-level), run_completed
    let expected_kinds = vec![
        MethodEventKind::DefinitionFrozen,
        MethodEventKind::RunStarted,
        MethodEventKind::PhaseStarted,
        MethodEventKind::StepStarted,
        MethodEventKind::AttemptStarted,
        MethodEventKind::WorkerDispatched,
        MethodEventKind::WorkerCompleted,
        MethodEventKind::HandoffIngested,
        MethodEventKind::OutputBound,
        MethodEventKind::AttemptCompleted,
        MethodEventKind::StepCompleted,
        MethodEventKind::PhaseCompleted,
        MethodEventKind::OutputBound,
        MethodEventKind::RunCompleted,
    ];

    let actual_kinds: Vec<MethodEventKind> = events.iter().map(|e| e.kind).collect();
    assert_eq!(
        actual_kinds, expected_kinds,
        "event kind sequence mismatch.\nactual:   {:?}\nexpected: {:?}",
        actual_kinds, expected_kinds
    );

    // Verify phase_id is set on phase/step/attempt/worker events
    for event in &events {
        match event.kind {
            MethodEventKind::PhaseStarted
            | MethodEventKind::PhaseCompleted
            | MethodEventKind::StepStarted
            | MethodEventKind::StepCompleted
            | MethodEventKind::AttemptStarted
            | MethodEventKind::AttemptCompleted
            | MethodEventKind::WorkerDispatched
            | MethodEventKind::WorkerCompleted
            | MethodEventKind::HandoffIngested
            | MethodEventKind::OutputBound => {
                // OutputBound at method level may not have phase_id, but the
                // step-level one does. We just check it's set when step_id is set.
                if event.step_id.is_some() {
                    assert!(
                        event.phase_id.is_some(),
                        "event seq {} ({:?}) with step_id must have phase_id",
                        event.seq,
                        event.kind
                    );
                }
            }
            _ => {}
        }
    }

    // Verify step_id is set on step/attempt/worker events
    for event in &events {
        match event.kind {
            MethodEventKind::StepStarted
            | MethodEventKind::StepCompleted
            | MethodEventKind::AttemptStarted
            | MethodEventKind::AttemptCompleted
            | MethodEventKind::WorkerDispatched
            | MethodEventKind::WorkerCompleted
            | MethodEventKind::HandoffIngested => {
                assert!(
                    event.step_id.is_some(),
                    "event seq {} ({:?}) must have step_id",
                    event.seq,
                    event.kind
                );
            }
            _ => {}
        }
    }
}

// ============================================================================
// 3. integration_state_rebuild_from_events
// ============================================================================

#[test]
fn integration_state_rebuild_from_events() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: execution_root.clone(),
    };

    let _state =
        execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher).expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // Save original state.json content
    let original_state_content = std::fs::read_to_string(paths.state_json()).unwrap();
    let original_state: serde_json::Value =
        serde_json::from_str(&original_state_content).expect("parse original state");

    // Delete state.json
    std::fs::remove_file(paths.state_json()).expect("remove state.json");
    assert!(!paths.state_json().exists(), "state.json should be deleted");

    // Rebuild state from events
    let rebuilt = rebuild_state(&paths.events_log()).expect("rebuild_state");

    // Compare rebuilt state to original (key fields)
    let rebuilt_json: serde_json::Value =
        serde_json::from_str(&serde_json::to_string_pretty(&rebuilt).unwrap()).unwrap();

    assert_eq!(
        original_state["run_id"], rebuilt_json["run_id"],
        "rebuilt run_id must match original"
    );
    assert_eq!(
        original_state["status"], rebuilt_json["status"],
        "rebuilt status must match original"
    );
    assert_eq!(
        original_state["seq"], rebuilt_json["seq"],
        "rebuilt seq must match original"
    );

    // Compare phase structure
    let original_phases = original_state["phases"]
        .as_object()
        .expect("original phases");
    let rebuilt_phases = rebuilt_json["phases"].as_object().expect("rebuilt phases");
    assert_eq!(
        original_phases.keys().collect::<Vec<_>>(),
        rebuilt_phases.keys().collect::<Vec<_>>(),
        "rebuilt phase keys must match original"
    );

    for (phase_id, original_phase) in original_phases {
        let rebuilt_phase = &rebuilt_phases[phase_id];
        assert_eq!(
            original_phase["status"], rebuilt_phase["status"],
            "rebuilt phase '{}' status must match",
            phase_id
        );
    }
}

// ============================================================================
// 4. integration_artifact_cross_reference
// ============================================================================

#[test]
fn integration_artifact_cross_reference() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: execution_root.clone(),
    };

    let _state =
        execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher).expect("execute_run");

    let paths = MethodRunPaths::new(&execution_root);

    // Load the definition snapshot
    let def = DefinitionLoader::load(&paths.definition_snapshot()).expect("load snapshot");

    // Recover events
    let events = recover_events(&paths.events_log()).expect("recover events");

    // Collect phase_id and step_id values from events
    let event_phase_ids: BTreeSet<String> =
        events.iter().filter_map(|e| e.phase_id.clone()).collect();
    let event_step_ids: BTreeSet<String> =
        events.iter().filter_map(|e| e.step_id.clone()).collect();

    // Verify definition snapshot phase/step ids match event phase_id/step_id values
    for phase in &def.method.phases {
        assert!(
            event_phase_ids.contains(&phase.id),
            "definition phase '{}' must appear in events",
            phase.id
        );
        for step in &phase.steps {
            assert!(
                event_step_ids.contains(&step.id),
                "definition step '{}' must appear in events",
                step.id
            );
        }
    }

    // Verify canonical handoff filename components match
    // For minimal-dispatch: bootstrap--dispatch--001--primary.md
    let expected_handoff = paths.canonical_handoff("bootstrap", "dispatch", 1, "primary");
    assert!(
        expected_handoff.exists(),
        "canonical handoff bootstrap--dispatch--001--primary.md must exist"
    );
    let handoff_filename = expected_handoff.file_name().unwrap().to_str().unwrap();
    assert_eq!(
        handoff_filename, "bootstrap--dispatch--001--primary.md",
        "handoff filename must match canonical format"
    );

    // Verify output record locator matches method output definition
    let output_record_content =
        std::fs::read_to_string(paths.output_record("dispatch_summary")).unwrap();
    let output_record: serde_json::Value =
        serde_json::from_str(&output_record_content).expect("parse output record");

    let expected_locator = &def.method.outputs["dispatch_summary"].from;
    assert_eq!(
        output_record["locator"].as_str().unwrap(),
        expected_locator,
        "output record locator must match method definition output 'from' field"
    );
}

// ============================================================================
// 5. integration_normalize_only
// ============================================================================

#[test]
fn integration_normalize_only() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: execution_root.clone(),
    };

    execute_normalize(&source).expect("execute_normalize");

    let paths = MethodRunPaths::new(&execution_root);

    // Verify definition.snapshot.yaml exists
    assert!(
        paths.definition_snapshot().exists(),
        "definition.snapshot.yaml must exist after normalize"
    );

    // Verify step.json files exist
    let step_json_path = paths.step_dir("bootstrap", "dispatch").join("step.json");
    assert!(
        step_json_path.exists(),
        "step.json must exist after normalize"
    );

    // Verify NO events.ndjson exists (normalize doesn't create events)
    assert!(
        !paths.events_log().exists(),
        "events.ndjson must NOT exist after normalize-only"
    );

    // Verify NO state.json exists
    assert!(
        !paths.state_json().exists(),
        "state.json must NOT exist after normalize-only"
    );
}

// ============================================================================
// 6. integration_real_method_normalization
// ============================================================================

#[test]
fn integration_real_method_normalization() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: spec_hardening_path(),
        execution_root: execution_root.clone(),
    };

    execute_normalize(&source).expect("execute_normalize on spec-hardening");

    let paths = MethodRunPaths::new(&execution_root);

    // Load the normalized definition
    let def = DefinitionLoader::load(&paths.definition_snapshot()).expect("load snapshot");

    // Verify all 6 phases normalized
    assert_eq!(
        def.method.phases.len(),
        6,
        "spec-hardening must have 6 phases, got {}",
        def.method.phases.len()
    );

    let phase_ids: Vec<&str> = def.method.phases.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(
        phase_ids,
        vec![
            "intake",
            "multi-angle-review",
            "amendment",
            "contracting",
            "planning",
            "validation"
        ]
    );

    // Verify steps have resolved defaults (max_attempts, completion_policy from method defaults)
    // Method defaults: max_attempts=2, completion_policy=all_complete
    for phase in &def.method.phases {
        for step in &phase.steps {
            assert_eq!(
                step.max_attempts, 2,
                "step '{}' should inherit max_attempts=2 from method defaults",
                step.id
            );
            assert_eq!(
                step.completion_policy,
                capacitor_core::method_runner::definition::CompletionPolicy::AllComplete,
                "step '{}' should inherit completion_policy=all_complete from method defaults",
                step.id
            );
        }
    }

    // Verify all 3 action types present: dispatch, interactive, synthesis
    // (pipeline-execute is not used in spec-hardening)
    let action_kinds: Vec<ActionKind> = def
        .method
        .phases
        .iter()
        .flat_map(|p| p.steps.iter())
        .map(|s| s.action)
        .collect();

    assert!(
        action_kinds.contains(&ActionKind::Dispatch),
        "spec-hardening must contain dispatch action steps"
    );
    assert!(
        action_kinds.contains(&ActionKind::Interactive),
        "spec-hardening must contain interactive action steps"
    );
    assert!(
        action_kinds.contains(&ActionKind::Synthesis),
        "spec-hardening must contain synthesis action steps"
    );

    // Verify output locators all resolve (they were validated during normalization,
    // so if we got here without error they're valid). Cross-check the count.
    assert_eq!(
        def.method.outputs.len(),
        5,
        "spec-hardening must declare 5 method-level outputs"
    );

    // Verify each step.json was written
    for phase in &def.method.phases {
        for step in &phase.steps {
            let step_json_path = paths.step_dir(&phase.id, &step.id).join("step.json");
            assert!(
                step_json_path.exists(),
                "step.json must exist for {}/{}",
                phase.id,
                step.id
            );
        }
    }
}

// ============================================================================
// 7. integration_pipeline_blocked
// ============================================================================

#[test]
fn integration_pipeline_blocked() {
    let tmp = tempfile::TempDir::new().unwrap();
    let execution_root = tmp.path().to_path_buf();
    let source = DefinitionSource {
        definition_path: pipeline_blocked_path(),
        execution_root: execution_root.clone(),
    };

    let result = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher);

    // Verify returns PipelineExecuteBlocked error
    let err = result.expect_err("pipeline-blocked.yaml should return an error");
    let err_string = format!("{}", err);

    match &err {
        RunError::PipelineExecuteBlocked(step_id) => {
            // Verify error message mentions the step id
            assert_eq!(
                step_id, "run-child-pipeline",
                "PipelineExecuteBlocked should reference step 'run-child-pipeline'"
            );
        }
        other => {
            panic!("expected RunError::PipelineExecuteBlocked, got: {}", other);
        }
    }

    // Also verify the error display includes the step id
    assert!(
        err_string.contains("run-child-pipeline"),
        "error message '{}' must mention the blocked step id",
        err_string
    );
}

// ============================================================================
// 8. integration_run_isolation
// ============================================================================

#[test]
fn integration_run_isolation() {
    let tmp_a = tempfile::TempDir::new().unwrap();
    let tmp_b = tempfile::TempDir::new().unwrap();

    let source_a = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp_a.path().to_path_buf(),
    };
    let source_b = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp_b.path().to_path_buf(),
    };

    let state_a = execute_run(&source_a, &FakePromptBuilder, &FakeWorkerDispatcher).expect("run A");
    let state_b = execute_run(&source_b, &FakePromptBuilder, &FakeWorkerDispatcher).expect("run B");

    // Verify different run_ids
    assert_ne!(
        state_a.run_id, state_b.run_id,
        "two independent runs must produce different run_ids"
    );

    // Verify separate file trees, no cross-contamination
    let paths_a = MethodRunPaths::new(tmp_a.path());
    let paths_b = MethodRunPaths::new(tmp_b.path());

    // Both have their own state.json
    assert!(paths_a.state_json().exists(), "run A state.json must exist");
    assert!(paths_b.state_json().exists(), "run B state.json must exist");

    // Verify the state.json contents reflect separate run_ids
    let state_a_content = std::fs::read_to_string(paths_a.state_json()).unwrap();
    let state_b_content = std::fs::read_to_string(paths_b.state_json()).unwrap();
    let state_a_json: serde_json::Value = serde_json::from_str(&state_a_content).unwrap();
    let state_b_json: serde_json::Value = serde_json::from_str(&state_b_content).unwrap();

    assert_ne!(
        state_a_json["run_id"], state_b_json["run_id"],
        "state.json files must contain different run_ids"
    );

    // Verify events.ndjson files have different run_ids
    let events_a = recover_events(&paths_a.events_log()).expect("recover events A");
    let events_b = recover_events(&paths_b.events_log()).expect("recover events B");

    assert!(!events_a.is_empty(), "run A must have events");
    assert!(!events_b.is_empty(), "run B must have events");
    assert_ne!(
        events_a[0].run_id, events_b[0].run_id,
        "event run_ids must differ between isolated runs"
    );

    // Verify no file from run A exists under run B's tree and vice versa
    // (This is inherently guaranteed by separate TempDirs, but let's verify
    // the method roots are under different parents)
    assert_ne!(
        paths_a.method_root().canonicalize().unwrap(),
        paths_b.method_root().canonicalize().unwrap(),
        ".method/ roots must be different paths"
    );
}
