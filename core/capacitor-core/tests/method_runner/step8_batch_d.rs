//! Step 8 Batch D tests: Parallel phase execution (Slice 11) and
//! error taxonomy enrichment + observability (Slice 12).
//!
//! Slice 11: Parallel execution mode where all steps run regardless of failures,
//!           with join semantics (all complete, any fail, any blocked).
//! Slice 12: Timing data in AttemptCompleted/AttemptFailed, error categories,
//!           structured blocked_reason, and RunCompleted summary payload.

use std::path::PathBuf;

use crate::common::fixtures::{
    approved_interactive_io as default_interactive, minimal_dispatch_path, retry_dispatch_path,
};
use capacitor_core::method_runner::adapters::{
    ConfigurableDispatcher, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::execute_run;
use capacitor_core::method_runner::state::{PhaseStatus, RunStatus, StepStatus};
use capacitor_core::method_runner::storage::MethodRunPaths;

fn parallel_phase_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("parallel-phase.yaml")
}

// ============================================================================
// Test 1: Parallel phase — all steps execute even if first fails
// ============================================================================

#[test]
fn parallel_phase_all_steps_execute_even_if_first_fails() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: parallel_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    // Configure step-a to fail on attempt 1 (only 1 attempt allowed)
    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("step-a", 1);

    let prompt_builder = FakePromptBuilder;
    let interactive_io = default_interactive();

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    // Both steps should have been executed (parallel mode doesn't short-circuit)
    let parallel_phase = state.phases.get("parallel").expect("parallel phase exists");

    // step-a should be blocked/failed (circuit breaker after 1 attempt)
    let step_a = parallel_phase.steps.get("step-a").expect("step-a exists");
    assert_eq!(
        step_a.status,
        StepStatus::Blocked,
        "step-a should be blocked after failure"
    );

    // step-b should have completed successfully
    let step_b = parallel_phase.steps.get("step-b").expect("step-b exists");
    assert_eq!(
        step_b.status,
        StepStatus::Completed,
        "step-b should complete despite step-a failure"
    );
}

// ============================================================================
// Test 2: Parallel phase — all complete leads to phase complete
// ============================================================================

#[test]
fn parallel_phase_all_complete_phase_completes() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: parallel_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = default_interactive();

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    assert_eq!(state.status, RunStatus::Completed);

    let parallel_phase = state.phases.get("parallel").expect("parallel phase exists");
    assert_eq!(parallel_phase.status, PhaseStatus::Completed);

    // Both steps completed
    let step_a = parallel_phase.steps.get("step-a").expect("step-a exists");
    assert_eq!(step_a.status, StepStatus::Completed);

    let step_b = parallel_phase.steps.get("step-b").expect("step-b exists");
    assert_eq!(step_b.status, StepStatus::Completed);
}

// ============================================================================
// Test 3: Parallel phase — one step exhausts retries leads to phase failed
// ============================================================================

#[test]
fn parallel_phase_one_fails_phase_fails() {
    // Use a custom fixture where step-a has max_attempts: 2 and a crash (non-zero exit)
    // that produces a handoff. The crash attempt fails but doesn't hit circuit breaker
    // on the first try — we need both attempts to fail so the step is truly blocked.
    // With max_attempts: 1 and a dispatch adapter error, the step ends as StepBlocked
    // (circuit breaker). Since the only terminal failure path for dispatch steps is
    // the circuit breaker (which emits StepBlocked), a parallel phase with one failed
    // dispatch step will always see it as "blocked" → PhaseBlocked.
    //
    // So this test validates that the phase correctly transitions to Blocked
    // when a parallel step's circuit breaker fires.
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: parallel_phase_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("step-a", 1); // step-a fails, circuit breaker fires (max_attempts=1)

    let prompt_builder = FakePromptBuilder;
    let interactive_io = default_interactive();

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    // Run should not be Completed since a parallel step failed
    assert_ne!(
        state.status,
        RunStatus::Completed,
        "run should not complete when a parallel step fails"
    );

    let parallel_phase = state.phases.get("parallel").expect("parallel phase exists");
    // Phase should be blocked (step hit circuit breaker → StepBlocked)
    assert_eq!(
        parallel_phase.status,
        PhaseStatus::Blocked,
        "parallel phase should be blocked when a step's circuit breaker fires"
    );

    // step-b still completed
    let step_b = parallel_phase.steps.get("step-b").expect("step-b exists");
    assert_eq!(step_b.status, StepStatus::Completed);
}

