//! Adversarial tests for the method runner's YAML normalizer and executor.
//!
//! Each test feeds intentionally malformed or edge-case input to
//! `Normalizer::normalize` or `executor::execute_normalize` and verifies:
//!   - No panics occur
//!   - The correct error variant is returned
//!   - Error messages are helpful (contain relevant context)
//!   - Behavior is documented for ambiguous cases
//!
//! All YAML is defined inline — no fixture files.

use capacitor_core::method_runner::definition::{NormalizationError, Normalizer};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal valid YAML that normalizes successfully.
/// Other tests mutate/omit parts of this template.
fn minimal_valid_yaml() -> String {
    r#"
schema_version: "1"
method:
  id: test-method
  version: "1.0"
  title: Test Method
  phases:
    - id: phase-one
      title: Phase One
      steps:
        - id: step-one
          title: Step One
          action: dispatch
          dispatch:
            instructions: Do the thing.
"#
    .to_string()
}

/// Asserts that `normalize` succeeds on the minimal template, so if other
/// tests fail it is not due to a stale baseline.
#[test]
fn baseline_minimal_yaml_normalizes_successfully() {
    let result = Normalizer::normalize(&minimal_valid_yaml());
    assert!(result.is_ok(), "baseline should normalize: {result:?}");
}

// ---------------------------------------------------------------------------
// 1. adversarial_empty_yaml
// ---------------------------------------------------------------------------

/// Completely empty string must return a clear parse error, not panic.
#[test]
fn adversarial_empty_yaml() {
    let result = Normalizer::normalize("");
    let err = result.expect_err("empty YAML must be an error");
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError, got: {err}"
    );
    // Error message should mention something useful (serde_yaml will say
    // "EOF" or "missing field").
    let msg = err.to_string();
    assert!(!msg.is_empty(), "error message must not be empty");
}

// ---------------------------------------------------------------------------
// 2. adversarial_no_method_key
// ---------------------------------------------------------------------------

/// Valid YAML with no `method` key must fail during deserialization.
#[test]
fn adversarial_no_method_key() {
    let yaml = r#"
schema_version: "1"
foo: bar
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("missing `method` key must be an error");
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError (serde missing field), got: {err}"
    );
    let msg = err.to_string();
    assert!(
        msg.contains("method") || msg.contains("missing field"),
        "error should mention 'method' or 'missing field': {msg}"
    );
}

// ---------------------------------------------------------------------------
// 3. adversarial_no_phases
// ---------------------------------------------------------------------------

/// Method with an empty phases list. The YAML schema declares `phases` as
/// `Vec<RawPhase>`, so an empty list is syntactically valid. Normalization
/// currently succeeds — this documents the behavior. If future validation
/// rejects it, update this test accordingly.
#[test]
fn adversarial_no_phases() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-phases
  version: "1.0"
  title: No Phases
  phases: []
"#;
    let result = Normalizer::normalize(yaml);
    // DOCUMENTED BEHAVIOR: empty phases list normalizes successfully.
    // The normalizer treats zero phases as vacuously valid. The executor
    // would emit RunStarted immediately followed by RunCompleted.
    assert!(
        result.is_ok(),
        "empty phases list should normalize successfully (current behavior): {result:?}"
    );
    let def = result.unwrap();
    assert!(
        def.method.phases.is_empty(),
        "normalized definition should have zero phases"
    );
}

// ---------------------------------------------------------------------------
// 4. adversarial_empty_phase
// ---------------------------------------------------------------------------

/// Phase with an empty steps list. Same reasoning as no_phases: syntactically
/// valid, currently accepted.
#[test]
fn adversarial_empty_phase() {
    let yaml = r#"
schema_version: "1"
method:
  id: empty-phase
  version: "1.0"
  title: Empty Phase
  phases:
    - id: hollow
      title: Hollow Phase
      steps: []
"#;
    let result = Normalizer::normalize(yaml);
    // DOCUMENTED BEHAVIOR: phase with empty steps normalizes successfully.
    assert!(
        result.is_ok(),
        "empty steps list should normalize successfully (current behavior): {result:?}"
    );
    let def = result.unwrap();
    assert!(
        def.method.phases[0].steps.is_empty(),
        "normalized phase should have zero steps"
    );
}

