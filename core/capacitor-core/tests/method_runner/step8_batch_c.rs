//! Step 8 Batch C tests: Phase gates (Slice 9) and resume/reconciliation (Slice 10).
//!
//! Slice 9: Gate evaluation after phase steps complete, gate outcomes, GateEvaluated events.
//! Slice 10: Resume from events, reconcile orphan artifacts, state rebuild.

use std::path::PathBuf;

use crate::common::fixtures::minimal_dispatch_path;
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::{execute_run, RunError};
use capacitor_core::method_runner::resume::resume_run;
use capacitor_core::method_runner::state::{rebuild_state, PhaseStatus, RunStatus};
use capacitor_core::method_runner::storage::MethodRunPaths;

fn gated_phase_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("gated-phase.yaml")
}

fn gated_outputs_present_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("gated-outputs-present.yaml")
}

fn gated_pipeline_clean_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("gated-pipeline-clean.yaml")
}

// ============================================================================
// Slice 9: Approval gate — approved → phase completes
// ============================================================================

#[test]
fn approval_gate_approved_phase_completes() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: gated_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    // Gate will prompt via InteractiveIO — respond with "approved"
    let interactive_io = FakeInteractiveIO::new("approved");

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    assert_eq!(state.status, RunStatus::Completed);
    let build_phase = state.phases.get("build").expect("build phase exists");
    assert_eq!(build_phase.status, PhaseStatus::Completed);

    // Verify gate result was recorded
    let gate_result = build_phase
        .gate_result
        .as_ref()
        .expect("gate result exists");
    assert_eq!(gate_result.gate_id, "build-gate");
    assert_eq!(gate_result.gate_type, "approval");
    assert_eq!(gate_result.outcome, "approved");
}

// ============================================================================
// Slice 9: Approval gate — rejected → phase blocked
// ============================================================================

#[test]
fn approval_gate_rejected_phase_blocked() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: gated_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    // Gate will prompt via InteractiveIO — respond with "rejected"
    let interactive_io = FakeInteractiveIO::new("rejected");

    let result = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io);
    assert!(result.is_err());
    let err = result.unwrap_err();
    match err {
        RunError::PhaseGateBlocked {
            phase_id,
            gate_id,
            reason,
        } => {
            assert_eq!(phase_id, "build");
            assert_eq!(gate_id, "build-gate");
            assert_eq!(reason, "gate rejected");
        }
        other => panic!("expected PhaseGateBlocked, got: {other:?}"),
    }

    // Verify state on disk shows phase blocked
    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();
    let state = capacitor_core::method_runner::state::project(&events).unwrap();
    let build_phase = state.phases.get("build").expect("build phase exists");
    assert_eq!(build_phase.status, PhaseStatus::Blocked);

    // Gate result should be "rejected"
    let gate_result = build_phase
        .gate_result
        .as_ref()
        .expect("gate result exists");
    assert_eq!(gate_result.outcome, "rejected");
}

// ============================================================================
// Slice 9: outputs_present gate — all outputs present → approved
// ============================================================================

#[test]
fn outputs_present_gate_all_present_approved() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: gated_outputs_present_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    assert_eq!(state.status, RunStatus::Completed);
    let build_phase = state.phases.get("build").expect("build phase exists");
    assert_eq!(build_phase.status, PhaseStatus::Completed);

    let gate_result = build_phase
        .gate_result
        .as_ref()
        .expect("gate result exists");
    assert_eq!(gate_result.gate_id, "outputs-gate");
    assert_eq!(gate_result.gate_type, "outputs_present");
    assert_eq!(gate_result.outcome, "approved");
}

// ============================================================================
// Slice 9: outputs_present gate — missing output → validation_failed
// ============================================================================

