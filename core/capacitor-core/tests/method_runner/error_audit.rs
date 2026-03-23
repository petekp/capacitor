// ==========================================================================
// PANIC AUDIT — method_runner source files
// ==========================================================================
//
// Searched all files under core/capacitor-core/src/method_runner/ for
// .unwrap(), .expect(), and panic!() calls.
//
// FINDING 1: definition.rs:665
//   Code:    let step_output_name = segments.last().unwrap();
//   Context: Inside validate_output_locator, after checking segments.len() < 3.
//   Verdict: JUSTIFIED — the guard on line 655 ensures segments.len() >= 3,
//            so .last() is guaranteed to be Some. A debug_assert would be
//            cleaner, but this is not a reachable panic.
//
// No other .unwrap(), .expect(), or panic!() calls found in method_runner/.
// All other Option/Result handling uses proper ? or match/if-let patterns.
// ==========================================================================

use std::path::PathBuf;
use std::time::Duration;

use capacitor_core::method_runner::definition::Normalizer;
use capacitor_core::method_runner::handoff::parse_handoff;
use capacitor_core::method_runner::output::parse_locator;
use capacitor_core::method_runner::state::{PhaseStatus, RunStatus, StepStatus};
use capacitor_core::method_runner::storage::acquire_lock;

// ===========================================================================
// Task 2 & 4: Normalization error message quality
// ===========================================================================

#[test]
fn error_normalization_yaml_parse() {
    let bad_yaml = "not: valid: yaml: [[[";
    let err = Normalizer::normalize(bad_yaml).unwrap_err();
    let msg = err.to_string();

    // Must mention it's a YAML parse error and include serde_yaml details
    assert!(
        msg.contains("YAML parse error"),
        "expected 'YAML parse error' in: {msg}"
    );
    // serde_yaml errors include line/column or descriptive parse detail
    assert!(
        msg.len() > "YAML parse error: ".len(),
        "expected parse details beyond the prefix in: {msg}"
    );
}

#[test]
fn error_normalization_invalid_schema() {
    let yaml = r#"
schema_version: "99"
method:
  id: test
  version: "1"
  title: Test
  phases: []
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("99"),
        "expected schema version '99' in error message: {msg}"
    );
    assert!(
        msg.contains("schema_version"),
        "expected 'schema_version' context in: {msg}"
    );
}

#[test]
fn error_normalization_duplicate_phase() {
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: same-phase
      title: Phase 1
      steps:
        - id: s1
          title: Step
          action: dispatch
          dispatch:
            instructions: do it
    - id: same-phase
      title: Phase 2
      steps:
        - id: s2
          title: Step
          action: dispatch
          dispatch:
            instructions: do it
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("same-phase"),
        "expected duplicate phase id 'same-phase' in: {msg}"
    );
    assert!(
        msg.contains("duplicate"),
        "expected 'duplicate' keyword in: {msg}"
    );
}

#[test]
fn error_normalization_duplicate_step() {
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: phase-x
      title: Phase X
      steps:
        - id: dupe-step
          title: Step 1
          action: dispatch
          dispatch:
            instructions: do it
        - id: dupe-step
          title: Step 2
          action: dispatch
          dispatch:
            instructions: do it too
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("dupe-step"),
        "expected duplicate step id 'dupe-step' in: {msg}"
    );
    assert!(
        msg.contains("phase-x"),
        "expected phase id 'phase-x' context in: {msg}"
    );
}

#[test]
fn error_normalization_invalid_action() {
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: p
      title: P
      steps:
        - id: bad-action-step
          title: Bad
          action: teleport
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("teleport"),
        "expected invalid action 'teleport' in: {msg}"
    );
    assert!(
        msg.contains("bad-action-step"),
        "expected step id 'bad-action-step' in: {msg}"
    );
}

#[test]
fn error_normalization_invalid_locator() {
    // A method output with a locator that has too few segments
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  outputs:
    my_output:
      from: "only-one-segment"
      required: true
  phases:
    - id: p
      title: P
      steps:
        - id: s
          title: S
          action: dispatch
          dispatch:
            instructions: do it
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("only-one-segment"),
        "expected bad locator 'only-one-segment' in: {msg}"
    );
    assert!(
        msg.contains("my_output"),
        "expected output name 'my_output' in: {msg}"
    );
}

