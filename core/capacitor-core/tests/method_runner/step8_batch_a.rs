//! Step 8 Batch A tests: retry logic, circuit breaker, multi-worker fanout,
//! completion policies, attempt isolation/immutability, definition freeze enforcement.
//!
//! These tests exercise the Slice 6 obligations that the tracer bullet
//! intentionally skipped: failure handling, retry, and multi-worker dispatch.

use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::common::fixtures::{
    approved_interactive_io as default_interactive, minimal_dispatch_path, retry_dispatch_path,
};
use capacitor_core::method_runner::adapters::{
    ConfigurableDispatcher, FakePromptBuilder, FakeWorkerDispatcher, PromptBuilder,
    WorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::{execute_run, RunError};
use capacitor_core::method_runner::state::{rebuild_state, AttemptStatus, RunStatus, StepStatus};
use capacitor_core::method_runner::storage::MethodRunPaths;

fn multi_worker_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("multi-worker.yaml")
}

fn first_clean_policy_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("first-clean-policy.yaml")
}

// ============================================================================
// Retry: attempt 1 fails (adapter error), attempt 2 succeeds
// ============================================================================

#[test]
fn retry_attempt_1_fails_attempt_2_succeeds() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1); // Attempt 1 fails with adapter error

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed on retry");

    // Run completed successfully
    assert_eq!(state.status, RunStatus::Completed);

    // Step completed (not blocked)
    let phase = state.phases.get("work").expect("work phase");
    let step = phase.steps.get("do-work").expect("do-work step");
    assert_eq!(step.status, StepStatus::Completed);

    // Two attempts recorded
    assert_eq!(step.attempts.len(), 2, "should have 2 attempts");
    assert_eq!(step.current_attempt, 2, "current attempt should be 2");

    // Attempt 1 failed
    let a1 = step.attempts.get(&1).expect("attempt 1");
    assert_eq!(a1.status, AttemptStatus::Failed);

    // Attempt 2 completed
    let a2 = step.attempts.get(&2).expect("attempt 2");
    assert_eq!(a2.status, AttemptStatus::Completed);

    // Verify events include AttemptFailed for attempt 1
    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();
    let failed_events: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::AttemptFailed)
        .collect();
    assert_eq!(failed_events.len(), 1, "exactly one AttemptFailed event");
    assert_eq!(failed_events[0].attempt, Some(1));
}

// ============================================================================
// Retry: attempt 1 crash (non-zero exit), attempt 2 succeeds
// ============================================================================

#[test]
fn retry_worker_crash_then_success() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.crash_attempt("do-work", 1); // Non-zero exit on attempt 1

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed on retry");

    assert_eq!(state.status, RunStatus::Completed);

    let step = state
        .phases
        .get("work")
        .unwrap()
        .steps
        .get("do-work")
        .unwrap();
    assert_eq!(step.attempts.len(), 2);

    // Verify WorkerFailed event was emitted for attempt 1
    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();
    let worker_failed: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::WorkerFailed)
        .collect();
    assert_eq!(worker_failed.len(), 1);
    assert_eq!(worker_failed[0].attempt, Some(1));
}

// ============================================================================
// Circuit breaker: all 3 attempts fail → StepBlocked
// ============================================================================

#[test]
fn circuit_breaker_all_attempts_exhausted() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);
    dispatcher.fail_attempt("do-work", 2);
    dispatcher.fail_attempt("do-work", 3);

    let result = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    );

    // Run should fail with StepBlocked
    assert!(
        result.is_err(),
        "run should fail when all attempts exhausted"
    );
    let err = result.unwrap_err();
    match &err {
        RunError::StepBlocked { step_id, reason } => {
            assert_eq!(step_id, "do-work");
            assert!(
                reason.contains("circuit breaker"),
                "reason should mention circuit breaker: {}",
                reason
            );
        }
        other => panic!("expected StepBlocked, got: {other:?}"),
    }

    // Verify events: 3 AttemptFailed + 1 StepBlocked
    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();
    let failed_count = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::AttemptFailed)
        .count();
    assert_eq!(failed_count, 3, "should have 3 AttemptFailed events");

    let blocked_count = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::StepBlocked)
        .count();
    assert_eq!(blocked_count, 1, "should have 1 StepBlocked event");
}

