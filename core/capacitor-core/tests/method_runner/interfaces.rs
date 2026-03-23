//! Interface contract tests for the method runner (IF1–IF9).
//!
//! Each test is named `interface_if{N}_{description}` and verifies the error
//! contract, boundary behavior, and invariants defined in
//! `docs/method-runner-spec/execution-packet.md`.

use std::io::Write;
use std::path::PathBuf;

use capacitor_core::method_runner::adapters::{
    FakePromptBuilder, FakeWorkerDispatcher, InteractiveIO, InteractivePrompt, InteractiveResponse,
    PromptBuildRequest, PromptBuilder, WorkerDispatchRequest, WorkerDispatcher,
};
use capacitor_core::method_runner::definition::{DefinitionLoader, Normalizer};
use capacitor_core::method_runner::events::{
    append_event, make_envelope, read_last_seq, recover_events, MethodEventKind,
};
use capacitor_core::method_runner::handoff::{ingest_handoff, parse_handoff, HandoffParseError};
use capacitor_core::method_runner::output::{parse_locator, LocatorError};
use capacitor_core::method_runner::state::{
    AttemptStatus, PhaseStatus, RunStatus, StepStatus, WorkerStatus,
};
use capacitor_core::method_runner::storage::{acquire_lock, LockInfo, MethodRunPaths};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../methods/fixtures")
        .join(name)
}

fn read_fixture(name: &str) -> String {
    std::fs::read_to_string(fixture_path(name))
        .unwrap_or_else(|e| panic!("failed to read fixture {name}: {e}"))
}

/// Build the full canonical handoff content with all 7 headings.
fn full_handoff_content() -> String {
    "\
# Handoff

### Files Changed
- src/main.rs

### Tests Run
- cargo test

### Verification
- All checks pass

### Verdict
CLEAN

### Completion Claim
COMPLETE

### Issues Found
None

### Next Steps
None
"
    .to_string()
}

// =========================================================================
// IF1 — PromptBuilder
// =========================================================================

#[test]
fn interface_if1_fake_prompt_builder_idempotence() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay");

    let request = PromptBuildRequest {
        phase_id: "bootstrap".into(),
        step_id: "dispatch".into(),
        attempt: 1,
        relay_root: relay_root.clone(),
        instructions: "Do the thing.".into(),
    };

    let builder = FakePromptBuilder;

    // First call
    let result1 = builder.build_prompt(&request).unwrap();
    let header1 = std::fs::read(&result1.header_path).unwrap();
    let prompt1 = std::fs::read(&result1.prompt_path).unwrap();

    // Second call — same request, overwrite files
    let result2 = builder.build_prompt(&request).unwrap();
    let header2 = std::fs::read(&result2.header_path).unwrap();
    let prompt2 = std::fs::read(&result2.prompt_path).unwrap();

    // Byte-identical outputs
    assert_eq!(header1, header2, "prompt-header.md must be idempotent");
    assert_eq!(prompt1, prompt2, "prompt.md must be idempotent");
}

#[test]
fn interface_if1_prompt_builder_creates_expected_files() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay");

    let request = PromptBuildRequest {
        phase_id: "research".into(),
        step_id: "scan".into(),
        attempt: 2,
        relay_root: relay_root.clone(),
        instructions: "Scan the codebase.".into(),
    };

    let builder = FakePromptBuilder;
    let result = builder.build_prompt(&request).unwrap();

    assert_eq!(result.header_path, relay_root.join("prompt-header.md"));
    assert_eq!(result.prompt_path, relay_root.join("prompt.md"));

    assert!(
        result.header_path.exists(),
        "prompt-header.md must exist on disk"
    );
    assert!(result.prompt_path.exists(), "prompt.md must exist on disk");

    // Verify header contains step metadata
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(header.contains("scan"), "header should contain step_id");
    assert!(
        header.contains("research"),
        "header should contain phase_id"
    );
    assert!(header.contains("2"), "header should contain attempt number");

    // Verify prompt contains instructions
    let prompt = std::fs::read_to_string(&result.prompt_path).unwrap();
    assert!(
        prompt.contains("Scan the codebase"),
        "prompt should contain instructions"
    );
}

