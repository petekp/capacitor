//! Step 8 Batch B tests: Interactive CLI flags (Slice 7) and synthesis reader logic (Slice 8).
//!
//! Slice 7: Response type validation, prompt persistence, CLI adapter, output binding.
//! Slice 8: Synthesis input resolution, exact event lifecycle, no relay dirs, no dispatch paths.

use std::path::PathBuf;

use crate::common::fixtures::{interactive_only_path, synthesis_only_path};
use capacitor_core::method_runner::adapters::{
    validate_interactive_response, CliInteractiveIO, FakeInteractiveIO, FakePromptBuilder,
    FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::{execute_run, RunError};
use capacitor_core::method_runner::state::RunStatus;
use capacitor_core::method_runner::storage::MethodRunPaths;

fn interactive_approval_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("interactive-approval.yaml")
}

fn dispatch_then_synthesis_path() -> PathBuf {
    crate::common::fixtures::method_fixture_path("dispatch-then-synthesis.yaml")
}

// ============================================================================
// Slice 7: Interactive — approval response_type validates correctly
// ============================================================================

#[test]
fn approval_response_type_accepts_approved() {
    assert!(validate_interactive_response("approval", "approved").is_ok());
    assert!(validate_interactive_response("approval", "Approved").is_ok());
    assert!(validate_interactive_response("approval", "APPROVED").is_ok());
}

#[test]
fn approval_response_type_accepts_rejected() {
    assert!(validate_interactive_response("approval", "rejected").is_ok());
    assert!(validate_interactive_response("approval", "Rejected").is_ok());
    assert!(validate_interactive_response("approval", "REJECTED").is_ok());
}

#[test]
fn approval_response_type_rejects_invalid() {
    assert!(validate_interactive_response("approval", "maybe").is_err());
    assert!(validate_interactive_response("approval", "yes").is_err());
    assert!(validate_interactive_response("approval", "").is_err());
}

// ============================================================================
// Slice 7: Interactive — markdown response_type accepts any non-empty string
// ============================================================================

#[test]
fn markdown_response_type_accepts_any_nonempty() {
    assert!(validate_interactive_response("markdown", "hello").is_ok());
    assert!(validate_interactive_response("markdown", "# Header\n\nBody text").is_ok());
    assert!(validate_interactive_response("markdown", "x").is_ok());
}

#[test]
fn markdown_response_type_rejects_empty() {
    assert!(validate_interactive_response("markdown", "").is_err());
    assert!(validate_interactive_response("markdown", "   ").is_err());
}

// ============================================================================
// Slice 7: Interactive — selection and checklist response_type
// ============================================================================

#[test]
fn selection_response_type_accepts_nonempty() {
    assert!(validate_interactive_response("selection", "option-a").is_ok());
}

#[test]
fn checklist_response_type_accepts_nonempty() {
    assert!(validate_interactive_response("checklist", "item1,item2").is_ok());
}

// ============================================================================
// Slice 7: Interactive — prompt persisted before response captured
// ============================================================================

#[test]
fn prompt_persisted_before_response() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO::with_type("approved", "approval");
    let _state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);

    // prompt.txt must exist in the attempt directory
    let prompt_path = attempt_dir.join("prompt.txt");
    assert!(
        prompt_path.exists(),
        "prompt.txt must be persisted in attempt dir"
    );

    let prompt_content = std::fs::read_to_string(&prompt_path).unwrap();
    assert_eq!(
        prompt_content, "Do you approve the draft?",
        "prompt.txt must contain the interactive prompt message"
    );
}

// ============================================================================
// Slice 7: Interactive — response binds to declared output name
// ============================================================================

#[test]
fn interactive_response_binds_to_output_name() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO::with_type("approved", "approval");
    let state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("run should succeed");

    // The step output should be bound
    let step = state
        .phases
        .get("review")
        .unwrap()
        .steps
        .get("approve-draft")
        .unwrap();
    assert!(
        step.outputs.contains_key("approval"),
        "step outputs must contain 'approval'"
    );

    // Verify the output artifact was written
    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);
    let output_artifact = attempt_dir.join("artifacts/approval.md");
    assert!(output_artifact.exists(), "output artifact must exist");

    let content = std::fs::read_to_string(&output_artifact).unwrap();
    assert_eq!(content, "approved", "output artifact must contain response");
}

// ============================================================================
// Slice 7: Interactive — attempt.json produced
// ============================================================================

#[test]
fn interactive_attempt_json_produced() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO::with_type("approved", "approval");
    let _state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);

    assert!(
        attempt_dir.join("attempt.json").exists(),
        "attempt.json must exist"
    );

    let attempt_json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(attempt_dir.join("attempt.json")).unwrap())
            .unwrap();
    assert_eq!(attempt_json["status"], "completed");
    assert_eq!(attempt_json["action"], "interactive");
}