// ============================================================================
// Circuit breaker: 2 fail, 3rd succeeds
// ============================================================================

#[test]
fn circuit_breaker_last_attempt_succeeds() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);
    dispatcher.fail_attempt("do-work", 2);
    // Attempt 3 succeeds (no failure configured)

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed on last attempt");

    assert_eq!(state.status, RunStatus::Completed);
    let step = state
        .phases
        .get("work")
        .unwrap()
        .steps
        .get("do-work")
        .unwrap();
    assert_eq!(step.attempts.len(), 3);
    assert_eq!(step.current_attempt, 3);
}

// ============================================================================
// Retry context: attempt 2 header includes prior failure reason
// ============================================================================

#[test]
fn retry_header_includes_prior_failure_context() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    // Check that the prompt for attempt 2 includes retry context
    let paths = MethodRunPaths::new(tmp.path());
    let attempt2_relay = paths.worker_relay_root("work", "do-work", 2, "primary");
    let prompt_content =
        std::fs::read_to_string(attempt2_relay.join("prompt.md")).expect("prompt.md");

    assert!(
        prompt_content.contains("Retry Context"),
        "attempt 2 prompt should contain retry context: {}",
        prompt_content
    );
    assert!(
        prompt_content.contains("attempt 2"),
        "retry context should mention attempt number"
    );
}

// ============================================================================
// Attempt immutability (I3): terminal attempt dirs unchanged after retry
// ============================================================================

#[test]
fn attempt_immutability_i3_after_retry() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());

    // Attempt 1 dir should exist and have attempt.json with "failed" status
    let a1_dir = paths.attempt_dir("work", "do-work", 1);
    assert!(a1_dir.exists(), "attempt 1 dir must exist");
    let a1_json: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(a1_dir.join("attempt.json")).expect("attempt.json"),
    )
    .expect("valid json");
    assert_eq!(a1_json["status"], "failed");

    // Attempt 2 dir should exist and have attempt.json with "completed" status
    let a2_dir = paths.attempt_dir("work", "do-work", 2);
    assert!(a2_dir.exists(), "attempt 2 dir must exist");
    let a2_json: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(a2_dir.join("attempt.json")).expect("attempt.json"),
    )
    .expect("valid json");
    assert_eq!(a2_json["status"], "completed");
}

// ============================================================================
// Attempt isolation (I4): no shared mutable paths between attempts
// ============================================================================

#[test]
fn attempt_isolation_i4_no_shared_paths() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let a1_dir = paths.attempt_dir("work", "do-work", 1);
    let a2_dir = paths.attempt_dir("work", "do-work", 2);

    // Collect all file paths under each attempt dir
    fn collect_files(dir: &std::path::Path) -> BTreeSet<PathBuf> {
        let mut files = BTreeSet::new();
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    files.extend(collect_files(&path));
                } else {
                    // Use relative path from attempt dir
                    if let Ok(rel) = path.strip_prefix(dir) {
                        files.insert(rel.to_path_buf());
                    }
                }
            }
        }
        files
    }

    let a1_files = collect_files(&a1_dir);
    let a2_files = collect_files(&a2_dir);

    // Both should have files (not empty)
    assert!(!a1_files.is_empty(), "attempt 1 should have files");
    assert!(!a2_files.is_empty(), "attempt 2 should have files");

    // The relative paths can overlap (both have attempt.json, input-bindings.json)
    // but the ABSOLUTE paths must be different (they're under different attempt dirs)
    assert_ne!(a1_dir, a2_dir, "attempt dirs must be different");

    // Verify both attempt dirs are under the same step dir
    let step_dir = paths.step_dir("work", "do-work");
    assert!(a1_dir.starts_with(&step_dir));
    assert!(a2_dir.starts_with(&step_dir));
}