// =========================================================================
// IF2 — WorkerDispatcher
// =========================================================================

#[test]
fn interface_if2_fake_dispatcher_creates_handoff() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/primary");

    let request = WorkerDispatchRequest {
        phase_id: "bootstrap".into(),
        step_id: "dispatch".into(),
        attempt: 1,
        worker_id: "primary".into(),
        relay_root: relay_root.clone(),
    };

    let dispatcher = FakeWorkerDispatcher;
    let result = dispatcher.dispatch(&request).unwrap();

    // Verify HANDOFF.md exists at relay root
    let handoff_path = relay_root.join("HANDOFF.md");
    assert!(handoff_path.exists(), "HANDOFF.md must exist at relay root");

    // Verify it has canonical headings
    let content = std::fs::read_to_string(&handoff_path).unwrap();
    assert!(
        content.contains("### Verdict"),
        "must contain Verdict heading"
    );
    assert!(
        content.contains("### Completion Claim"),
        "must contain Completion Claim heading"
    );
    assert!(content.contains("CLEAN"), "must contain CLEAN verdict");
    assert!(
        content.contains("COMPLETE"),
        "must contain COMPLETE completion claim"
    );

    // Verify exit_code is 0 for clean dispatch
    assert_eq!(
        result.exit_code, 0,
        "clean dispatch should have exit_code 0"
    );
    assert_eq!(result.worker_id, "primary");
}

// =========================================================================
// IF3 — ArtifactIngestor / Handoff Parser
// =========================================================================

#[test]
fn interface_if3_parse_handoff_happy_path() {
    let content = full_handoff_content();
    let parsed = parse_handoff(&content, "primary").unwrap();

    assert_eq!(parsed.verdict.as_deref(), Some("CLEAN"));
    assert_eq!(parsed.completion_claim.as_deref(), Some("COMPLETE"));
    assert_eq!(parsed.files_changed.as_deref(), Some("- src/main.rs"));
    assert_eq!(parsed.tests_run.as_deref(), Some("- cargo test"));
    assert_eq!(parsed.verification.as_deref(), Some("- All checks pass"));
    assert_eq!(parsed.issues_found.as_deref(), Some("None"));
    assert_eq!(parsed.next_steps.as_deref(), Some("None"));
    assert_eq!(parsed.worker_id, "primary");

    // No warnings about invalid values or duplicates
    let structural_warnings: Vec<&String> = parsed
        .parse_warnings
        .iter()
        .filter(|w| {
            w.contains("duplicate")
                || w.contains("unknown")
                || w.contains("invalid")
                || w.contains("empty")
        })
        .collect();
    assert!(
        structural_warnings.is_empty(),
        "happy path should have no structural warnings, got: {:?}",
        structural_warnings
    );
}

#[test]
fn interface_if3_parse_handoff_missing_heading() {
    // Content with Verdict heading but missing Completion Claim
    let content = "\
### Files Changed
- src/main.rs

### Tests Run
- cargo test

### Verification
- ok

### Verdict
CLEAN

### Issues Found
None

### Next Steps
None
";
    let parsed = parse_handoff(content, "w1").unwrap();

    // Completion Claim is missing
    assert_eq!(parsed.completion_claim, None);

    // Should have a warning about missing section
    assert!(
        parsed
            .parse_warnings
            .iter()
            .any(|w| w.contains("missing") && w.contains("Completion Claim")),
        "should warn about missing Completion Claim section"
    );
}