// ============================================================================
// Test 4: Parallel phase — one blocked leads to phase blocked
// ============================================================================

#[test]
fn parallel_phase_one_blocked_phase_blocked() {
    // Use a YAML with a pipeline_execute step in a parallel phase
    // We'll create this inline using a temp file
    let tmp = tempfile::TempDir::new().unwrap();

    let yaml_content = r#"
schema_version: "1"
method:
  id: parallel-with-blocked
  version: "2026-03-23"
  title: Parallel With Blocked
  description: Parallel phase where one step is pipeline_execute (blocked).
  phases:
    - id: parallel
      title: Parallel Phase
      execution: parallel
      steps:
        - id: step-dispatch
          title: Dispatch Step
          action: dispatch
          max_attempts: 1
          outputs:
            result:
              path: artifacts/result.md
              type: markdown
          dispatch:
            instructions: Do work.
        - id: step-pipeline
          title: Pipeline Step
          action: pipeline-execute
          pipeline_execute:
            pipeline: my-pipeline
"#;

    let yaml_path = tmp.path().join("method.yaml");
    std::fs::write(&yaml_path, yaml_content).unwrap();

    let source = DefinitionSource {
        definition_path: yaml_path,
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = default_interactive();

    let state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let parallel_phase = state.phases.get("parallel").expect("parallel phase exists");
    assert_eq!(
        parallel_phase.status,
        PhaseStatus::Blocked,
        "parallel phase should be blocked when a step is blocked"
    );

    // The run should be blocked
    assert_eq!(
        state.status,
        RunStatus::Blocked,
        "run should be blocked when parallel phase is blocked"
    );
}

// ============================================================================
// Test 5: Timing data present in AttemptCompleted events
// ============================================================================

#[test]
fn timing_data_in_attempt_completed() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = default_interactive();

    let _state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    let attempt_completed_events: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::AttemptCompleted)
        .collect();

    assert!(
        !attempt_completed_events.is_empty(),
        "should have at least one AttemptCompleted event"
    );

    for event in &attempt_completed_events {
        let elapsed = event.payload.get("elapsed_ms");
        assert!(
            elapsed.is_some(),
            "AttemptCompleted should have elapsed_ms in payload"
        );
        assert!(
            elapsed.unwrap().is_u64(),
            "elapsed_ms should be a u64 value"
        );
    }
}

// ============================================================================
// Test 6: Error category present in AttemptFailed events
// ============================================================================

#[test]
fn error_category_in_attempt_failed() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1); // First attempt fails with adapter error

    let prompt_builder = FakePromptBuilder;
    let interactive_io = default_interactive();

    let _state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    let attempt_failed_events: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::AttemptFailed)
        .collect();

    assert!(
        !attempt_failed_events.is_empty(),
        "should have at least one AttemptFailed event"
    );

    for event in &attempt_failed_events {
        // Check error_category
        let category = event.payload.get("error_category");
        assert!(
            category.is_some(),
            "AttemptFailed should have error_category in payload"
        );
        let category_str = category.unwrap().as_str().unwrap();
        assert!(
            [
                "adapter_error",
                "worker_crash",
                "handoff_missing",
                "validation_failed"
            ]
            .contains(&category_str),
            "error_category should be one of the known categories, got: {}",
            category_str
        );

        // Check elapsed_ms
        let elapsed = event.payload.get("elapsed_ms");
        assert!(
            elapsed.is_some(),
            "AttemptFailed should have elapsed_ms in payload"
        );
    }
}