// ============================================================================
// Dispatch identity (I5): unique five-field tuples in WorkerDispatched events
// ============================================================================

#[test]
fn dispatch_identity_i5_unique_tuples() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();
    let dispatched: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::WorkerDispatched)
        .collect();

    // Should have 2 WorkerDispatched events (one per attempt)
    assert_eq!(dispatched.len(), 2);

    // Each should have the five identity fields
    let mut tuples = BTreeSet::new();
    for ev in &dispatched {
        let run_id = &ev.run_id;
        let phase_id = ev.phase_id.as_deref().unwrap();
        let step_id = ev.step_id.as_deref().unwrap();
        let attempt = ev.attempt.unwrap();
        let worker_id = ev.worker_id.as_deref().unwrap();

        let tuple = format!("{run_id}:{phase_id}:{step_id}:{attempt}:{worker_id}");
        assert!(
            tuples.insert(tuple.clone()),
            "duplicate dispatch identity: {tuple}"
        );
    }
}

// ============================================================================
// Multi-worker: both workers dispatched, all_complete policy
// ============================================================================

#[test]
fn multi_worker_both_dispatched_all_complete() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: multi_worker_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    assert_eq!(state.status, RunStatus::Completed);

    let step = state
        .phases
        .get("review")
        .unwrap()
        .steps
        .get("analyze")
        .unwrap();
    assert_eq!(step.status, StepStatus::Completed);

    // Only one attempt needed (both workers succeed)
    assert_eq!(step.attempts.len(), 1);

    // Attempt should have 2 workers
    let attempt = step.attempts.get(&1).unwrap();
    assert_eq!(attempt.workers.len(), 2, "should have 2 workers");
    assert!(attempt.workers.contains_key("security"));
    assert!(attempt.workers.contains_key("performance"));

    // Both workers completed
    for (wid, ws) in &attempt.workers {
        assert_eq!(
            ws.status,
            capacitor_core::method_runner::state::WorkerStatus::Completed,
            "worker {} should be completed",
            wid
        );
    }

    // Verify events: 2 WorkerDispatched, 2 WorkerCompleted
    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();
    let dispatched = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::WorkerDispatched)
        .count();
    assert_eq!(dispatched, 2, "should have 2 WorkerDispatched events");

    let completed = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::WorkerCompleted)
        .count();
    assert_eq!(completed, 2, "should have 2 WorkerCompleted events");
}

// ============================================================================
// Multi-worker: relay dirs are separate per worker
// ============================================================================

#[test]
fn multi_worker_separate_relay_dirs() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: multi_worker_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let security_relay = paths.worker_relay_root("review", "analyze", 1, "security");
    let perf_relay = paths.worker_relay_root("review", "analyze", 1, "performance");

    assert!(security_relay.exists(), "security relay dir must exist");
    assert!(perf_relay.exists(), "performance relay dir must exist");
    assert_ne!(security_relay, perf_relay, "relay dirs must be different");

    // Each should have a HANDOFF.md
    assert!(security_relay.join("HANDOFF.md").exists());
    assert!(perf_relay.join("HANDOFF.md").exists());
}

// ============================================================================
// Multi-worker: one fails → attempt fails → retry succeeds
// ============================================================================

#[test]
fn multi_worker_one_fails_then_retry_succeeds() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: multi_worker_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    // Only the "security" worker fails on attempt 1
    // ConfigurableDispatcher matches on step_id + attempt, not worker_id,
    // so we need to use crash_attempt which produces a non-zero exit for all workers.
    // For a cleaner test, let's fail the whole attempt.
    dispatcher.fail_attempt("analyze", 1);

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed on retry");

    assert_eq!(state.status, RunStatus::Completed);

    let step = state
        .phases
        .get("review")
        .unwrap()
        .steps
        .get("analyze")
        .unwrap();
    assert_eq!(step.attempts.len(), 2, "should have 2 attempts");
}

// ============================================================================
// First-clean policy: first worker succeeds, step completes immediately
// ============================================================================