#[test]
fn interface_if3_parse_handoff_duplicate_heading() {
    let content = "\
### Verdict
CLEAN

### Verdict
ISSUES FOUND
";
    let parsed = parse_handoff(content, "w1").unwrap();

    // First wins
    assert_eq!(parsed.verdict.as_deref(), Some("CLEAN"));

    assert!(
        parsed
            .parse_warnings
            .iter()
            .any(|w| w.contains("duplicate") && w.contains("Verdict")),
        "should warn about duplicate heading"
    );
}

#[test]
fn interface_if3_parse_handoff_no_headings_at_all() {
    let content = "Just some text with no markdown headings at all.\nMore text here.\n";
    let result = parse_handoff(content, "w1");

    assert!(result.is_err());
    match result.unwrap_err() {
        HandoffParseError::NoHeadingsFound => {} // expected
        other => panic!("expected NoHeadingsFound, got: {other:?}"),
    }
}

#[test]
fn interface_if3_parse_handoff_empty_section() {
    let content = "\
### Verdict

### Completion Claim
COMPLETE
";
    let parsed = parse_handoff(content, "w1").unwrap();

    // Empty section yields Some("") — the section exists but is empty
    assert_eq!(parsed.verdict.as_deref(), Some(""));

    assert!(
        parsed
            .parse_warnings
            .iter()
            .any(|w| w.contains("empty") && w.contains("Verdict")),
        "should warn about empty section"
    );
}

#[test]
fn interface_if3_parse_handoff_invalid_verdict_value() {
    let content = "\
### Verdict
MAYBE_OK

### Completion Claim
COMPLETE
";
    let parsed = parse_handoff(content, "w1").unwrap();

    // Kept as-is
    assert_eq!(parsed.verdict.as_deref(), Some("MAYBE_OK"));

    assert!(
        parsed
            .parse_warnings
            .iter()
            .any(|w| w.contains("invalid verdict")),
        "should warn about invalid verdict value"
    );
}

#[test]
fn interface_if3_parse_handoff_invalid_completion_claim() {
    let content = "\
### Verdict
CLEAN

### Completion Claim
DONE
";
    let parsed = parse_handoff(content, "w1").unwrap();

    // Kept as-is
    assert_eq!(parsed.completion_claim.as_deref(), Some("DONE"));

    assert!(
        parsed
            .parse_warnings
            .iter()
            .any(|w| w.contains("invalid completion claim")),
        "should warn about invalid completion claim value"
    );
}

#[test]
fn interface_if3_parse_handoff_unknown_headings_ignored() {
    let content = "\
### Custom Section
some content

### Verdict
CLEAN

### Another Custom
more content
";
    let parsed = parse_handoff(content, "w1").unwrap();

    assert_eq!(parsed.verdict.as_deref(), Some("CLEAN"));

    let unknown_warnings: Vec<&String> = parsed
        .parse_warnings
        .iter()
        .filter(|w| w.contains("unknown"))
        .collect();
    assert!(
        unknown_warnings.len() >= 2,
        "should warn about at least 2 unknown headings, got: {:?}",
        unknown_warnings
    );
}

#[test]
fn interface_if3_ingest_handoff_copies_and_writes_json() {
    let tmp = tempfile::tempdir().unwrap();
    let paths = MethodRunPaths::new(tmp.path());

    // Create the source handoff file at the relay root
    let relay_root = paths.worker_relay_root("research", "scan", 1, "primary");
    std::fs::create_dir_all(&relay_root).unwrap();
    let source = relay_root.join("HANDOFF.md");
    std::fs::write(&source, full_handoff_content()).unwrap();

    let result = ingest_handoff(&paths, "research", "scan", 1, "primary", &source).unwrap();

    // Canonical path should exist
    assert!(
        result.canonical_path.exists(),
        "canonical handoff copy must exist"
    );
    let expected_canonical = paths.canonical_handoff("research", "scan", 1, "primary");
    assert_eq!(result.canonical_path, expected_canonical);

    // Parsed JSON should exist
    let parsed_json_path = paths
        .attempt_dir("research", "scan", 1)
        .join("parsed-handoffs/primary.json");
    assert!(parsed_json_path.exists(), "parsed JSON must be written");

    // Verify parsed JSON deserializes properly
    let json_content = std::fs::read_to_string(&parsed_json_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json_content).unwrap();
    assert_eq!(parsed["verdict"], "CLEAN");
    assert_eq!(parsed["completion_claim"], "COMPLETE");
}