#[test]
fn outputs_present_gate_missing_output_validation_failed() {
    let tmp = tempfile::TempDir::new().unwrap();

    // Create a fixture with a gate that checks for an output that doesn't exist
    let yaml = r#"schema_version: "1"
method:
  id: gated-missing-output
  version: "2026-03-23"
  title: Gated Missing Output
  phases:
    - id: build
      title: Build
      execution: serial
      gate:
        id: outputs-gate
        type: outputs_present
        outputs:
          - nonexistent_output
      steps:
        - id: implement
          title: Implement
          action: dispatch
          outputs:
            dispatch_summary:
              path: artifacts/dispatch-summary.md
              type: markdown
          dispatch:
            instructions: Implement.
"#;
    let def_path = tmp.path().join("method.yaml");
    std::fs::write(&def_path, yaml).unwrap();

    let source = DefinitionSource {
        definition_path: def_path,
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let result = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io);
    assert!(result.is_err());

    let err = result.unwrap_err();
    match err {
        RunError::PhaseGateBlocked {
            phase_id,
            gate_id,
            reason,
        } => {
            assert_eq!(phase_id, "build");
            assert_eq!(gate_id, "outputs-gate");
            assert!(
                reason.contains("validation failed"),
                "reason should mention validation_failed: {reason}"
            );
            assert!(
                reason.contains("nonexistent_output"),
                "reason should mention the missing output: {reason}"
            );
        }
        other => panic!("expected PhaseGateBlocked, got: {other:?}"),
    }

    // Verify gate event shows validation_failed
    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();
    let state = capacitor_core::method_runner::state::project(&events).unwrap();
    let gate_result = state
        .phases
        .get("build")
        .unwrap()
        .gate_result
        .as_ref()
        .unwrap();
    assert_eq!(gate_result.outcome, "validation_failed");
}

// ============================================================================
// Slice 9: pipeline_clean gate — v1-deferred, always blocked
// ============================================================================

#[test]
fn pipeline_clean_gate_blocked() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: gated_pipeline_clean_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let result = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io);
    assert!(result.is_err());

    let err = result.unwrap_err();
    match err {
        RunError::PhaseGateBlocked {
            phase_id,
            gate_id,
            reason,
        } => {
            assert_eq!(phase_id, "build");
            assert_eq!(gate_id, "pipeline-gate");
            assert!(
                reason.contains("pipeline_clean requires pipeline-execute"),
                "reason should mention v1 limitation: {reason}"
            );
        }
        other => panic!("expected PhaseGateBlocked, got: {other:?}"),
    }

    // Verify gate event shows waiting outcome
    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();
    let state = capacitor_core::method_runner::state::project(&events).unwrap();
    let gate_result = state
        .phases
        .get("build")
        .unwrap()
        .gate_result
        .as_ref()
        .unwrap();
    assert_eq!(gate_result.outcome, "waiting");
}

// ============================================================================
// Slice 9: GateEvaluated event emitted with correct payload
// ============================================================================

#[test]
fn gate_evaluated_event_emitted_with_correct_payload() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: gated_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let _state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    // Find the GateEvaluated event
    let gate_events: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::GateEvaluated)
        .collect();
    assert_eq!(gate_events.len(), 1, "exactly one GateEvaluated event");

    let gate_event = gate_events[0];
    assert_eq!(gate_event.phase_id.as_deref(), Some("build"));
    assert_eq!(
        gate_event.payload.get("gate_id").and_then(|v| v.as_str()),
        Some("build-gate")
    );
    assert_eq!(
        gate_event.payload.get("gate_type").and_then(|v| v.as_str()),
        Some("approval")
    );
    assert_eq!(
        gate_event.payload.get("outcome").and_then(|v| v.as_str()),
        Some("approved")
    );
}

// ============================================================================
// Slice 10: Clean resume — stop and restart, state identical
// ============================================================================

#[test]
fn resume_clean_run_state_identical() {
    // First, do a complete run
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let original_state =
        execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();
    assert_eq!(original_state.status, RunStatus::Completed);

    // Resume the completed run — should return same state
    let resumed_state =
        resume_run(tmp.path(), &prompt_builder, &dispatcher, &interactive_io).unwrap();
    assert_eq!(resumed_state.status, RunStatus::Completed);
    assert_eq!(resumed_state.run_id, original_state.run_id);
    assert_eq!(
        resumed_state.phases.keys().collect::<Vec<_>>(),
        original_state.phases.keys().collect::<Vec<_>>()
    );
}