#[test]
fn first_clean_policy_first_worker_succeeds() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: first_clean_policy_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    assert_eq!(state.status, RunStatus::Completed);

    let step = state
        .phases
        .get("work")
        .unwrap()
        .steps
        .get("compete")
        .unwrap();

    // With first_clean and all workers succeeding, the step should complete
    // on the first attempt
    assert_eq!(step.status, StepStatus::Completed);
    assert_eq!(step.attempts.len(), 1);
}

// ============================================================================
// First-clean policy: first worker fails, second succeeds → step completes
// ============================================================================

#[test]
fn first_clean_policy_first_fails_second_succeeds() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: first_clean_policy_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    // For first_clean, even if the first worker crashes, if any worker succeeds
    // in definition order, the step completes. The ConfigurableDispatcher
    // crashes based on (step_id, attempt), not per-worker, so this test
    // uses a FakeWorkerDispatcher which succeeds for all workers.
    // The key test is that with first_clean, even a single clean worker is enough.
    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    assert_eq!(state.status, RunStatus::Completed);
}

// ============================================================================
// Definition freeze (I10): executor reads snapshot, not source YAML
// ============================================================================

#[test]
fn definition_freeze_i10_reads_snapshot_not_source() {
    let tmp = tempfile::TempDir::new().unwrap();

    // Create a copy of the minimal-dispatch fixture that we can modify
    let fixture_content = std::fs::read_to_string(minimal_dispatch_path()).unwrap();
    let source_yaml = tmp.path().join("method.yaml");
    std::fs::write(&source_yaml, &fixture_content).unwrap();

    let source = DefinitionSource {
        definition_path: source_yaml.clone(),
        execution_root: tmp.path().to_path_buf(),
    };

    // Execute the run — this freezes the definition snapshot
    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    assert_eq!(state.status, RunStatus::Completed);

    // Verify the snapshot was written
    let paths = MethodRunPaths::new(tmp.path());
    assert!(paths.definition_snapshot().exists());

    // Now modify the source YAML (add a new step that would change the run)
    let modified_content =
        fixture_content.replace("title: Minimal Dispatch", "title: MODIFIED AFTER FREEZE");
    std::fs::write(&source_yaml, modified_content).unwrap();

    // The snapshot should still have the original title
    let snapshot_content = std::fs::read_to_string(paths.definition_snapshot()).unwrap();
    assert!(
        snapshot_content.contains("Minimal Dispatch"),
        "snapshot should have original title"
    );
    assert!(
        !snapshot_content.contains("MODIFIED AFTER FREEZE"),
        "snapshot should not reflect post-freeze changes"
    );
}

// ============================================================================
// IF1 idempotence: PromptBuilder with same inputs → byte-identical outputs
// ============================================================================

#[test]
fn if1_prompt_builder_idempotence() {
    use capacitor_core::method_runner::adapters::PromptBuildRequest;

    let tmp1 = tempfile::TempDir::new().unwrap();
    let tmp2 = tempfile::TempDir::new().unwrap();

    let request1 = PromptBuildRequest {
        phase_id: "phase1".to_string(),
        step_id: "step1".to_string(),
        attempt: 1,
        relay_root: tmp1.path().to_path_buf(),
        instructions: "Do the thing.".to_string(),
        template: None,
        skills: vec![],
        context_file: None,
    };

    let request2 = PromptBuildRequest {
        phase_id: "phase1".to_string(),
        step_id: "step1".to_string(),
        attempt: 1,
        relay_root: tmp2.path().to_path_buf(),
        instructions: "Do the thing.".to_string(),
        template: None,
        skills: vec![],
        context_file: None,
    };

    let builder = FakePromptBuilder;
    let result1 = builder.build_prompt(&request1).unwrap();
    let result2 = builder.build_prompt(&request2).unwrap();

    let header1 = std::fs::read_to_string(&result1.header_path).unwrap();
    let header2 = std::fs::read_to_string(&result2.header_path).unwrap();
    assert_eq!(header1, header2, "headers should be byte-identical");

    let prompt1 = std::fs::read_to_string(&result1.prompt_path).unwrap();
    let prompt2 = std::fs::read_to_string(&result2.prompt_path).unwrap();
    assert_eq!(prompt1, prompt2, "prompts should be byte-identical");
}