// =========================================================================
// IF4 — InteractiveIO
// =========================================================================

#[test]
fn interface_if4_interactive_io_trait_exists() {
    // Verify the trait has the expected method signatures by constructing
    // a minimal stub implementation. This confirms the API surface is correct.
    struct StubIO;
    impl InteractiveIO for StubIO {
        fn emit_prompt(&self, prompt: &InteractivePrompt) {
            let _ = &prompt.message;
        }
        fn capture_response(&self) -> InteractiveResponse {
            InteractiveResponse {
                body: "stub".into(),
            }
        }
    }

    let io = StubIO;
    io.emit_prompt(&InteractivePrompt {
        message: "Approve?".into(),
    });
    let response = io.capture_response();
    assert_eq!(response.body, "stub");
}

// =========================================================================
// IF5 — Definition Normalizer
// =========================================================================

#[test]
fn interface_if5_inheritance_cascade() {
    // Method defaults should cascade: method defaults -> phase -> step
    let yaml = r#"
schema_version: "1"
method:
  id: cascade-test
  version: "1.0"
  title: Cascade Test
  defaults:
    skills:
      - base-skill
    template: implement
    max_attempts: 3
    completion_policy: all_complete
  phases:
    - id: p1
      title: Phase 1
      skills:
        - phase-skill
      steps:
        - id: s1
          title: Step 1
          action: dispatch
          dispatch:
            instructions: do it
        - id: s2
          title: Step 2
          action: dispatch
          skills:
            - step-skill
          max_attempts: 5
          template: review
          completion_policy: first_clean
          dispatch:
            instructions: do it again
"#;

    let normalized = Normalizer::normalize(yaml).unwrap();
    let phase = &normalized.method.phases[0];
    let s1 = &phase.steps[0];
    let s2 = &phase.steps[1];

    // s1: inherits method defaults + phase skills, no step overrides
    assert_eq!(s1.max_attempts, 3, "s1 should inherit method max_attempts");
    assert_eq!(
        s1.template,
        Some("implement".into()),
        "s1 should inherit method template"
    );
    assert!(
        s1.skills.contains(&"base-skill".to_string()),
        "s1 should have method default skill"
    );
    assert!(
        s1.skills.contains(&"phase-skill".to_string()),
        "s1 should have phase skill"
    );
    assert_eq!(
        s1.completion_policy,
        capacitor_core::method_runner::definition::CompletionPolicy::AllComplete
    );

    // s2: overrides at step level
    assert_eq!(s2.max_attempts, 5, "s2 should override max_attempts");
    assert_eq!(
        s2.template,
        Some("review".into()),
        "s2 should override template"
    );
    assert!(
        s2.skills.contains(&"step-skill".to_string()),
        "s2 should have step-level skill"
    );
    assert!(
        s2.skills.contains(&"base-skill".to_string()),
        "s2 should still have method default skill"
    );
    assert!(
        s2.skills.contains(&"phase-skill".to_string()),
        "s2 should still have phase skill"
    );
    assert_eq!(
        s2.completion_policy,
        capacitor_core::method_runner::definition::CompletionPolicy::FirstClean
    );
}

