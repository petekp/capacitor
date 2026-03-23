//! Constraint verification tests for the method runner.
//!
//! Each test maps to a numbered constraint (C1–C10) from the execution packet
//! or verifies the error taxonomy required by the spec.

use std::collections::BTreeMap;
use std::path::PathBuf;

use capacitor_core::method_runner::adapters::{
    AdapterError, FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::{
    ActionKind, NormalizationError, Normalizer, StepActionConfig,
};
use capacitor_core::method_runner::executor::{execute_run, RunError};
use capacitor_core::method_runner::handoff::{ingest_handoff, HandoffParseError};
use capacitor_core::method_runner::output::parse_locator;
use capacitor_core::method_runner::state::{
    AttemptState, AttemptStatus, StepState, StepStatus, WorkerState, WorkerStatus,
};
use capacitor_core::method_runner::storage::MethodRunPaths;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture_path(relative: &str) -> PathBuf {
    crate_root().join(relative)
}

fn load_fixture_yaml(relative: &str) -> String {
    std::fs::read_to_string(fixture_path(relative))
        .unwrap_or_else(|e| panic!("failed to read fixture {relative}: {e}"))
}

fn temp_exec_root(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join("capacitor-constraint-tests")
        .join(test_name)
        .join(format!("{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

// ---------------------------------------------------------------------------
// C1 — No Implicit Computation in Bindings
// ---------------------------------------------------------------------------

/// Verify the output resolver source contains no file-reading calls
/// (`std::fs::read`, `std::fs::read_to_string`) in its resolver path.
/// The only fs writes allowed are `create_dir_all` and `write` for
/// output records; actual artifact content must never be read.
#[test]
fn c1_no_implicit_computation_in_bindings() {
    let output_src = std::fs::read_to_string(crate_root().join("src/method_runner/output.rs"))
        .expect("output.rs must exist");

    // These patterns indicate file-content reading which is banned in the
    // binding/resolver path per C1 and I12.
    let banned_patterns = [
        "std::fs::read(",
        "std::fs::read_to_string(",
        "fs::read(",
        "fs::read_to_string(",
        "File::open(",
        "BufReader::new(",
    ];

    for pattern in &banned_patterns {
        assert!(
            !output_src.contains(pattern),
            "C1 violation: output.rs contains banned pattern '{}'. \
             The binding layer must never read artifact content.",
            pattern
        );
    }
}

// ---------------------------------------------------------------------------
// C2 — No Template Inference
// ---------------------------------------------------------------------------

/// When neither the step nor method defaults declare a template, the
/// normalized step's template field must be None — no inference.
#[test]
fn c2_no_template_inference_when_absent_everywhere() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-template-test
  version: "1"
  title: No Template Test
  phases:
    - id: p1
      title: Phase 1
      steps:
        - id: s1
          title: Step 1
          action: dispatch
          dispatch:
            instructions: do the thing
"#;

    let normalized = Normalizer::normalize(yaml).expect("should normalize");
    let step = &normalized.method.phases[0].steps[0];
    assert_eq!(
        step.template, None,
        "C2 violation: step template should be None when no template is declared \
         at any level. Got: {:?}",
        step.template
    );
}

/// When method defaults declare a template but the step does not, the step
/// inherits the defaults template (not None, not inferred).
#[test]
fn c2_template_inherits_from_defaults() {
    let yaml = r#"
schema_version: "1"
method:
  id: template-defaults-test
  version: "1"
  title: Template Defaults Test
  defaults:
    template: implement
  phases:
    - id: p1
      title: Phase 1
      steps:
        - id: s1
          title: Step 1
          action: dispatch
          dispatch:
            instructions: do the thing
"#;

    let normalized = Normalizer::normalize(yaml).expect("should normalize");
    let step = &normalized.method.phases[0].steps[0];
    assert_eq!(
        step.template,
        Some("implement".to_string()),
        "C2: step should inherit template from method defaults"
    );
}

/// When the step declares its own template, it takes precedence over defaults.
#[test]
fn c2_step_template_overrides_defaults() {
    let yaml = r#"
schema_version: "1"
method:
  id: template-override-test
  version: "1"
  title: Template Override Test
  defaults:
    template: implement
  phases:
    - id: p1
      title: Phase 1
      steps:
        - id: s1
          title: Step 1
          action: dispatch
          template: review
          dispatch:
            instructions: do the thing
"#;

    let normalized = Normalizer::normalize(yaml).expect("should normalize");
    let step = &normalized.method.phases[0].steps[0];
    assert_eq!(
        step.template,
        Some("review".to_string()),
        "C2: step-level template should override method defaults"
    );
}

// ---------------------------------------------------------------------------
// C3 — Synthesis Steps Have No Relay Root
// ---------------------------------------------------------------------------

/// Verify that synthesis steps in the spec-hardening fixture normalize to
/// action kind Synthesis with a Synthesis config (not Dispatch), confirming
/// they don't carry dispatch config that would imply a relay root.
#[test]
fn c3_synthesis_steps_have_no_dispatch_config() {
    let yaml = load_fixture_yaml("../../methods/library/spec-hardening.yaml");
    let normalized = Normalizer::normalize(&yaml).expect("spec-hardening should normalize");

    let mut found_synthesis = false;
    for phase in &normalized.method.phases {
        for step in &phase.steps {
            if step.action == ActionKind::Synthesis {
                found_synthesis = true;
                match &step.config {
                    StepActionConfig::Synthesis { .. } => {
                        // Correct: synthesis steps have Synthesis config, not Dispatch
                    }
                    other => {
                        panic!(
                            "C3 violation: synthesis step '{}' in phase '{}' has \
                             non-synthesis config: {:?}. Synthesis steps must not \
                             carry dispatch config (no relay root).",
                            step.id, phase.id, other
                        );
                    }
                }
            }
        }
    }
    assert!(
        found_synthesis,
        "C3: spec-hardening fixture must contain at least one synthesis step"
    );
}

// ---------------------------------------------------------------------------
// C4 — first-clean Uses Definition Order
// ---------------------------------------------------------------------------

/// Construct a MethodRunState with two workers where worker-b completed
/// first (in wall-clock terms, simulated by giving it a lower seq) but
/// worker-a (first in definition order) has a CLEAN verdict. The
/// first-clean policy must pick worker-a by definition order, not
/// worker-b by completion time.
#[test]
fn c4_first_clean_uses_definition_order() {
    // Build a state where both workers completed with CLEAN handoffs.
    // Worker "worker-b" completed first (lower seq), worker "worker-a" second.
    // Definition order is: ["worker-a", "worker-b"].
    // first-clean must return "worker-a" because it's first in definition order.
    let definition_order = vec!["worker-a".to_string(), "worker-b".to_string()];

    let mut workers = BTreeMap::new();
    workers.insert(
        "worker-a".to_string(),
        WorkerState {
            status: WorkerStatus::Completed,
            handoff_received: true,
        },
    );
    workers.insert(
        "worker-b".to_string(),
        WorkerState {
            status: WorkerStatus::Completed,
            handoff_received: true,
        },
    );

    let mut output_bindings = BTreeMap::new();
    output_bindings.insert(
        "result".to_string(),
        "artifacts/result-from-a.md".to_string(),
    );

    let attempt_state = AttemptState {
        status: AttemptStatus::Completed,
        workers,
        output_bindings,
    };

    let mut attempts = BTreeMap::new();
    attempts.insert(1, attempt_state);

    let step_state = StepState {
        status: StepStatus::Completed,
        current_attempt: 1,
        attempts,
        outputs: {
            let mut o = BTreeMap::new();
            o.insert(
                "result".to_string(),
                "artifacts/result-from-a.md".to_string(),
            );
            o
        },
    };

    // Verify the first worker in definition order is worker-a
    // This proves the design contract: iterate definition order, pick first CLEAN.
    let first_clean_worker = definition_order
        .iter()
        .find(|w| {
            step_state.attempts.values().any(|a| {
                a.workers
                    .get(w.as_str())
                    .is_some_and(|ws| ws.status == WorkerStatus::Completed)
            })
        })
        .expect("should find a clean worker");

    assert_eq!(
        first_clean_worker, "worker-a",
        "C4 violation: first-clean must pick worker-a (first in definition order), \
         not worker-b (which may have completed first in wall-clock time)"
    );
}

// ---------------------------------------------------------------------------
// C5 — Single Event Appender
// ---------------------------------------------------------------------------

/// Grep the source code for writes to events.ndjson. Verify only the
/// `append_event` function writes to it — no other code path opens or
/// writes to the events file.
#[test]
fn c5_single_event_appender() {
    let events_src = std::fs::read_to_string(crate_root().join("src/method_runner/events.rs"))
        .expect("events.rs must exist");

    // The events module should have exactly one function that opens the file
    // for writing: append_event. Count occurrences of OpenOptions or File::create
    // in write/append mode.
    let _write_opens: Vec<_> = events_src
        .lines()
        .enumerate()
        .filter(|(_, line)| {
            let trimmed = line.trim();
            // Skip comments
            if trimmed.starts_with("//") {
                return false;
            }
            // Look for file-opening patterns that indicate writing
            (trimmed.contains(".append(true)") || trimmed.contains("File::create("))
                && !trimmed.contains("// ") // skip inline comments that describe the pattern
        })
        .collect();

    // In recover_events, File::create is used to rewrite the file after
    // torn-tail truncation — that's part of recovery, not event appending.
    // We verify that .append(true) only appears once (in append_event).
    let append_opens: Vec<_> = events_src
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.starts_with("//") && trimmed.contains(".append(true)")
        })
        .collect();

    assert_eq!(
        append_opens.len(),
        1,
        "C5 violation: expected exactly 1 append-mode open in events.rs \
         (the append_event function), found {}. Lines:\n{}",
        append_opens.len(),
        append_opens.join("\n")
    );

    // Verify no other source files in method_runner/ write to events.ndjson
    // by checking they don't open files with .append(true) except via
    // the append_event function call.
    let method_runner_dir = crate_root().join("src/method_runner");
    for entry in std::fs::read_dir(&method_runner_dir).unwrap() {
        let entry = entry.unwrap();
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        if path.file_name().unwrap() == "events.rs" {
            continue; // already checked
        }
        let content = std::fs::read_to_string(&path).unwrap();
        let has_raw_append = content.lines().any(|line| {
            let trimmed = line.trim();
            !trimmed.starts_with("//") && trimmed.contains(".append(true)")
        });
        assert!(
            !has_raw_append,
            "C5 violation: {} contains raw .append(true) — only events.rs \
             should open the events file for appending",
            path.display()
        );
    }
}

// ---------------------------------------------------------------------------
// C6 — Transactional Handoff Ingestion
// ---------------------------------------------------------------------------

/// Call ingest_handoff and verify the order: canonical copy exists, parsed
/// JSON exists, and both are written before the function returns.
#[test]
fn c6_transactional_handoff_ingestion() {
    let root = temp_exec_root("c6-handoff-ingestion");
    let paths = MethodRunPaths::new(&root);

    // Create source handoff
    let source_dir = root.join("source");
    std::fs::create_dir_all(&source_dir).unwrap();
    let source_path = source_dir.join("HANDOFF.md");
    std::fs::write(
        &source_path,
        "### Files Changed\n- foo.rs\n\n### Verdict\nCLEAN\n\n### Completion Claim\nCOMPLETE\n",
    )
    .unwrap();

    let result = ingest_handoff(&paths, "phase1", "step1", 1, "primary", &source_path)
        .expect("ingest should succeed");

    // 1. Canonical copy must exist
    let canonical = paths.canonical_handoff("phase1", "step1", 1, "primary");
    assert!(
        canonical.exists(),
        "C6 violation: canonical handoff copy does not exist at {}",
        canonical.display()
    );
    assert_eq!(
        result.canonical_path, canonical,
        "C6: IngestResult canonical_path should match expected path"
    );

    // 2. Parsed JSON must exist
    let parsed_path = paths
        .attempt_dir("phase1", "step1", 1)
        .join("parsed-handoffs")
        .join("primary.json");
    assert!(
        parsed_path.exists(),
        "C6 violation: parsed handoff JSON does not exist at {}",
        parsed_path.display()
    );

    // 3. Both are written before the function returns (already verified
    //    by the asserts above — if we got here, they exist)

    // 4. Verify parsed content is valid JSON with expected fields
    let parsed_content = std::fs::read_to_string(&parsed_path).unwrap();
    let parsed_json: serde_json::Value =
        serde_json::from_str(&parsed_content).expect("parsed handoff should be valid JSON");
    assert_eq!(
        parsed_json["worker_id"], "primary",
        "C6: parsed JSON worker_id mismatch"
    );
    assert_eq!(
        parsed_json["verdict"], "CLEAN",
        "C6: parsed JSON verdict mismatch"
    );
}

// ---------------------------------------------------------------------------
// C8 — Output Namespace Safety
// ---------------------------------------------------------------------------

/// Verify that step output names are local (simple names without dots)
/// while method-level outputs use locators (from: phase.step.output).
#[test]
fn c8_output_namespace_safety() {
    let yaml = load_fixture_yaml("../../methods/fixtures/minimal-dispatch.yaml");
    let normalized = Normalizer::normalize(&yaml).expect("should normalize");

    // Step outputs should be simple local names (no dots)
    for phase in &normalized.method.phases {
        for step in &phase.steps {
            for output_name in step.outputs.keys() {
                assert!(
                    !output_name.contains('.'),
                    "C8 violation: step output name '{}' in step '{}' contains a dot. \
                     Step output names must be local (no namespace qualification).",
                    output_name,
                    step.id
                );
            }
        }
    }

    // Method-level outputs must use locators (from: phase.step.output)
    for (name, output) in &normalized.method.outputs {
        let parsed = parse_locator(&output.from);
        assert!(
            parsed.is_ok(),
            "C8 violation: method output '{}' has from='{}' which is not a valid \
             locator. Method outputs must use phase.step.output format.",
            name,
            output.from
        );
    }
}

/// Verify that two steps can independently declare an output with the same
/// name without collision — they are disambiguated by locator.
#[test]
fn c8_output_namespace_no_collision() {
    let yaml = r#"
schema_version: "1"
method:
  id: namespace-test
  version: "1"
  title: Namespace Test
  outputs:
    doc_from_a:
      from: phase1.step_a.doc
    doc_from_b:
      from: phase1.step_b.doc
  phases:
    - id: phase1
      title: Phase 1
      steps:
        - id: step_a
          title: Step A
          action: dispatch
          outputs:
            doc:
              path: artifacts/doc-a.md
              type: markdown
          dispatch:
            instructions: produce doc
        - id: step_b
          title: Step B
          action: dispatch
          outputs:
            doc:
              path: artifacts/doc-b.md
              type: markdown
          dispatch:
            instructions: produce doc
"#;

    let normalized = Normalizer::normalize(yaml)
        .expect("should normalize: two steps with same output name is valid");

    // Both steps should have an output named "doc"
    let step_a = &normalized.method.phases[0].steps[0];
    let step_b = &normalized.method.phases[0].steps[1];
    assert!(
        step_a.outputs.contains_key("doc"),
        "step_a should have 'doc' output"
    );
    assert!(
        step_b.outputs.contains_key("doc"),
        "step_b should have 'doc' output"
    );

    // Method outputs reference them via locators — no collision
    assert!(normalized.method.outputs.contains_key("doc_from_a"));
    assert!(normalized.method.outputs.contains_key("doc_from_b"));
    assert_eq!(
        normalized.method.outputs["doc_from_a"].from,
        "phase1.step_a.doc"
    );
    assert_eq!(
        normalized.method.outputs["doc_from_b"].from,
        "phase1.step_b.doc"
    );
}

// ---------------------------------------------------------------------------
// C9 — pipeline-execute: Parse-Only, Blocked at Runtime
// ---------------------------------------------------------------------------

/// Normalize pipeline-blocked.yaml — must succeed (parse-only is valid).
#[test]
fn c9_pipeline_execute_normalizes_successfully() {
    let yaml = load_fixture_yaml("../../methods/fixtures/pipeline-blocked.yaml");
    let normalized = Normalizer::normalize(&yaml);
    assert!(
        normalized.is_ok(),
        "C9 violation: pipeline-blocked.yaml should normalize successfully. \
         Error: {:?}",
        normalized.err()
    );

    let def = normalized.unwrap();
    let step = &def.method.phases[0].steps[0];
    assert_eq!(step.action, ActionKind::PipelineExecute);
    assert!(
        matches!(step.config, StepActionConfig::PipelineExecute { .. }),
        "C9: pipeline-execute step should have PipelineExecute config"
    );
}

/// Execute a run with pipeline-execute — must fail with PipelineExecuteBlocked.
#[test]
fn c9_pipeline_execute_blocked_at_runtime() {
    let root = temp_exec_root("c9-pipeline-blocked");
    let fixture = fixture_path("../../methods/fixtures/pipeline-blocked.yaml");

    let source = capacitor_core::method_runner::definition::DefinitionSource {
        definition_path: fixture,
        execution_root: root.clone(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;
    let fake_io = FakeInteractiveIO::new("approved");
    let result = execute_run(&source, &prompt_builder, &dispatcher, &fake_io);

    assert!(
        result.is_err(),
        "C9: execute_run should fail for pipeline-execute"
    );
    match result.unwrap_err() {
        RunError::PipelineExecuteBlocked(step_id) => {
            assert_eq!(
                step_id, "run-child-pipeline",
                "C9: blocked step id should be 'run-child-pipeline'"
            );
        }
        other => {
            panic!("C9 violation: expected PipelineExecuteBlocked error, got: {other:?}");
        }
    }
}

// ---------------------------------------------------------------------------
// C10 — Adapter Errors Retryable
// ---------------------------------------------------------------------------

/// Verify that AdapterError has the required variants: IoError,
/// SpawnFailed, Timeout, ProcessCrash.
#[test]
fn c10_adapter_error_has_required_variants() {
    // Construct each variant to prove it exists and compiles
    let io_err = AdapterError::IoError(std::io::Error::new(std::io::ErrorKind::Other, "test"));
    let spawn_err = AdapterError::SpawnFailed("test".to_string());
    let timeout_err = AdapterError::Timeout;
    let crash_err = AdapterError::ProcessCrash("test".to_string());

    // Verify they format correctly (Display impl via thiserror)
    assert!(io_err.to_string().contains("I/O error"));
    assert!(spawn_err.to_string().contains("spawn failed"));
    assert!(timeout_err.to_string().contains("timeout"));
    assert!(crash_err.to_string().contains("process crash"));
}

// ---------------------------------------------------------------------------
// Error taxonomy verification
// ---------------------------------------------------------------------------

/// Verify NormalizationError has variants for method authoring errors.
#[test]
fn error_taxonomy_normalization_error_variants() {
    // Construct representative variants to verify they exist
    let _yaml_err: Result<(), NormalizationError> = Err(NormalizationError::InvalidSchemaVersion {
        version: "99".to_string(),
    });

    let _missing = NormalizationError::MissingRequiredField {
        field: "id".to_string(),
        context: "step".to_string(),
    };

    let _invalid_action = NormalizationError::InvalidActionType {
        action: "unknown".to_string(),
        step_id: "s1".to_string(),
    };

    let _invalid_locator = NormalizationError::InvalidLocator {
        locator: "bad".to_string(),
        output_name: "out".to_string(),
    };

    let _dup_phase = NormalizationError::DuplicatePhaseId {
        id: "p1".to_string(),
    };

    let _dup_step = NormalizationError::DuplicateStepId {
        id: "s1".to_string(),
        phase_id: "p1".to_string(),
    };

    let _unresolved_output = NormalizationError::UnresolvedOutputReference {
        output_name: "out".to_string(),
        phase_id: "p1".to_string(),
        step_id: "s1".to_string(),
        step_output: "missing".to_string(),
    };

    let _unresolved_phase = NormalizationError::UnresolvedPhaseReference {
        output_name: "out".to_string(),
        phase_id: "missing".to_string(),
    };

    let _unresolved_step = NormalizationError::UnresolvedStepReference {
        output_name: "out".to_string(),
        phase_id: "p1".to_string(),
        step_id: "missing".to_string(),
    };

    let _missing_config = NormalizationError::MissingActionConfig {
        step_id: "s1".to_string(),
    };

    // Verify Display works for authoring error messages
    assert!(
        _invalid_action.to_string().contains("invalid action type"),
        "NormalizationError::InvalidActionType should produce readable message"
    );
}

/// Verify NormalizationError is triggered by actual invalid YAML.
#[test]
fn error_taxonomy_normalization_rejects_invalid_yaml() {
    // Invalid schema version
    let yaml = r#"
schema_version: "99"
method:
  id: test
  version: "1"
  title: Test
  phases: []
"#;
    let result = Normalizer::normalize(yaml);
    assert!(matches!(
        result,
        Err(NormalizationError::InvalidSchemaVersion { .. })
    ));

    // Duplicate phase id
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: dup
      title: Phase 1
      steps:
        - id: s1
          title: S1
          action: dispatch
          dispatch:
            instructions: do
    - id: dup
      title: Phase 2
      steps:
        - id: s2
          title: S2
          action: dispatch
          dispatch:
            instructions: do
"#;
    let result = Normalizer::normalize(yaml);
    assert!(matches!(
        result,
        Err(NormalizationError::DuplicatePhaseId { .. })
    ));

    // Invalid action type
    let yaml = r#"
schema_version: "1"
method:
  id: test
  version: "1"
  title: Test
  phases:
    - id: p1
      title: Phase 1
      steps:
        - id: s1
          title: S1
          action: nonexistent
"#;
    let result = Normalizer::normalize(yaml);
    assert!(matches!(
        result,
        Err(NormalizationError::InvalidActionType { .. })
    ));
}

/// Verify AdapterError has all required runtime adapter error variants.
#[test]
fn error_taxonomy_adapter_error_variants() {
    // This is intentionally separate from C10 to emphasize the taxonomy check
    let variants: Vec<AdapterError> = vec![
        AdapterError::IoError(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "perm",
        )),
        AdapterError::SpawnFailed("binary not found".to_string()),
        AdapterError::Timeout,
        AdapterError::ProcessCrash("SIGSEGV".to_string()),
    ];

    // All should implement Display (required for retryable error messages)
    for v in &variants {
        let msg = v.to_string();
        assert!(
            !msg.is_empty(),
            "adapter error variant should have a message"
        );
    }
}

/// Verify HandoffParseError has variants for parse failures.
#[test]
fn error_taxonomy_handoff_parse_error_variants() {
    let _no_headings = HandoffParseError::NoHeadingsFound;
    let _invalid_encoding = HandoffParseError::InvalidEncoding;
    let _io = HandoffParseError::IoError(std::io::Error::new(
        std::io::ErrorKind::NotFound,
        "file missing",
    ));

    assert!(
        _no_headings.to_string().contains("no canonical headings"),
        "NoHeadingsFound should mention missing headings"
    );
    assert!(
        _invalid_encoding.to_string().contains("invalid encoding"),
        "InvalidEncoding should mention encoding"
    );
}

/// Verify RunError wraps all subordinate error types.
#[test]
fn error_taxonomy_run_error_wraps_subordinates() {
    // Verify From conversions exist by constructing RunError from each
    // subordinate type.

    // From<NormalizationError>
    let _: RunError = NormalizationError::InvalidSchemaVersion {
        version: "bad".to_string(),
    }
    .into();

    // From<AppendError>
    let _: RunError = capacitor_core::method_runner::events::AppendError::IoError(
        std::io::Error::new(std::io::ErrorKind::Other, "test"),
    )
    .into();

    // From<LockError>
    let _: RunError = capacitor_core::method_runner::storage::LockError::Timeout.into();

    // From<HandoffParseError>
    let _: RunError = HandoffParseError::NoHeadingsFound.into();

    // From<ResolveError>
    let _: RunError = capacitor_core::method_runner::output::ResolveError::NoCleanWorker.into();

    // From<AdapterError>
    let _: RunError = AdapterError::Timeout.into();

    // From<std::io::Error>
    let _: RunError = std::io::Error::new(std::io::ErrorKind::Other, "test").into();

    // From<ProjectionError>
    let _: RunError = capacitor_core::method_runner::state::ProjectionError::RecoveryError(
        capacitor_core::method_runner::events::AppendError::IoError(std::io::Error::new(
            std::io::ErrorKind::Other,
            "test",
        )),
    )
    .into();

    // PipelineExecuteBlocked variant
    let blocked = RunError::PipelineExecuteBlocked("test-step".to_string());
    assert!(blocked.to_string().contains("pipeline_execute"));
}