#[test]
fn error_normalization_unresolved_reference() {
    // Output references a step output that the step does not declare
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  outputs:
    final_result:
      from: "phase-a.step-a.nonexistent_output"
      required: true
  phases:
    - id: phase-a
      title: Phase A
      steps:
        - id: step-a
          title: Step A
          action: dispatch
          outputs:
            actual_output:
              path: artifacts/result.md
              type: markdown
          dispatch:
            instructions: do it
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("nonexistent_output"),
        "expected unresolved output name 'nonexistent_output' in: {msg}"
    );
    assert!(
        msg.contains("final_result"),
        "expected method output name 'final_result' in: {msg}"
    );
}

#[test]
fn error_normalization_missing_config() {
    // dispatch step without a dispatch: block
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: p
      title: P
      steps:
        - id: naked-dispatch
          title: No Config
          action: dispatch
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("naked-dispatch"),
        "expected step id 'naked-dispatch' in: {msg}"
    );
    assert!(
        msg.contains("dispatch"),
        "expected action type context in: {msg}"
    );
}

// ===========================================================================
// Handoff parse errors
// ===========================================================================

#[test]
fn error_handoff_no_headings() {
    let content = "This is just plain text with no ### headings at all.\nMore text here.";
    let err = parse_handoff(content, "worker-1").unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("heading"),
        "expected 'heading' context in: {msg}"
    );

    // Verify it is the NoHeadingsFound variant
    assert!(
        matches!(
            err,
            capacitor_core::method_runner::handoff::HandoffParseError::NoHeadingsFound
        ),
        "expected NoHeadingsFound variant"
    );
}

// ===========================================================================
// Lock errors
// ===========================================================================

#[test]
fn error_lock_timeout() {
    let tmp = tempfile::tempdir().unwrap();
    let lock_path = tmp.path().join("locks").join("run.lock");

    // Acquire first lock (should succeed)
    let _lock1 = acquire_lock(&lock_path, Duration::from_secs(5)).unwrap();

    // Second acquisition should time out — use a very short timeout
    let err = acquire_lock(&lock_path, Duration::from_millis(100)).unwrap_err();
    let msg = err.to_string();

    assert!(
        matches!(
            err,
            capacitor_core::method_runner::storage::LockError::Timeout
        ),
        "expected Timeout variant, got: {msg}"
    );
    assert!(msg.contains("timed out"), "expected 'timed out' in: {msg}");
}

// ===========================================================================
// Transition errors
// ===========================================================================

#[test]
fn error_transition_illegal() {
    // RunStatus::Completed -> Running is illegal
    let result = RunStatus::Completed.transition_to(RunStatus::Running, "run-42");
    let err = result.unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("Completed"),
        "expected from-state 'Completed' in: {msg}"
    );
    assert!(
        msg.contains("Running"),
        "expected to-state 'Running' in: {msg}"
    );
    assert!(
        msg.contains("run-42"),
        "expected entity id 'run-42' in: {msg}"
    );
    assert!(
        msg.contains("illegal transition"),
        "expected 'illegal transition' in: {msg}"
    );
}

#[test]
fn error_transition_phase_illegal() {
    let result = PhaseStatus::Completed.transition_to(PhaseStatus::Running, "phase-z");
    let err = result.unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("phase-z"),
        "expected entity id 'phase-z' in: {msg}"
    );
    assert!(msg.contains("Completed"), "expected from-state in: {msg}");
}

#[test]
fn error_transition_step_illegal() {
    let result = StepStatus::Completed.transition_to(StepStatus::Running, "step-q");
    let err = result.unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("step-q"),
        "expected entity id 'step-q' in: {msg}"
    );
}

// ===========================================================================
// Pipeline execute blocked
// ===========================================================================

#[test]
fn error_pipeline_blocked() {
    let tmp = tempfile::tempdir().unwrap();
    let exec_root = tmp.path().to_path_buf();

    // Use the pipeline-blocked fixture
    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture = crate_root.join("../../methods/fixtures/pipeline-blocked.yaml");

    let source = capacitor_core::method_runner::definition::DefinitionSource {
        definition_path: fixture,
        execution_root: exec_root,
    };

    let prompt_builder = capacitor_core::method_runner::adapters::FakePromptBuilder;
    let dispatcher = capacitor_core::method_runner::adapters::FakeWorkerDispatcher;

    let err =
        capacitor_core::method_runner::executor::execute_run(&source, &prompt_builder, &dispatcher)
            .unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("run-child-pipeline"),
        "expected step id 'run-child-pipeline' in: {msg}"
    );
    assert!(
        msg.contains("pipeline"),
        "expected 'pipeline' context in: {msg}"
    );
}

// ===========================================================================
// Definition load from missing path
// ===========================================================================