#[test]
fn interface_if5_normalize_all_yaml_fixtures() {
    let fixtures = ["minimal-dispatch.yaml", "pipeline-blocked.yaml"];
    for name in &fixtures {
        let yaml = read_fixture(name);
        let result = Normalizer::normalize(&yaml);
        assert!(
            result.is_ok(),
            "fixture {name} should normalize cleanly: {:?}",
            result.err()
        );
    }

    // Also test spec-hardening from library
    let spec_hardening = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../methods/library/spec-hardening.yaml"),
    )
    .unwrap();
    let result = Normalizer::normalize(&spec_hardening);
    assert!(
        result.is_ok(),
        "spec-hardening.yaml should normalize cleanly: {:?}",
        result.err()
    );
}

#[test]
fn interface_if5_normalization_idempotent() {
    let yaml = read_fixture("minimal-dispatch.yaml");

    // Normalize
    let normalized = Normalizer::normalize(&yaml).unwrap();

    // Write snapshot
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_path = tmp.path().join("definition.snapshot.yaml");
    capacitor_core::method_runner::definition::write_snapshot(&snapshot_path, &normalized).unwrap();

    // Load snapshot and compare
    let reloaded = DefinitionLoader::load(&snapshot_path).unwrap();

    assert_eq!(
        normalized, reloaded,
        "normalize -> write -> load must be idempotent"
    );
}

// =========================================================================
// IF6 — State Machine Enforcer
// =========================================================================

// --- RunStatus ---

#[test]
fn interface_if6_run_legal_transitions() {
    // Created -> Running
    let s = RunStatus::Created.transition_to(RunStatus::Running, "r1");
    assert!(s.is_ok());

    // Running -> Completed
    let s = RunStatus::Running.transition_to(RunStatus::Completed, "r1");
    assert!(s.is_ok());

    // Running -> Failed
    let s = RunStatus::Running.transition_to(RunStatus::Failed, "r1");
    assert!(s.is_ok());

    // Running -> Blocked
    let s = RunStatus::Running.transition_to(RunStatus::Blocked, "r1");
    assert!(s.is_ok());

    // Blocked -> Running (unblock)
    let s = RunStatus::Blocked.transition_to(RunStatus::Running, "r1");
    assert!(s.is_ok());

    // Blocked -> Failed
    let s = RunStatus::Blocked.transition_to(RunStatus::Failed, "r1");
    assert!(s.is_ok());
}

#[test]
fn interface_if6_run_illegal_transitions() {
    // Completed -> Running (terminal is final)
    assert!(RunStatus::Completed
        .transition_to(RunStatus::Running, "r1")
        .is_err());

    // Created -> Completed (skipping Running)
    assert!(RunStatus::Created
        .transition_to(RunStatus::Completed, "r1")
        .is_err());

    // Failed -> Running
    assert!(RunStatus::Failed
        .transition_to(RunStatus::Running, "r1")
        .is_err());
}

// --- PhaseStatus ---

#[test]
fn interface_if6_phase_legal_transitions() {
    assert!(PhaseStatus::Pending
        .transition_to(PhaseStatus::Running, "p1")
        .is_ok());
    assert!(PhaseStatus::Running
        .transition_to(PhaseStatus::Completed, "p1")
        .is_ok());
    assert!(PhaseStatus::Running
        .transition_to(PhaseStatus::Failed, "p1")
        .is_ok());
    assert!(PhaseStatus::Running
        .transition_to(PhaseStatus::Blocked, "p1")
        .is_ok());
    assert!(PhaseStatus::Blocked
        .transition_to(PhaseStatus::Running, "p1")
        .is_ok());
}

#[test]
fn interface_if6_phase_illegal_transitions() {
    // Completed -> Running (terminal)
    assert!(PhaseStatus::Completed
        .transition_to(PhaseStatus::Running, "p1")
        .is_err());

    // Pending -> Completed (skipping Running)
    assert!(PhaseStatus::Pending
        .transition_to(PhaseStatus::Completed, "p1")
        .is_err());

    // Skipped -> Running
    assert!(PhaseStatus::Skipped
        .transition_to(PhaseStatus::Running, "p1")
        .is_err());
}