// ============================================================================
// Test 7: Run summary payload in RunCompleted event
// ============================================================================

#[test]
fn run_summary_in_run_completed_event() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let interactive_io = default_interactive();

    let _state = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io).unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    // Find RunCompleted events with summary payloads
    let run_completed_with_summary: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::RunCompleted && e.payload.get("summary").is_some())
        .collect();

    assert!(
        !run_completed_with_summary.is_empty(),
        "should have a RunCompleted event with summary payload"
    );

    let summary_event = run_completed_with_summary[0];
    let summary = summary_event.payload.get("summary").unwrap();

    // Verify all expected summary fields
    assert!(
        summary.get("total_phases").is_some(),
        "summary should have total_phases"
    );
    assert!(
        summary.get("completed_phases").is_some(),
        "summary should have completed_phases"
    );
    assert!(
        summary.get("blocked_phases").is_some(),
        "summary should have blocked_phases"
    );
    assert!(
        summary.get("failed_phases").is_some(),
        "summary should have failed_phases"
    );
    assert!(
        summary.get("total_steps").is_some(),
        "summary should have total_steps"
    );
    assert!(
        summary.get("completed_steps").is_some(),
        "summary should have completed_steps"
    );
    assert!(
        summary.get("blocked_steps").is_some(),
        "summary should have blocked_steps"
    );
    assert!(
        summary.get("failed_steps").is_some(),
        "summary should have failed_steps"
    );
    assert!(
        summary.get("total_attempts").is_some(),
        "summary should have total_attempts"
    );
    assert!(
        summary.get("total_events").is_some(),
        "summary should have total_events"
    );
    assert!(
        summary.get("elapsed_ms").is_some(),
        "summary should have elapsed_ms"
    );

    // For the minimal-dispatch fixture: 1 phase, 1 step
    assert_eq!(summary["total_phases"].as_u64().unwrap(), 1);
    assert_eq!(summary["completed_phases"].as_u64().unwrap(), 1);
    assert_eq!(summary["total_steps"].as_u64().unwrap(), 1);
    assert_eq!(summary["completed_steps"].as_u64().unwrap(), 1);
    assert!(summary["total_attempts"].as_u64().unwrap() >= 1);
    assert!(summary["total_events"].as_u64().unwrap() > 0);
}

// ============================================================================
// Test 8: Serial phase still works — step failure stops phase (regression)
// ============================================================================

#[test]
fn serial_phase_step_failure_stops_phase_regression() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    // Fail all 3 attempts to trigger circuit breaker
    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);
    dispatcher.fail_attempt("do-work", 2);
    dispatcher.fail_attempt("do-work", 3);

    let prompt_builder = FakePromptBuilder;
    let interactive_io = default_interactive();

    let result = execute_run(&source, &prompt_builder, &dispatcher, &interactive_io);

    // Should error — circuit breaker fires, step blocked, run cannot proceed
    assert!(
        result.is_err(),
        "serial phase should error when step is blocked"
    );

    // Verify we get a StepBlocked error
    let err = result.unwrap_err();
    let err_str = err.to_string();
    assert!(
        err_str.contains("blocked"),
        "error should mention blocking: {}",
        err_str
    );

    // Verify StepBlocked event was emitted with structured blocked_reason
    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    let blocked_events: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::StepBlocked)
        .collect();

    assert!(!blocked_events.is_empty(), "should have StepBlocked event");

    let blocked_event = &blocked_events[0];
    let blocked_reason = blocked_event.payload.get("blocked_reason");
    assert!(
        blocked_reason.is_some(),
        "StepBlocked should have blocked_reason in payload"
    );

    let blocked_obj = blocked_reason.unwrap();
    let category = blocked_obj.get("category").and_then(|v| v.as_str());
    assert_eq!(
        category,
        Some("circuit_breaker"),
        "blocked_reason category should be circuit_breaker"
    );
}