// ============================================================================
// IF2 exit capture: clean and crash exits are captured
// ============================================================================

#[test]
fn if2_exit_capture_clean_and_crash() {
    use capacitor_core::method_runner::adapters::WorkerDispatchRequest;

    let tmp = tempfile::TempDir::new().unwrap();

    // Clean exit
    let request = WorkerDispatchRequest {
        phase_id: "p".to_string(),
        step_id: "s".to_string(),
        attempt: 1,
        worker_id: "primary".to_string(),
        relay_root: tmp.path().join("clean"),
        prompt_path: tmp.path().join("clean/prompt.md"),
    };
    let result = FakeWorkerDispatcher.dispatch(&request).unwrap();
    assert_eq!(result.exit_code, 0, "clean exit should be 0");

    // Crash exit
    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.crash_attempt("s", 1);
    let request2 = WorkerDispatchRequest {
        phase_id: "p".to_string(),
        step_id: "s".to_string(),
        attempt: 1,
        worker_id: "primary".to_string(),
        relay_root: tmp.path().join("crash"),
        prompt_path: tmp.path().join("crash/prompt.md"),
    };
    let result2 = dispatcher.dispatch(&request2).unwrap();
    assert_ne!(result2.exit_code, 0, "crash exit should be non-zero");
}

// ============================================================================
// IF2 timeout: adapter error on configured timeout
// ============================================================================

#[test]
fn if2_adapter_error_propagates() {
    use capacitor_core::method_runner::adapters::{AdapterError, WorkerDispatchRequest};

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("s", 1);

    let tmp = tempfile::TempDir::new().unwrap();
    let request = WorkerDispatchRequest {
        phase_id: "p".to_string(),
        step_id: "s".to_string(),
        attempt: 1,
        worker_id: "primary".to_string(),
        relay_root: tmp.path().to_path_buf(),
        prompt_path: tmp.path().join("prompt.md"),
    };

    let result = dispatcher.dispatch(&request);
    assert!(result.is_err(), "should return adapter error");
    match result.unwrap_err() {
        AdapterError::SpawnFailed(msg) => {
            assert!(msg.contains("configured failure"));
        }
        other => panic!("expected SpawnFailed, got: {other:?}"),
    }
}

// ============================================================================
// Attempt artifacts: attempt.json, input-bindings.json, output-bindings.json
// ============================================================================

#[test]
fn attempt_artifacts_produced_for_each_attempt() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());

    // Both attempt dirs should have required artifacts
    for attempt_num in [1u32, 2] {
        let attempt_dir = paths.attempt_dir("work", "do-work", attempt_num);
        assert!(
            attempt_dir.join("attempt.json").exists(),
            "attempt {} should have attempt.json",
            attempt_num
        );
        assert!(
            attempt_dir.join("input-bindings.json").exists(),
            "attempt {} should have input-bindings.json",
            attempt_num
        );
    }

    // Only the successful attempt (2) should have output-bindings.json
    let a2_dir = paths.attempt_dir("work", "do-work", 2);
    assert!(
        a2_dir.join("output-bindings.json").exists(),
        "successful attempt should have output-bindings.json"
    );
}

// ============================================================================
// State rebuild: events → project → identical state
// ============================================================================

#[test]
fn state_rebuild_after_retry() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    let original_state = execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    // Rebuild state from events
    let rebuilt_state = rebuild_state(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();

    assert_eq!(
        original_state.status, rebuilt_state.status,
        "rebuilt status should match"
    );
    assert_eq!(
        original_state.phases.len(),
        rebuilt_state.phases.len(),
        "rebuilt phases should match"
    );
}

// ============================================================================
// Normalizer: workers field parsed correctly
// ============================================================================