// --- StepStatus ---

#[test]
fn interface_if6_step_legal_transitions() {
    assert!(StepStatus::Pending
        .transition_to(StepStatus::Running, "s1")
        .is_ok());
    assert!(StepStatus::Running
        .transition_to(StepStatus::Completed, "s1")
        .is_ok());
    assert!(StepStatus::Running
        .transition_to(StepStatus::Failed, "s1")
        .is_ok());
    assert!(StepStatus::Running
        .transition_to(StepStatus::Blocked, "s1")
        .is_ok());
    assert!(StepStatus::Blocked
        .transition_to(StepStatus::Running, "s1")
        .is_ok());
}

#[test]
fn interface_if6_step_illegal_transitions() {
    // Completed -> Running
    assert!(StepStatus::Completed
        .transition_to(StepStatus::Running, "s1")
        .is_err());

    // Pending -> Completed (skip)
    assert!(StepStatus::Pending
        .transition_to(StepStatus::Completed, "s1")
        .is_err());

    // Failed -> Completed
    assert!(StepStatus::Failed
        .transition_to(StepStatus::Completed, "s1")
        .is_err());
}

// --- AttemptStatus ---

#[test]
fn interface_if6_attempt_legal_transitions() {
    assert!(AttemptStatus::Created
        .transition_to(AttemptStatus::Dispatching, "a1")
        .is_ok());
    assert!(AttemptStatus::Dispatching
        .transition_to(AttemptStatus::Running, "a1")
        .is_ok());
    assert!(AttemptStatus::Running
        .transition_to(AttemptStatus::HandoffReceived, "a1")
        .is_ok());
    assert!(AttemptStatus::Running
        .transition_to(AttemptStatus::Failed, "a1")
        .is_ok());
    assert!(AttemptStatus::HandoffReceived
        .transition_to(AttemptStatus::OutputBound, "a1")
        .is_ok());
    assert!(AttemptStatus::OutputBound
        .transition_to(AttemptStatus::Completed, "a1")
        .is_ok());
}

#[test]
fn interface_if6_attempt_illegal_transitions() {
    // Created -> Running (skip Dispatching)
    assert!(AttemptStatus::Created
        .transition_to(AttemptStatus::Running, "a1")
        .is_err());

    // Completed -> Failed (terminal)
    assert!(AttemptStatus::Completed
        .transition_to(AttemptStatus::Failed, "a1")
        .is_err());

    // Dispatching -> Completed (skip Running, HandoffReceived, OutputBound)
    assert!(AttemptStatus::Dispatching
        .transition_to(AttemptStatus::Completed, "a1")
        .is_err());
}

// --- WorkerStatus ---

#[test]
fn interface_if6_worker_legal_transitions() {
    assert!(WorkerStatus::Pending
        .transition_to(WorkerStatus::Dispatched, "w1")
        .is_ok());
    assert!(WorkerStatus::Dispatched
        .transition_to(WorkerStatus::Running, "w1")
        .is_ok());
    assert!(WorkerStatus::Running
        .transition_to(WorkerStatus::Completed, "w1")
        .is_ok());
    assert!(WorkerStatus::Running
        .transition_to(WorkerStatus::Failed, "w1")
        .is_ok());
}

#[test]
fn interface_if6_worker_illegal_transitions() {
    // Pending -> Running (skip Dispatched)
    assert!(WorkerStatus::Pending
        .transition_to(WorkerStatus::Running, "w1")
        .is_err());

    // Completed -> Running (terminal)
    assert!(WorkerStatus::Completed
        .transition_to(WorkerStatus::Running, "w1")
        .is_err());

    // Failed -> Completed (terminal)
    assert!(WorkerStatus::Failed
        .transition_to(WorkerStatus::Completed, "w1")
        .is_err());
}

// =========================================================================
// IF7 — Output Resolver
// =========================================================================