// ============================================================================
// Slice 10: state.json missing → rebuild from events
// ============================================================================

#[test]
fn resume_rebuilds_state_from_events_when_state_json_missing() {
    // Do a complete run
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let original_state =
        execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    // Delete state.json
    let paths = MethodRunPaths::new(tmp.path());
    let state_json_path = paths.state_json();
    assert!(
        state_json_path.exists(),
        "state.json should exist after run"
    );
    std::fs::remove_file(&state_json_path).unwrap();
    assert!(
        !state_json_path.exists(),
        "state.json should be deleted now"
    );

    // Rebuild state purely from events
    let rebuilt_state = rebuild_state(&paths.events_log()).unwrap();
    assert_eq!(rebuilt_state.status, RunStatus::Completed);
    assert_eq!(rebuilt_state.run_id, original_state.run_id);

    // Resume should also work
    let resumed_state =
        resume_run(tmp.path(), &prompt_builder, &dispatcher, &interactive_io).unwrap();
    assert_eq!(resumed_state.status, RunStatus::Completed);
    assert_eq!(resumed_state.run_id, original_state.run_id);

    // state.json should be restored
    assert!(
        state_json_path.exists(),
        "state.json should be restored by resume"
    );
}

// ============================================================================
// Slice 10: Orphan handoff detected and reconciled
// ============================================================================

#[test]
fn resume_reconciles_orphan_handoff() {
    // Do a complete run first so we have valid events and handoff artifacts
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = FakeInteractiveIO::new("approved");

    let _original_state =
        execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let events_path = paths.events_log();

    // Read events and truncate at the HandoffIngested event.
    // This simulates a crash after the worker produced the handoff artifact
    // but before the HandoffIngested event was written.
    let events = recover_events(&events_path).unwrap();

    // Find the index of the first HandoffIngested event
    let handoff_idx = events
        .iter()
        .position(|e| e.kind == MethodEventKind::HandoffIngested)
        .expect("run should have produced a HandoffIngested event");

    // Keep only events before the HandoffIngested (simulating a crash at that point)
    let truncated_events = &events[..handoff_idx];
    assert!(
        !truncated_events.is_empty(),
        "should have events before HandoffIngested"
    );

    // Rewrite truncated events
    {
        use std::io::Write;
        let mut file = std::fs::File::create(&events_path).unwrap();
        for event in truncated_events {
            let json = serde_json::to_string(event).unwrap();
            writeln!(file, "{json}").unwrap();
        }
    }

    // Verify the handoff artifact still exists on disk (orphan)
    let handoffs_dir = paths.method_root().join("artifacts").join("handoffs");
    assert!(handoffs_dir.is_dir(), "handoffs dir should exist");
    let handoff_files: Vec<_> = std::fs::read_dir(&handoffs_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "md"))
        .collect();
    assert!(
        !handoff_files.is_empty(),
        "at least one orphan handoff file should exist"
    );

    // Verify the state after truncation has no handoff_received for workers
    let state_before = rebuild_state(&events_path).unwrap();
    // The run should NOT be complete (we truncated mid-flow)
    assert_ne!(
        state_before.status,
        RunStatus::Completed,
        "run should not be complete after truncation"
    );

    // Resume should reconcile the orphan handoff and complete the run
    let resumed_state =
        resume_run(tmp.path(), &prompt_builder, &dispatcher, &interactive_io).unwrap();
    assert_eq!(resumed_state.status, RunStatus::Completed);

    // Read events after resume — should now contain reconciliation events
    let events_after = recover_events(&events_path).unwrap();
    let reconciled_handoff_events: Vec<_> = events_after
        .iter()
        .filter(|e| {
            e.kind == MethodEventKind::HandoffIngested && e.payload.get("reconciled").is_some()
        })
        .collect();
    assert!(
        !reconciled_handoff_events.is_empty(),
        "should have at least one reconciled HandoffIngested event"
    );
}