// ---------------------------------------------------------------------------
// 5. adversarial_duplicate_phase_ids
// ---------------------------------------------------------------------------

/// Two phases with the same id must return DuplicatePhaseId.
#[test]
fn adversarial_duplicate_phase_ids() {
    let yaml = r#"
schema_version: "1"
method:
  id: dup-phases
  version: "1.0"
  title: Dup Phases
  phases:
    - id: alpha
      title: Alpha
      steps:
        - id: s1
          title: S1
          action: dispatch
          dispatch:
            instructions: foo
    - id: alpha
      title: Alpha Again
      steps:
        - id: s2
          title: S2
          action: dispatch
          dispatch:
            instructions: bar
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("duplicate phase ids must be an error");
    assert!(
        matches!(err, NormalizationError::DuplicatePhaseId { ref id } if id == "alpha"),
        "expected DuplicatePhaseId {{ id: 'alpha' }}, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 6. adversarial_duplicate_step_ids
// ---------------------------------------------------------------------------

/// Two steps in the same phase with the same id must return DuplicateStepId.
#[test]
fn adversarial_duplicate_step_ids() {
    let yaml = r#"
schema_version: "1"
method:
  id: dup-steps
  version: "1.0"
  title: Dup Steps
  phases:
    - id: phase-a
      title: Phase A
      steps:
        - id: same-id
          title: First
          action: dispatch
          dispatch:
            instructions: first
        - id: same-id
          title: Second
          action: dispatch
          dispatch:
            instructions: second
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("duplicate step ids must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::DuplicateStepId { ref id, ref phase_id }
            if id == "same-id" && phase_id == "phase-a"
        ),
        "expected DuplicateStepId, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 7. adversarial_nonexistent_output_reference
// ---------------------------------------------------------------------------

/// Method-level output `from:` pointing to a step output that does not exist
/// must return UnresolvedOutputReference.
#[test]
fn adversarial_nonexistent_output_reference() {
    let yaml = r#"
schema_version: "1"
method:
  id: bad-output-ref
  version: "1.0"
  title: Bad Output Ref
  outputs:
    ghost:
      from: phase-one.step-one.nonexistent_output
  phases:
    - id: phase-one
      title: Phase One
      steps:
        - id: step-one
          title: Step One
          action: dispatch
          dispatch:
            instructions: do it
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("nonexistent output reference must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::UnresolvedOutputReference {
                ref output_name,
                ref step_output,
                ..
            }
            if output_name == "ghost" && step_output == "nonexistent_output"
        ),
        "expected UnresolvedOutputReference, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 8. adversarial_invalid_schema_version
// ---------------------------------------------------------------------------

/// schema_version other than "1" must return InvalidSchemaVersion.
#[test]
fn adversarial_invalid_schema_version() {
    let yaml = r#"
schema_version: "99"
method:
  id: bad-ver
  version: "1.0"
  title: Bad Version
  phases:
    - id: p
      title: P
      steps:
        - id: s
          title: S
          action: dispatch
          dispatch:
            instructions: x
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("schema_version 99 must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::InvalidSchemaVersion { ref version } if version == "99"
        ),
        "expected InvalidSchemaVersion, got: {err}"
    );
    let msg = err.to_string();
    assert!(
        msg.contains("99"),
        "error message should mention the bad version: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 9. adversarial_missing_schema_version
// ---------------------------------------------------------------------------

/// No schema_version field at all must fail at deserialization.
#[test]
fn adversarial_missing_schema_version() {
    let yaml = r#"
method:
  id: no-sv
  version: "1.0"
  title: No Schema Version
  phases:
    - id: p
      title: P
      steps:
        - id: s
          title: S
          action: dispatch
          dispatch:
            instructions: x
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("missing schema_version must be an error");
    // serde_yaml will report a missing field error
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError, got: {err}"
    );
    let msg = err.to_string();
    assert!(
        msg.contains("schema_version") || msg.contains("missing field"),
        "error should mention schema_version: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 10. adversarial_invalid_action_type
// ---------------------------------------------------------------------------

/// action: "teleport" (not a recognized action) must return InvalidActionType.
#[test]
fn adversarial_invalid_action_type() {
    let yaml = r#"
schema_version: "1"
method:
  id: bad-action
  version: "1.0"
  title: Bad Action
  phases:
    - id: p
      title: P
      steps:
        - id: teleport-step
          title: Teleport
          action: teleport
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("action 'teleport' must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::InvalidActionType { ref action, ref step_id }
            if action == "teleport" && step_id == "teleport-step"
        ),
        "expected InvalidActionType, got: {err}"
    );
    let msg = err.to_string();
    assert!(
        msg.contains("teleport"),
        "error should mention the bad action: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 11. adversarial_dispatch_without_config
// ---------------------------------------------------------------------------

/// action: dispatch but no dispatch: section must return MissingActionConfig.
#[test]
fn adversarial_dispatch_without_config() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-config
  version: "1.0"
  title: No Config
  phases:
    - id: p
      title: P
      steps:
        - id: orphan
          title: Orphan Dispatch
          action: dispatch
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("dispatch without config must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::MissingActionConfig { ref step_id } if step_id == "orphan"
        ),
        "expected MissingActionConfig, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 12. adversarial_special_chars_in_ids
// ---------------------------------------------------------------------------

/// Phase/step ids with `/`, `..`, spaces, and other special characters
/// should not cause path traversal or panics. The normalizer does not
/// currently validate id characters; this documents the behavior.
#[test]
fn adversarial_special_chars_in_ids() {
    let cases = [
        ("../../etc/passwd", "step-ok"),
        ("phase ok", "step with spaces"),
        ("phase/slash", "step/slash"),
        ("phase\0null", "step-ok"), // null byte
        ("..", ".."),               // parent dir
        (".", "."),                 // current dir
    ];

    for (phase_id, step_id) in cases {
        let yaml = format!(
            r#"
schema_version: "1"
method:
  id: special-chars
  version: "1.0"
  title: Special Chars
  phases:
    - id: "{phase_id}"
      title: Phase
      steps:
        - id: "{step_id}"
          title: Step
          action: dispatch
          dispatch:
            instructions: test
"#
        );
        // We only care that it does not panic. Whether it errors or succeeds
        // is an open design question (no id validation exists today).
        let result = std::panic::catch_unwind(|| Normalizer::normalize(&yaml));
        assert!(
            result.is_ok(),
            "normalizer panicked on phase_id={phase_id:?}, step_id={step_id:?}"
        );
        // DOCUMENTED BEHAVIOR: the normalizer does not validate id characters.
        // Path traversal safety is the executor's responsibility when mapping
        // ids to filesystem paths. Future work should add id validation.
    }
}

// ---------------------------------------------------------------------------
// 13. adversarial_very_long_ids
// ---------------------------------------------------------------------------

/// 500-character phase and step ids. Must not panic; should normalize
/// successfully (no length validation exists today).
#[test]
fn adversarial_very_long_ids() {
    let long_id = "x".repeat(500);
    let yaml = format!(
        r#"
schema_version: "1"
method:
  id: long-ids
  version: "1.0"
  title: Long IDs
  phases:
    - id: {long_id}
      title: Long Phase
      steps:
        - id: {long_id}
          title: Long Step
          action: dispatch
          dispatch:
            instructions: test
"#
    );
    let result = Normalizer::normalize(&yaml);
    // DOCUMENTED BEHAVIOR: no id length validation. Normalizes successfully.
    assert!(
        result.is_ok(),
        "500-char ids should normalize successfully (current behavior): {result:?}"
    );
    let def = result.unwrap();
    assert_eq!(def.method.phases[0].id.len(), 500);
    assert_eq!(def.method.phases[0].steps[0].id.len(), 500);
}

// ---------------------------------------------------------------------------
// 14. adversarial_unicode_ids
// ---------------------------------------------------------------------------

/// Phase/step ids with emoji and CJK characters. Must not panic.
#[test]
fn adversarial_unicode_ids() {
    // Note: YAML unicode escapes (\u) are only valid inside double-quoted
    // YAML strings, and serde_yaml may not handle them. We test with Rust
    // string literals containing actual unicode codepoints instead.
    let yaml_literal = "
schema_version: \"1\"
method:
  id: unicode-test
  version: \"1.0\"
  title: Unicode Test
  phases:
    - id: \"phase-\u{1F680}\"
      title: Rocket Phase
      steps:
        - id: \"step-\u{4E16}\u{754C}\"
          title: World Step
          action: dispatch
          dispatch:
            instructions: test
";
    let result = Normalizer::normalize(yaml_literal);
    // DOCUMENTED BEHAVIOR: unicode ids normalize successfully.
    assert!(
        result.is_ok(),
        "unicode ids should normalize without panic: {result:?}"
    );
    let def = result.unwrap();
    assert!(def.method.phases[0].id.contains('\u{1F680}'));
    assert!(def.method.phases[0].steps[0].id.contains('\u{4E16}'));
}

// ---------------------------------------------------------------------------
// 15. adversarial_null_values
// ---------------------------------------------------------------------------

/// Explicit null/~ for required fields. IMPORTANT FINDING: serde_yaml
/// coerces YAML null values (`~`, `null`, `Null`, `NULL`) to their string
/// representations when the target type is `String`. This means:
/// - `id: ~` becomes `id: "~"`
/// - `id: null` becomes `id: "null"`
/// This is NOT a validation error at the serde level. The normalizer would
/// need explicit post-deserialization validation to reject these.
/// For non-scalar types like `Vec`, YAML null does cause a type error.
#[test]
fn adversarial_null_values() {
    // DOCUMENTED FINDING: `id: ~` is parsed as the literal string "~".
    let yaml_tilde_id = r#"
schema_version: "1"
method:
  id: ~
  version: "1.0"
  title: Tilde Id
  phases: []
"#;
    let result = Normalizer::normalize(yaml_tilde_id);
    assert!(
        result.is_ok(),
        "serde_yaml coerces ~ to string '~' for String fields: {result:?}"
    );
    let def = result.unwrap();
    assert_eq!(def.method.id, "~", "id should be the literal string '~'");

    // DOCUMENTED FINDING: `id: null` is also parsed as the literal
    // string "null". serde_yaml does NOT reject YAML null for String types.
    // This could be a silent data integrity issue if authors accidentally
    // use `null` for a required id field.
    let yaml_null_id = r#"
schema_version: "1"
method:
  id: null
  version: "1.0"
  title: Null Id
  phases: []
"#;
    let result = Normalizer::normalize(yaml_null_id);
    assert!(
        result.is_ok(),
        "serde_yaml coerces null to string 'null' for String fields: {result:?}"
    );
    let def = result.unwrap();
    assert_eq!(
        def.method.id, "null",
        "id should be the literal string 'null' — potential silent data loss"
    );

    // DOCUMENTED FINDING: same behavior for schema_version: null.
    // The normalizer will see version string "null", which != "1",
    // so it correctly rejects with InvalidSchemaVersion.
    let yaml_null_sv = r#"
schema_version: null
method:
  id: test
  version: "1.0"
  title: Test
  phases: []
"#;
    let result = Normalizer::normalize(yaml_null_sv);
    let err = result.expect_err("schema_version 'null' is not '1'");
    assert!(
        matches!(err, NormalizationError::InvalidSchemaVersion { ref version } if version == "null"),
        "expected InvalidSchemaVersion with version='null', got: {err}"
    );

    // null for phases (not optional — Vec<RawPhase>). This IS rejected
    // because serde_yaml cannot coerce null to a Vec.
    let yaml_null_phases = r#"
schema_version: "1"
method:
  id: test
  version: "1.0"
  title: Test
  phases: null
"#;
    let result = Normalizer::normalize(yaml_null_phases);
    let err = result.expect_err("null phases must be an error");
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError for null phases, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 16. adversarial_extra_unknown_fields
// ---------------------------------------------------------------------------

/// Extra YAML keys not in the schema should be silently ignored by serde
/// (default behavior without `#[serde(deny_unknown_fields)]`).
#[test]
fn adversarial_extra_unknown_fields() {
    let yaml = r#"
schema_version: "1"
some_random_key: totally_unexpected
method:
  id: extra-fields
  version: "1.0"
  title: Extra Fields
  nonsense: 42
  phases:
    - id: p
      title: P
      bogus_phase_field: true
      steps:
        - id: s
          title: S
          action: dispatch
          invisible_step_field: [1, 2, 3]
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    // DOCUMENTED BEHAVIOR: unknown fields are silently ignored.
    // If deny_unknown_fields is added later, this test must be updated.
    assert!(
        result.is_ok(),
        "unknown fields should be silently ignored: {result:?}"
    );
}

// ---------------------------------------------------------------------------
// 17. adversarial_all_action_types
// ---------------------------------------------------------------------------

/// One step of each action type (dispatch, interactive, synthesis,
/// pipeline-execute) in a single method. All must normalize correctly.
#[test]
fn adversarial_all_action_types() {
    let yaml = r#"
schema_version: "1"
method:
  id: all-actions
  version: "1.0"
  title: All Action Types
  phases:
    - id: phase
      title: Phase
      steps:
        - id: dispatch-step
          title: Dispatch
          action: dispatch
          dispatch:
            instructions: dispatch it
        - id: interactive-step
          title: Interactive
          action: interactive
          interactive:
            prompt: "What do you think?"
            response_type: text
            output: user-response.md
        - id: synthesis-step
          title: Synthesis
          action: synthesis
          synthesis:
            instructions: synthesize it
            output: synthesis-output.md
        - id: pipeline-step
          title: Pipeline Execute
          action: pipeline-execute
          pipeline_execute:
            pipeline: build-pipeline
            inputs:
              src: "./src"
            outputs:
              artifact: "./dist"
"#;
    let result = Normalizer::normalize(yaml);
    assert!(
        result.is_ok(),
        "all action types should normalize: {result:?}"
    );

    let def = result.unwrap();
    let steps = &def.method.phases[0].steps;
    assert_eq!(steps.len(), 4);

    use capacitor_core::method_runner::definition::{ActionKind, StepActionConfig};

    assert_eq!(steps[0].action, ActionKind::Dispatch);
    assert!(matches!(steps[0].config, StepActionConfig::Dispatch { .. }));

    assert_eq!(steps[1].action, ActionKind::Interactive);
    assert!(matches!(
        steps[1].config,
        StepActionConfig::Interactive { .. }
    ));

    assert_eq!(steps[2].action, ActionKind::Synthesis);
    assert!(matches!(
        steps[2].config,
        StepActionConfig::Synthesis { .. }
    ));

    assert_eq!(steps[3].action, ActionKind::PipelineExecute);
    assert!(matches!(
        steps[3].config,
        StepActionConfig::PipelineExecute { .. }
    ));
}

// ---------------------------------------------------------------------------
// 18. adversarial_max_attempts_zero
// ---------------------------------------------------------------------------

/// max_attempts: 0 must be rejected — executor would never dispatch.
#[test]
fn adversarial_max_attempts_zero() {
    let yaml = r#"
schema_version: "1"
method:
  id: zero-attempts
  version: "1.0"
  title: Zero Attempts
  phases:
    - id: p
      title: P
      steps:
        - id: s
          title: S
          action: dispatch
          max_attempts: 0
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    assert!(result.is_err(), "max_attempts: 0 should be rejected");
    let err = result.unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("max_attempts") && msg.contains("0"),
        "error should mention max_attempts and the value: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 19. adversarial_locator_too_few_segments
// ---------------------------------------------------------------------------

/// Output locator with only 2 segments (e.g., "phase.step" instead of
/// "phase.step.output") must return InvalidLocator.
#[test]
fn adversarial_locator_too_few_segments() {
    let yaml = r#"
schema_version: "1"
method:
  id: bad-locator
  version: "1.0"
  title: Bad Locator
  outputs:
    broken:
      from: phase.step
  phases:
    - id: phase
      title: Phase
      steps:
        - id: step
          title: Step
          action: dispatch
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("2-segment locator must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::InvalidLocator { ref locator, ref output_name }
            if locator == "phase.step" && output_name == "broken"
        ),
        "expected InvalidLocator, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 20. adversarial_locator_empty_segment
// ---------------------------------------------------------------------------

/// Output locator with an empty segment (e.g., "phase..output") must error.
/// The split('.') produces ["phase", "", "output"], which has 3 segments,
/// so it passes the length check but the empty segment should cause an
/// unresolved reference since no step has an empty id.
#[test]
fn adversarial_locator_empty_segment() {
    let yaml = r#"
schema_version: "1"
method:
  id: empty-segment
  version: "1.0"
  title: Empty Segment
  outputs:
    broken:
      from: "phase..output"
  phases:
    - id: phase
      title: Phase
      steps:
        - id: step
          title: Step
          action: dispatch
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("locator with empty segment must be an error");
    // The split produces ["phase", "", "output"], which has 3 segments.
    // It will look for step_id="" in phase "phase" and fail with
    // UnresolvedStepReference.
    assert!(
        matches!(
            err,
            NormalizationError::UnresolvedStepReference { ref step_id, .. } if step_id.is_empty()
        ),
        "expected UnresolvedStepReference with empty step_id, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 21. adversarial_run_nonexistent_definition
// ---------------------------------------------------------------------------

/// Pointing execute_normalize at a definition file that does not exist must
/// return an IoError, not panic.
#[test]
fn adversarial_run_nonexistent_definition() {
    use capacitor_core::method_runner::definition::DefinitionSource;
    use capacitor_core::method_runner::executor::{execute_normalize, RunError};

    let source = DefinitionSource {
        definition_path: "/tmp/adversarial-test-nonexistent-path-does-not-exist.yaml".into(),
        execution_root: "/tmp/adversarial-test-exec-root".into(),
    };

    let result = execute_normalize(&source);
    let err = result.expect_err("nonexistent definition must be an error");
    assert!(
        matches!(err, RunError::IoError(_)),
        "expected RunError::IoError, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// 22. adversarial_run_existing_method_dir
// ---------------------------------------------------------------------------

/// Running execute_normalize twice in the same root should succeed both
/// times (idempotent: overwrites the snapshot and step.json files).
#[test]
fn adversarial_run_existing_method_dir() {
    use capacitor_core::method_runner::definition::DefinitionSource;
    use capacitor_core::method_runner::executor::execute_normalize;
    use std::io::Write;

    let tmp = tempfile::tempdir().expect("failed to create tempdir");
    let yaml_path = tmp.path().join("method.yaml");
    let exec_root = tmp.path().join("run");

    {
        let mut f = std::fs::File::create(&yaml_path).unwrap();
        write!(f, "{}", minimal_valid_yaml()).unwrap();
    }

    let source = DefinitionSource {
        definition_path: yaml_path.clone(),
        execution_root: exec_root.clone(),
    };

    // First run
    let result1 = execute_normalize(&source);
    assert!(result1.is_ok(), "first run should succeed: {result1:?}");

    // Verify .method/ exists
    assert!(
        exec_root.join(".method").exists(),
        ".method/ should exist after first run"
    );

    // Second run — should succeed, overwriting the existing snapshot
    let result2 = execute_normalize(&source);
    assert!(
        result2.is_ok(),
        "second run (idempotent overwrite) should succeed: {result2:?}"
    );

    // Verify definition snapshot still readable
    let snapshot_path = exec_root.join(".method").join("definition.snapshot.yaml");
    let content = std::fs::read_to_string(&snapshot_path)
        .expect("snapshot should be readable after second run");
    assert!(
        content.contains("test-method"),
        "snapshot should contain the method id"
    );
}

// ---------------------------------------------------------------------------
// Additional edge cases discovered during analysis
// ---------------------------------------------------------------------------

/// Single-segment locator (just "output") must return InvalidLocator.
#[test]
fn adversarial_locator_single_segment() {
    let yaml = r#"
schema_version: "1"
method:
  id: single-seg
  version: "1.0"
  title: Single Segment
  outputs:
    broken:
      from: "just-an-output"
  phases:
    - id: phase
      title: Phase
      steps:
        - id: step
          title: Step
          action: dispatch
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("single-segment locator must be an error");
    assert!(
        matches!(err, NormalizationError::InvalidLocator { .. }),
        "expected InvalidLocator, got: {err}"
    );
}

/// Interactive action without interactive config must return
/// MissingActionConfig.
#[test]
fn adversarial_interactive_without_config() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-interactive-config
  version: "1.0"
  title: Missing Interactive Config
  phases:
    - id: p
      title: P
      steps:
        - id: int-step
          title: Int Step
          action: interactive
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("interactive without config must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::MissingActionConfig { ref step_id } if step_id == "int-step"
        ),
        "expected MissingActionConfig, got: {err}"
    );
}

/// Synthesis action without synthesis config must return MissingActionConfig.
#[test]
fn adversarial_synthesis_without_config() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-synth-config
  version: "1.0"
  title: Missing Synthesis Config
  phases:
    - id: p
      title: P
      steps:
        - id: synth-step
          title: Synth Step
          action: synthesis
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("synthesis without config must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::MissingActionConfig { ref step_id } if step_id == "synth-step"
        ),
        "expected MissingActionConfig, got: {err}"
    );
}

/// Pipeline-execute action without pipeline_execute config must return
/// MissingActionConfig.
#[test]
fn adversarial_pipeline_execute_without_config() {
    let yaml = r#"
schema_version: "1"
method:
  id: no-pipe-config
  version: "1.0"
  title: Missing Pipeline Config
  phases:
    - id: p
      title: P
      steps:
        - id: pipe-step
          title: Pipe Step
          action: pipeline-execute
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("pipeline-execute without config must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::MissingActionConfig { ref step_id } if step_id == "pipe-step"
        ),
        "expected MissingActionConfig, got: {err}"
    );
}

/// Method output referencing a nonexistent phase must return
/// UnresolvedPhaseReference.
#[test]
fn adversarial_output_references_nonexistent_phase() {
    let yaml = r#"
schema_version: "1"
method:
  id: ghost-phase
  version: "1.0"
  title: Ghost Phase Ref
  outputs:
    result:
      from: "nonexistent-phase.step.output"
  phases:
    - id: real-phase
      title: Real Phase
      steps:
        - id: step
          title: Step
          action: dispatch
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("nonexistent phase reference must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::UnresolvedPhaseReference { ref phase_id, .. }
            if phase_id == "nonexistent-phase"
        ),
        "expected UnresolvedPhaseReference, got: {err}"
    );
}

/// Method output referencing a nonexistent step in an existing phase must
/// return UnresolvedStepReference.
#[test]
fn adversarial_output_references_nonexistent_step() {
    let yaml = r#"
schema_version: "1"
method:
  id: ghost-step
  version: "1.0"
  title: Ghost Step Ref
  outputs:
    result:
      from: "phase.nonexistent-step.output"
  phases:
    - id: phase
      title: Phase
      steps:
        - id: real-step
          title: Real Step
          action: dispatch
          dispatch:
            instructions: test
"#;
    let result = Normalizer::normalize(yaml);
    let err = result.expect_err("nonexistent step reference must be an error");
    assert!(
        matches!(
            err,
            NormalizationError::UnresolvedStepReference { ref step_id, .. }
            if step_id == "nonexistent-step"
        ),
        "expected UnresolvedStepReference, got: {err}"
    );
}

/// Whitespace-only YAML must fail at deserialization, not panic.
#[test]
fn adversarial_whitespace_only_yaml() {
    let result = Normalizer::normalize("   \n\t\n  ");
    let err = result.expect_err("whitespace-only YAML must be an error");
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError, got: {err}"
    );
}

/// YAML with just a comment and nothing else must fail.
#[test]
fn adversarial_comment_only_yaml() {
    let result = Normalizer::normalize("# This is just a comment\n# Nothing else");
    let err = result.expect_err("comment-only YAML must be an error");
    assert!(
        matches!(err, NormalizationError::YamlParseError(_)),
        "expected YamlParseError, got: {err}"
    );
}

/// schema_version: "1" as integer 1 (no quotes). serde_yaml handles this
/// by converting the integer to string during deserialization. Documents
/// behavior.
#[test]
fn adversarial_schema_version_as_integer() {
    let yaml = r#"
schema_version: 1
method:
  id: int-sv
  version: "1.0"
  title: Integer Schema Version
  phases:
    - id: p
      title: P
      steps:
        - id: s
          title: S
          action: dispatch
          dispatch:
            instructions: test
"#;
    // serde_yaml may or may not coerce integer 1 to string "1".
    // If it does, normalization succeeds. If not, it's a parse error.
    // Either way, no panic.
    let result = std::panic::catch_unwind(|| Normalizer::normalize(yaml));
    assert!(result.is_ok(), "must not panic on integer schema_version");
}