#[test]
fn interface_if7_parse_locator_3_segment() {
    let loc = parse_locator("research.scan.doc").unwrap();
    assert_eq!(loc.phase_id, "research");
    assert_eq!(loc.step_id, "scan");
    assert_eq!(loc.output_name, "doc");
    assert!(loc.worker_id.is_none());
}

#[test]
fn interface_if7_parse_locator_4_segment() {
    let loc = parse_locator("research.scan.worker1.doc").unwrap();
    assert_eq!(loc.phase_id, "research");
    assert_eq!(loc.step_id, "scan");
    assert_eq!(loc.worker_id.as_deref(), Some("worker1"));
    assert_eq!(loc.output_name, "doc");
}

#[test]
fn interface_if7_parse_locator_invalid_2_segments() {
    let result = parse_locator("phase.step");
    assert!(result.is_err());
    match result.unwrap_err() {
        LocatorError::InvalidFormat(_) => {}
        other => panic!("expected InvalidFormat, got: {other:?}"),
    }
}

#[test]
fn interface_if7_parse_locator_invalid_5_segments() {
    let result = parse_locator("a.b.c.d.e");
    assert!(result.is_err());
    match result.unwrap_err() {
        LocatorError::InvalidFormat(_) => {}
        other => panic!("expected InvalidFormat, got: {other:?}"),
    }
}

#[test]
fn interface_if7_parse_locator_empty_segment() {
    let result = parse_locator("phase..output");
    assert!(result.is_err());
    match result.unwrap_err() {
        LocatorError::EmptySegment => {}
        other => panic!("expected EmptySegment, got: {other:?}"),
    }
}

#[test]
fn interface_if7_parse_locator_empty_segment_4_seg() {
    let result = parse_locator("phase.step..output");
    assert!(result.is_err());
    match result.unwrap_err() {
        LocatorError::EmptySegment => {}
        other => panic!("expected EmptySegment, got: {other:?}"),
    }
}

// =========================================================================
// IF8 — Lock Manager
// =========================================================================

#[test]
fn interface_if8_acquire_release_cycle() {
    let tmp = tempfile::tempdir().unwrap();
    let lock_path = tmp.path().join("locks/run.lock");

    // Acquire
    let lock = acquire_lock(&lock_path, std::time::Duration::from_secs(1)).unwrap();
    assert!(lock_path.exists(), "lock file must exist after acquire");

    // Verify lock info
    let content = std::fs::read_to_string(&lock_path).unwrap();
    let info: LockInfo = serde_json::from_str(&content).unwrap();
    assert_eq!(info.pid, std::process::id());

    // Release by dropping
    drop(lock);
    assert!(!lock_path.exists(), "lock file must be removed after drop");
}

#[test]
fn interface_if8_stale_lock_detection_dead_pid() {
    let tmp = tempfile::tempdir().unwrap();
    let lock_path = tmp.path().join("locks/run.lock");
    std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();

    // Write a lock file with a dead PID (99999999 is almost certainly not alive)
    let stale_info = LockInfo {
        pid: 99999999,
        start_time: 0,
        hostname: "test".into(),
        acquired_at: "2024-01-01T00:00:00Z".into(),
    };
    let json = serde_json::to_string_pretty(&stale_info).unwrap();
    std::fs::write(&lock_path, json).unwrap();

    // Should detect stale lock, remove it, and acquire successfully
    let lock = acquire_lock(&lock_path, std::time::Duration::from_secs(1)).unwrap();
    assert!(lock_path.exists());

    // Verify it's our PID now
    let content = std::fs::read_to_string(&lock_path).unwrap();
    let info: LockInfo = serde_json::from_str(&content).unwrap();
    assert_eq!(info.pid, std::process::id());

    drop(lock);
}