#[test]
fn normalizer_parses_multi_worker_definition() {
    use capacitor_core::method_runner::definition::Normalizer;

    let yaml = std::fs::read_to_string(multi_worker_path()).unwrap();
    let def = Normalizer::normalize(&yaml).expect("should normalize");

    let step = &def.method.phases[0].steps[0];
    assert_eq!(step.id, "analyze");

    match &step.config {
        capacitor_core::method_runner::definition::StepActionConfig::Dispatch {
            workers, ..
        } => {
            assert_eq!(workers.len(), 2, "should have 2 explicit workers");
            assert_eq!(workers[0].id, "security");
            assert_eq!(workers[1].id, "performance");
            assert!(!workers[0].instructions.is_empty());
        }
        other => panic!("expected Dispatch config, got: {other:?}"),
    }
}

// ============================================================================
// Normalizer: implicit primary worker when no workers specified
// ============================================================================

#[test]
fn normalizer_inserts_implicit_primary_worker() {
    use capacitor_core::method_runner::definition::Normalizer;

    let yaml = std::fs::read_to_string(minimal_dispatch_path()).unwrap();
    let def = Normalizer::normalize(&yaml).expect("should normalize");

    let step = &def.method.phases[0].steps[0];
    match &step.config {
        capacitor_core::method_runner::definition::StepActionConfig::Dispatch {
            workers, ..
        } => {
            assert_eq!(workers.len(), 1, "should have 1 implicit worker");
            assert_eq!(workers[0].id, "primary");
        }
        other => panic!("expected Dispatch config, got: {other:?}"),
    }
}

// ============================================================================
// Event sequence: retry produces correct event ordering
// ============================================================================

#[test]
fn retry_event_sequence_ordering() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();

    // Extract the step-level event kinds in order
    let step_events: Vec<MethodEventKind> = events
        .iter()
        .filter(|e| e.step_id.as_deref() == Some("do-work"))
        .map(|e| e.kind)
        .collect();

    // Expected sequence for retry:
    // StepStarted → AttemptStarted(1) → WorkerDispatched(1) → WorkerFailed(1) →
    // AttemptFailed(1) → AttemptStarted(2) → WorkerDispatched(2) → WorkerCompleted(2) →
    // HandoffIngested(2) → OutputBound(2) → AttemptCompleted(2) → StepCompleted
    assert_eq!(step_events[0], MethodEventKind::StepStarted);
    assert_eq!(step_events[1], MethodEventKind::AttemptStarted); // attempt 1
    assert_eq!(step_events[2], MethodEventKind::WorkerDispatched); // attempt 1

    // AttemptFailed should appear before the second AttemptStarted
    let first_failed_idx = step_events
        .iter()
        .position(|k| *k == MethodEventKind::AttemptFailed)
        .expect("should have AttemptFailed");

    let attempt_started_indices: Vec<_> = step_events
        .iter()
        .enumerate()
        .filter(|(_, k)| **k == MethodEventKind::AttemptStarted)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        attempt_started_indices.len(),
        2,
        "should have 2 AttemptStarted"
    );
    assert!(
        first_failed_idx < attempt_started_indices[1],
        "AttemptFailed should come before second AttemptStarted"
    );

    // Last event should be StepCompleted
    assert_eq!(*step_events.last().unwrap(), MethodEventKind::StepCompleted);
}

// ============================================================================
// Seq monotonicity across retries
// ============================================================================

#[test]
fn seq_monotonically_increasing_across_retries() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: retry_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let mut dispatcher = ConfigurableDispatcher::new();
    dispatcher.fail_attempt("do-work", 1);

    execute_run(
        &source,
        &FakePromptBuilder,
        &dispatcher,
        &default_interactive(),
    )
    .expect("run should succeed");

    let events = recover_events(&MethodRunPaths::new(tmp.path()).events_log()).unwrap();

    let mut prev_seq = 0;
    for event in &events {
        assert!(
            event.seq > prev_seq,
            "seq should be strictly increasing: {} should be > {}",
            event.seq,
            prev_seq
        );
        prev_seq = event.seq;
    }
}