// ============================================================================
// Slice 7: Interactive — input-bindings.json and output-bindings.json produced
// ============================================================================

#[test]
fn interactive_bindings_produced() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO::with_type("approved", "approval");
    let _state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);

    assert!(
        attempt_dir.join("input-bindings.json").exists(),
        "input-bindings.json must exist"
    );
    assert!(
        attempt_dir.join("output-bindings.json").exists(),
        "output-bindings.json must exist"
    );

    // Verify output-bindings.json contains the correct output
    let bindings: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(attempt_dir.join("output-bindings.json")).unwrap(),
    )
    .unwrap();
    assert!(
        bindings["outputs"]["approval"].is_object(),
        "output-bindings.json must contain 'approval' binding"
    );
}

// ============================================================================
// Slice 7: Interactive — approval validation blocks on invalid response
// ============================================================================

#[test]
fn interactive_approval_blocks_on_invalid_response() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    // Provide an invalid response for approval type
    let fake_io = FakeInteractiveIO::with_type("maybe", "approval");
    let result = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io);

    assert!(
        result.is_err(),
        "run should fail with invalid approval response"
    );
    match result.unwrap_err() {
        RunError::StepBlocked { step_id, reason } => {
            assert_eq!(step_id, "approve-draft");
            assert!(
                reason.contains("response validation failed"),
                "reason should mention validation failure: {}",
                reason
            );
        }
        other => panic!("expected StepBlocked, got: {other:?}"),
    }
}

// ============================================================================
// Slice 7: CLI adapter — approve flag
// ============================================================================

#[test]
fn cli_interactive_io_approve() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let cli_io = CliInteractiveIO::approve();
    let state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &cli_io)
        .expect("run should succeed with --approve");

    assert_eq!(state.status, RunStatus::Completed);

    // Verify the response artifact contains "approved"
    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);
    let artifact = attempt_dir.join("artifacts/approval.md");
    let content = std::fs::read_to_string(&artifact).unwrap();
    assert_eq!(content, "approved");
}

// ============================================================================
// Slice 7: CLI adapter — reject flag
// ============================================================================

#[test]
fn cli_interactive_io_reject() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_approval_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let cli_io = CliInteractiveIO::reject();
    let state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &cli_io)
        .expect("run should succeed with --reject");

    assert_eq!(state.status, RunStatus::Completed);

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("review", "approve-draft", 1);
    let artifact = attempt_dir.join("artifacts/approval.md");
    let content = std::fs::read_to_string(&artifact).unwrap();
    assert_eq!(content, "rejected");
}

// ============================================================================
// Slice 7: CLI adapter — response-file flag
// ============================================================================

#[test]
fn cli_interactive_io_response_file() {
    let tmp = tempfile::TempDir::new().unwrap();

    // Write a response file
    let response_file = tmp.path().join("my-response.md");
    std::fs::write(&response_file, "This is my detailed feedback.").unwrap();

    let source = DefinitionSource {
        definition_path: interactive_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let cli_io = CliInteractiveIO::from_file(response_file);
    let state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &cli_io)
        .expect("run should succeed with --response-file");

    assert_eq!(state.status, RunStatus::Completed);

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("collect", "prompt-user", 1);
    let artifact = attempt_dir.join("artifacts/user-response.md");
    let content = std::fs::read_to_string(&artifact).unwrap();
    assert_eq!(content, "This is my detailed feedback.");
}

// ============================================================================
// Slice 8: Synthesis — reads consumed inputs from prior step outputs
// ============================================================================

#[test]
fn synthesis_reads_consumed_inputs() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: dispatch_then_synthesis_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    assert_eq!(state.status, RunStatus::Completed);

    let paths = MethodRunPaths::new(tmp.path());
    let synth_attempt_dir = paths.attempt_dir("pipeline", "synthesize", 1);
    let output_artifact = synth_attempt_dir.join("artifacts/digest.md");
    assert!(output_artifact.exists(), "synthesis output must exist");

    let content = std::fs::read_to_string(&output_artifact).unwrap();

    // The synthesis output should reference the consumed input (from do-work step)
    assert!(
        content.contains("Consumed Inputs"),
        "synthesis output should contain 'Consumed Inputs' section, got: {}",
        content
    );
    assert!(
        content.contains("pipeline.do-work.worker_output"),
        "synthesis output should reference the input locator, got: {}",
        content
    );
    // The resolved path from do-work should appear (it was bound as output)
    assert!(
        content.contains("artifacts/worker-output.md"),
        "synthesis output should contain the resolved input path, got: {}",
        content
    );
}