#[test]
fn interface_if8_lock_removed_after_drop() {
    let tmp = tempfile::tempdir().unwrap();
    let lock_path = tmp.path().join("locks/run.lock");

    {
        let _lock = acquire_lock(&lock_path, std::time::Duration::from_secs(1)).unwrap();
        assert!(lock_path.exists());
        // Lock dropped at end of scope
    }

    assert!(
        !lock_path.exists(),
        "lock file must not exist after RunLock is dropped"
    );
}

// =========================================================================
// IF9 — Event Appender
// =========================================================================

#[test]
fn interface_if9_monotonicity_5_events() {
    let tmp = tempfile::tempdir().unwrap();
    let events_path = tmp.path().join(".method/events.ndjson");

    let mut seq: u64 = 0;
    let kinds = [
        MethodEventKind::DefinitionFrozen,
        MethodEventKind::RunStarted,
        MethodEventKind::PhaseStarted,
        MethodEventKind::StepStarted,
        MethodEventKind::StepCompleted,
    ];

    for kind in &kinds {
        let mut env = make_envelope("run-1", *kind);
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    // Verify seq is 1..5
    assert_eq!(seq, 5);

    let events = recover_events(&events_path).unwrap();
    assert_eq!(events.len(), 5);

    for (i, event) in events.iter().enumerate() {
        assert_eq!(
            event.seq,
            (i + 1) as u64,
            "event at index {i} should have seq {}",
            i + 1
        );
    }

    // Verify strictly increasing
    for window in events.windows(2) {
        assert!(
            window[1].seq > window[0].seq,
            "seq must be strictly increasing: {} should be > {}",
            window[1].seq,
            window[0].seq
        );
    }
}

#[test]
fn interface_if9_append_continues_from_existing() {
    let tmp = tempfile::tempdir().unwrap();
    let events_path = tmp.path().join(".method/events.ndjson");

    // Write first 3 events
    let mut seq: u64 = 0;
    for _ in 0..3 {
        let mut env = make_envelope("run-1", MethodEventKind::RunStarted);
        // We're just testing sequence continuation, so use a simple event
        // (the state machine doesn't apply here — we're testing the appender)
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }
    assert_eq!(seq, 3);

    // Simulate a restart: read last seq and continue
    let recovered_seq = read_last_seq(&events_path).unwrap();
    assert_eq!(recovered_seq, 3);

    let mut seq2 = recovered_seq;
    for _ in 0..2 {
        let mut env = make_envelope("run-1", MethodEventKind::PhaseStarted);
        append_event(&events_path, &mut env, &mut seq2).unwrap();
    }
    assert_eq!(seq2, 5);

    // Verify all 5 events have correct sequence numbers
    let events = recover_events(&events_path).unwrap();
    assert_eq!(events.len(), 5);
    for (i, event) in events.iter().enumerate() {
        assert_eq!(event.seq, (i + 1) as u64);
    }
}

#[test]
fn interface_if9_recover_events_handles_torn_tail() {
    let tmp = tempfile::tempdir().unwrap();
    let events_path = tmp.path().join(".method/events.ndjson");
    std::fs::create_dir_all(events_path.parent().unwrap()).unwrap();

    // Write 3 valid events
    let mut seq: u64 = 0;
    for _ in 0..3 {
        let mut env = make_envelope("run-1", MethodEventKind::RunStarted);
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    // Append a torn (invalid JSON) tail
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&events_path)
        .unwrap();
    writeln!(file, "{{\"seq\":4,\"incomplete_json").unwrap();
    drop(file);

    // Recover should return the 3 valid events and truncate the torn tail
    let events = recover_events(&events_path).unwrap();
    assert_eq!(events.len(), 3, "should recover only the 3 valid events");

    // Verify the file was truncated (no more torn tail)
    let content = std::fs::read_to_string(&events_path).unwrap();
    let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines.len(), 3, "file should be truncated to 3 valid lines");

    // Verify we can continue appending from the recovered position
    let last_seq = read_last_seq(&events_path).unwrap();
    assert_eq!(last_seq, 3);
}