#[test]
fn error_definition_load_missing() {
    let nonexistent = PathBuf::from("/tmp/does-not-exist-method-runner-test/fake-definition.yaml");
    let result = capacitor_core::method_runner::definition::DefinitionLoader::load(&nonexistent);
    let err = result.unwrap_err();
    let msg = err.to_string();

    // Should be an IoError from std::fs::read_to_string
    assert!(
        msg.contains("I/O error") || msg.contains("No such file"),
        "expected I/O context in: {msg}"
    );
}

// ===========================================================================
// Output locator errors
// ===========================================================================

#[test]
fn error_locator_invalid_format() {
    let err = parse_locator("single").unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("invalid locator format"),
        "expected 'invalid locator format' in: {msg}"
    );
    assert!(msg.contains("1"), "expected segment count in: {msg}");
}

#[test]
fn error_locator_empty_segment() {
    let err = parse_locator("a..b").unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("empty segment"),
        "expected 'empty segment' in: {msg}"
    );
}

// ===========================================================================
// Normalization: unresolved phase reference
// ===========================================================================

#[test]
fn error_normalization_unresolved_phase_reference() {
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  outputs:
    out:
      from: "ghost-phase.step-a.output"
      required: true
  phases:
    - id: real-phase
      title: Real Phase
      steps:
        - id: step-a
          title: Step A
          action: dispatch
          outputs:
            output:
              path: artifacts/out.md
              type: markdown
          dispatch:
            instructions: do it
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("ghost-phase"),
        "expected missing phase id 'ghost-phase' in: {msg}"
    );
    assert!(msg.contains("out"), "expected output name 'out' in: {msg}");
}

// ===========================================================================
// Normalization: unresolved step reference
// ===========================================================================

#[test]
fn error_normalization_unresolved_step_reference() {
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  outputs:
    out:
      from: "phase-a.ghost-step.output"
      required: true
  phases:
    - id: phase-a
      title: Phase A
      steps:
        - id: real-step
          title: Real Step
          action: dispatch
          outputs:
            output:
              path: artifacts/out.md
              type: markdown
          dispatch:
            instructions: do it
"#;
    let err = Normalizer::normalize(yaml).unwrap_err();
    let msg = err.to_string();

    assert!(
        msg.contains("ghost-step"),
        "expected missing step id 'ghost-step' in: {msg}"
    );
    assert!(
        msg.contains("phase-a"),
        "expected phase id 'phase-a' in: {msg}"
    );
}

// ===========================================================================
// Adapter error Display messages
// ===========================================================================

#[test]
fn error_adapter_spawn_failed_includes_detail() {
    let err = capacitor_core::method_runner::adapters::AdapterError::SpawnFailed(
        "binary not found: /usr/bin/fake-agent".to_string(),
    );
    let msg = err.to_string();

    assert!(
        msg.contains("binary not found"),
        "expected spawn detail in: {msg}"
    );
}

#[test]
fn error_adapter_process_crash_includes_detail() {
    let err = capacitor_core::method_runner::adapters::AdapterError::ProcessCrash(
        "exit code 137 (OOM killed)".to_string(),
    );
    let msg = err.to_string();

    assert!(msg.contains("137"), "expected exit code in: {msg}");
}

// ===========================================================================
// Append error Display messages
// ===========================================================================

#[test]
fn error_append_serialization_includes_detail() {
    // Create a malformed JSON scenario by using serde_json Error
    let bad_json: Result<serde_json::Value, _> = serde_json::from_str("{invalid");
    let serde_err = bad_json.unwrap_err();
    let err = capacitor_core::method_runner::events::AppendError::SerializationError(serde_err);
    let msg = err.to_string();

    assert!(
        msg.contains("serialization error"),
        "expected 'serialization error' prefix in: {msg}"
    );
    assert!(
        msg.len() > "serialization error: ".len(),
        "expected serde detail beyond the prefix in: {msg}"
    );
}

// ===========================================================================
// ResolveError Display messages
// ===========================================================================

#[test]
fn error_resolve_phase_not_found_includes_id() {
    let err = capacitor_core::method_runner::output::ResolveError::PhaseNotFound(
        "missing-phase-42".to_string(),
    );
    let msg = err.to_string();

    assert!(
        msg.contains("missing-phase-42"),
        "expected phase id in: {msg}"
    );
}

#[test]
fn error_resolve_step_not_found_includes_id() {
    let err = capacitor_core::method_runner::output::ResolveError::StepNotFound(
        "missing-step-99".to_string(),
    );
    let msg = err.to_string();

    assert!(
        msg.contains("missing-step-99"),
        "expected step id in: {msg}"
    );
}