// ============================================================================
// Slice 8: Synthesis — exact event lifecycle
// ============================================================================

#[test]
fn synthesis_exact_event_lifecycle() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();

    // Extract synthesis step events in order
    let step_events: Vec<MethodEventKind> = events
        .iter()
        .filter(|e| e.step_id.as_deref() == Some("synthesize"))
        .map(|e| e.kind)
        .collect();

    // Exact lifecycle: step_started → attempt_started → synthesis_started →
    //   synthesis_completed → output_bound → attempt_completed → step_completed
    let expected = vec![
        MethodEventKind::StepStarted,
        MethodEventKind::AttemptStarted,
        MethodEventKind::SynthesisStarted,
        MethodEventKind::SynthesisCompleted,
        MethodEventKind::OutputBound,
        MethodEventKind::AttemptCompleted,
        MethodEventKind::StepCompleted,
    ];

    assert_eq!(
        step_events, expected,
        "synthesis event lifecycle must be exactly: {:?}\ngot: {:?}",
        expected, step_events
    );
}

// ============================================================================
// Slice 8: Synthesis — no dispatch paths touched (no WorkerDispatched)
// ============================================================================

#[test]
fn synthesis_no_dispatch_paths_touched() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let events = recover_events(&paths.events_log()).unwrap();
    let kinds: Vec<MethodEventKind> = events.iter().map(|e| e.kind).collect();

    // No worker-related events
    assert!(
        !kinds.contains(&MethodEventKind::WorkerDispatched),
        "synthesis must not emit WorkerDispatched"
    );
    assert!(
        !kinds.contains(&MethodEventKind::WorkerCompleted),
        "synthesis must not emit WorkerCompleted"
    );
    assert!(
        !kinds.contains(&MethodEventKind::WorkerFailed),
        "synthesis must not emit WorkerFailed"
    );
    assert!(
        !kinds.contains(&MethodEventKind::HandoffIngested),
        "synthesis must not emit HandoffIngested"
    );
}

// ============================================================================
// Slice 8: Synthesis — no relay directories created
// ============================================================================

#[test]
fn synthesis_no_relay_directories() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("process", "synthesize", 1);
    let relay_dir = attempt_dir.join("relay");
    assert!(
        !relay_dir.exists(),
        "synthesis must not create relay/ directory"
    );
}

// ============================================================================
// Slice 8: Synthesis — attempt.json, input-bindings.json, output-bindings.json
// ============================================================================

#[test]
fn synthesis_attempt_artifacts_produced() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let _state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("process", "synthesize", 1);

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

    // Verify attempt.json
    let attempt_json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(attempt_dir.join("attempt.json")).unwrap())
            .unwrap();
    assert_eq!(attempt_json["status"], "completed");
    assert_eq!(attempt_json["action"], "synthesis");

    // Verify output-bindings.json has the digest output
    let bindings: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(attempt_dir.join("output-bindings.json")).unwrap(),
    )
    .unwrap();
    assert!(
        bindings["outputs"]["digest"].is_object(),
        "output-bindings.json must contain 'digest' binding"
    );
}

// ============================================================================
// Slice 8: Synthesis — failure blocks step (no auto-retry)
// ============================================================================

#[test]
fn synthesis_has_no_retry() {
    // Synthesis steps are always attempt 1. Verify that synthesis_only_path
    // with its single step runs exactly once (1 attempt, no retry mechanism).
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: synthesis_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("run should succeed");

    let step = state
        .phases
        .get("process")
        .unwrap()
        .steps
        .get("synthesize")
        .unwrap();

    // Only one attempt
    assert_eq!(
        step.attempts.len(),
        1,
        "synthesis should have exactly 1 attempt"
    );
    assert_eq!(step.current_attempt, 1, "current attempt should be 1");
}

// ============================================================================
// Slice 7: Prompt persisted in markdown-type interactive step too
// ============================================================================

#[test]
fn prompt_persisted_for_markdown_interactive() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: interactive_only_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO::new("my detailed feedback");
    let _state = execute_run(&source, &FakePromptBuilder, &FakeWorkerDispatcher, &fake_io)
        .expect("run should succeed");

    let paths = MethodRunPaths::new(tmp.path());
    let attempt_dir = paths.attempt_dir("collect", "prompt-user", 1);

    let prompt_path = attempt_dir.join("prompt.txt");
    assert!(
        prompt_path.exists(),
        "prompt.txt must be persisted for markdown interactive step"
    );

    let content = std::fs::read_to_string(&prompt_path).unwrap();
    assert_eq!(content, "Please provide your feedback on the draft.");
}
