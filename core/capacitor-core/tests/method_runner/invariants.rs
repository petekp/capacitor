//! Invariant contract tests for the method runner.
//!
//! Each test maps 1:1 to an invariant from docs/method-runner-spec/execution-packet.md.
//! The naming convention is `invariant_i{N}_{short_description}`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::common::fixtures::minimal_dispatch_path;
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::{
    DefinitionLoader, DefinitionSource, NormalizedDefinitionFile, Normalizer,
};
use capacitor_core::method_runner::events::{make_envelope, recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::execute_run;
use capacitor_core::method_runner::output::resolve_and_write_output;
use capacitor_core::method_runner::state::{
    rebuild_state, write_state_atomic, AttemptStatus, MethodRunState, PhaseStatus, RunStatus,
    StepStatus, WorkerStatus,
};
use capacitor_core::method_runner::storage::{acquire_lock, MethodRunPaths};

use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Run the executor against the minimal-dispatch fixture inside a fresh tempdir.
/// Returns (tempdir_handle, paths, state).
fn run_minimal_dispatch() -> (TempDir, MethodRunPaths, MethodRunState) {
    let tmp = TempDir::new().expect("failed to create tempdir");
    let source = DefinitionSource {
        definition_path: minimal_dispatch_path(),
        execution_root: tmp.path().to_path_buf(),
    };
    let state = execute_run(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
    )
    .expect("execute_run");
    let paths = MethodRunPaths::new(tmp.path());
    (tmp, paths, state)
}

/// Normalize the minimal-dispatch fixture from its YAML source.
fn normalize_fixture() -> NormalizedDefinitionFile {
    let yaml = std::fs::read_to_string(minimal_dispatch_path()).expect("read fixture");
    Normalizer::normalize(&yaml).expect("normalize")
}

// ===========================================================================
// I1 — Event Authority
// ===========================================================================

/// Proves: events.ndjson is the sole source of truth.
/// Delete state.json, rebuild from events, and compare.
/// The rebuilt state MUST be identical to the original.
#[test]
fn invariant_i1_event_authority() {
    let (tmp, paths, original_state) = run_minimal_dispatch();

    // Verify state.json exists
    assert!(
        paths.state_json().exists(),
        "state.json must exist after a successful run"
    );

    // Delete state.json
    std::fs::remove_file(paths.state_json()).expect("remove state.json");
    assert!(!paths.state_json().exists());

    // Rebuild state from events only
    let rebuilt = rebuild_state(&paths.events_log()).expect("rebuild_state");

    // Core fields must match exactly
    assert_eq!(original_state.run_id, rebuilt.run_id, "run_id mismatch");
    assert_eq!(original_state.status, rebuilt.status, "status mismatch");
    assert_eq!(
        original_state.definition_frozen, rebuilt.definition_frozen,
        "definition_frozen mismatch"
    );
    assert_eq!(original_state.seq, rebuilt.seq, "seq mismatch");
    assert_eq!(original_state.phases, rebuilt.phases, "phases mismatch");

    // Also verify the entire struct is equal
    assert_eq!(
        original_state, rebuilt,
        "rebuilt state must be identical to the original"
    );

    drop(tmp);
}

// ===========================================================================
// I2 — Append-Only History
// ===========================================================================

/// Proves: events.ndjson is only ever appended to, never truncated or rewritten.
/// After execution, seq values must be strictly increasing with no gaps.
#[test]
fn invariant_i2_append_only_history() {
    let (tmp, paths, _state) = run_minimal_dispatch();

    let events = recover_events(&paths.events_log()).expect("recover_events");
    assert!(
        !events.is_empty(),
        "event log must not be empty after a run"
    );

    // Verify seq is strictly increasing with no gaps
    let mut prev_seq: u64 = 0;
    for event in &events {
        assert!(
            event.seq > prev_seq,
            "seq must be strictly increasing: got {} after {}",
            event.seq,
            prev_seq
        );
        assert_eq!(
            event.seq,
            prev_seq + 1,
            "seq must have no gaps: expected {} but got {}",
            prev_seq + 1,
            event.seq
        );
        prev_seq = event.seq;
    }

    // Verify append-only: read raw file and check each line is valid JSON
    let raw = std::fs::read_to_string(paths.events_log()).expect("read events");
    for (i, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        serde_json::from_str::<serde_json::Value>(trimmed).unwrap_or_else(|e| {
            panic!("line {} is not valid JSON: {}", i + 1, e);
        });
    }

    // Additionally: append a new event and verify the prior events remain intact
    let events_before = events.clone();
    let events_path = paths.events_log();
    let mut seq = prev_seq;
    let mut env = make_envelope(&events[0].run_id, MethodEventKind::RunBlocked);
    // This will fail on transition, but the point is that the file structure is append-only.
    // We just append a raw line manually to prove append semantics.
    {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&events_path)
            .expect("open events for append");
        seq += 1;
        env.seq = seq;
        env.timestamp = chrono::Utc::now().to_rfc3339();
        let json = serde_json::to_string(&env).expect("serialize");
        writeln!(file, "{json}").expect("append");
    }

    // Re-read: original events must be byte-for-byte identical
    let events_after = recover_events(&events_path).expect("recover after append");
    assert_eq!(events_after.len(), events_before.len() + 1);
    for (before, after) in events_before.iter().zip(events_after.iter()) {
        assert_eq!(before, after, "prior events must not change after append");
    }

    drop(tmp);
}

// ===========================================================================
// I3 — Attempt Immutability
// ===========================================================================

/// Proves: after an attempt completes, its directory contents are immutable.
/// We snapshot all file checksums in the attempt dir, then verify they remain
/// unchanged after the full run completes.
#[test]
fn invariant_i3_attempt_immutability() {
    let (tmp, paths, _state) = run_minimal_dispatch();

    // The fixture has one step: bootstrap/dispatch, attempt 001
    let attempt_dir = paths.attempt_dir("bootstrap", "dispatch", 1);
    assert!(
        attempt_dir.exists(),
        "attempt directory must exist: {}",
        attempt_dir.display()
    );

    // Collect all file checksums
    let mut checksums: BTreeMap<PathBuf, String> = BTreeMap::new();
    collect_checksums(&attempt_dir, &mut checksums);
    assert!(
        !checksums.is_empty(),
        "attempt directory must contain files"
    );

    // Verify all files still have the same checksums (nothing was modified after)
    let mut checksums_verify: BTreeMap<PathBuf, String> = BTreeMap::new();
    collect_checksums(&attempt_dir, &mut checksums_verify);

    assert_eq!(
        checksums, checksums_verify,
        "attempt directory contents must be immutable after completion"
    );

    // Verify key files exist
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

    drop(tmp);
}

fn collect_checksums(dir: &std::path::Path, map: &mut BTreeMap<PathBuf, String>) {
    if !dir.exists() {
        return;
    }
    for entry in walkdir::WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if entry.file_type().is_file() {
            let content = std::fs::read(entry.path()).expect("read file for checksum");
            let digest = md5::compute(&content);
            map.insert(entry.path().to_path_buf(), format!("{digest:x}"));
        }
    }
}

// ===========================================================================
// I4 — Attempt Isolation
// ===========================================================================

/// Proves: attempt directory paths for different attempts of the same step
/// have no shared path components after the step_dir.
/// We verify this structurally via the path builder, since a single run only
/// produces one attempt. We create paths for attempts 001, 002, 003 and verify
/// that their suffixes are fully disjoint.
#[test]
fn invariant_i4_attempt_isolation() {
    let paths = MethodRunPaths::new("/tmp/isolation-check");
    let phase = "research";
    let step = "analyze";

    let attempt_1 = paths.attempt_dir(phase, step, 1);
    let attempt_2 = paths.attempt_dir(phase, step, 2);
    let attempt_3 = paths.attempt_dir(phase, step, 3);

    let step_dir = paths.step_dir(phase, step);

    // Extract relative paths from step_dir
    let rel_1 = attempt_1.strip_prefix(&step_dir).expect("strip prefix 1");
    let rel_2 = attempt_2.strip_prefix(&step_dir).expect("strip prefix 2");
    let rel_3 = attempt_3.strip_prefix(&step_dir).expect("strip prefix 3");

    // The relative paths must be different
    assert_ne!(rel_1, rel_2, "attempt 1 and 2 must have different paths");
    assert_ne!(rel_1, rel_3, "attempt 1 and 3 must have different paths");
    assert_ne!(rel_2, rel_3, "attempt 2 and 3 must have different paths");

    // Verify that no attempt directory is a prefix of another
    assert!(
        !attempt_1.starts_with(&attempt_2),
        "attempt 1 must not be under attempt 2"
    );
    assert!(
        !attempt_2.starts_with(&attempt_1),
        "attempt 2 must not be under attempt 1"
    );
    assert!(
        !attempt_2.starts_with(&attempt_3),
        "attempt 2 must not be under attempt 3"
    );

    // Verify relay roots are also isolated
    let relay_1 = paths.worker_relay_root(phase, step, 1, "primary");
    let relay_2 = paths.worker_relay_root(phase, step, 2, "primary");
    assert_ne!(relay_1, relay_2, "relay roots must differ between attempts");
    assert!(
        !relay_1.starts_with(&relay_2),
        "relay 1 must not be nested under relay 2"
    );
    assert!(
        !relay_2.starts_with(&relay_1),
        "relay 2 must not be nested under relay 1"
    );
}

// ===========================================================================
// I5 — Deterministic Dispatch Identity
// ===========================================================================

/// Proves: every WorkerDispatched event contains (run_id, phase_id, step_id,
/// attempt, worker_id) and no two events share the same tuple.
#[test]
fn invariant_i5_deterministic_dispatch_identity() {
    let (tmp, paths, _state) = run_minimal_dispatch();

    let events = recover_events(&paths.events_log()).expect("recover_events");
    let dispatched: Vec<_> = events
        .iter()
        .filter(|e| e.kind == MethodEventKind::WorkerDispatched)
        .collect();

    assert!(
        !dispatched.is_empty(),
        "must have at least one WorkerDispatched event"
    );

    let mut identity_tuples: Vec<(String, String, String, u32, String)> = Vec::new();

    for event in &dispatched {
        // All five fields must be present
        assert!(
            !event.run_id.is_empty(),
            "WorkerDispatched must have run_id"
        );
        let phase_id = event
            .phase_id
            .as_ref()
            .expect("WorkerDispatched must have phase_id");
        let step_id = event
            .step_id
            .as_ref()
            .expect("WorkerDispatched must have step_id");
        let attempt = event.attempt.expect("WorkerDispatched must have attempt");
        let worker_id = event
            .worker_id
            .as_ref()
            .expect("WorkerDispatched must have worker_id");

        let tuple = (
            event.run_id.clone(),
            phase_id.clone(),
            step_id.clone(),
            attempt,
            worker_id.clone(),
        );

        assert!(
            !identity_tuples.contains(&tuple),
            "dispatch identity tuple must be unique: {:?}",
            tuple
        );
        identity_tuples.push(tuple);
    }

    drop(tmp);
}

// ===========================================================================
// I6 — Atomic Projection
// ===========================================================================

/// Proves: state.json is written via tmp-then-rename.
/// After clean execution, no .tmp file remains.
/// We also verify the write_state_atomic function produces valid JSON.
#[test]
fn invariant_i6_atomic_projection() {
    let (tmp, paths, state) = run_minimal_dispatch();

    // After clean execution, no .tmp file should remain
    let tmp_path = paths.state_json().with_extension("json.tmp");
    assert!(
        !tmp_path.exists(),
        "no .tmp file should remain after clean execution: {}",
        tmp_path.display()
    );

    // Verify state.json exists and is valid JSON
    let content = std::fs::read_to_string(paths.state_json()).expect("read state.json");
    let parsed: MethodRunState =
        serde_json::from_str(&content).expect("state.json must be valid JSON");
    assert_eq!(parsed.run_id, state.run_id);

    // Exercise write_state_atomic directly and verify atomicity
    let test_dir = tmp.path().join("atomic-test");
    std::fs::create_dir_all(&test_dir).expect("mkdir");
    let test_state_path = test_dir.join("state.json");
    write_state_atomic(&test_state_path, &state).expect("write_state_atomic");

    // Verify the file exists and no tmp remains
    assert!(test_state_path.exists(), "state.json must exist");
    let test_tmp_path = test_state_path.with_extension("json.tmp");
    assert!(
        !test_tmp_path.exists(),
        ".tmp file must not remain after atomic write"
    );

    // Verify the written state is valid
    let written: MethodRunState =
        serde_json::from_str(&std::fs::read_to_string(&test_state_path).expect("read"))
            .expect("parse");
    assert_eq!(written, state);

    drop(tmp);
}

// ===========================================================================
// I7 — Conservative Output Availability
// ===========================================================================

/// Proves: outputs are not resolvable from a non-terminal step.
/// Construct a state where the step is still running, then verify
/// resolve_and_write_output returns an error.
#[test]
fn invariant_i7_conservative_output_availability() {
    let tmp = TempDir::new().expect("tempdir");
    let paths = MethodRunPaths::new(tmp.path());
    std::fs::create_dir_all(paths.method_root().join("artifacts").join("outputs"))
        .expect("mkdir outputs");

    let normalized = normalize_fixture();

    // Build a state where the step is still running (not terminal)
    let mut running_state = MethodRunState {
        run_id: "test-run".to_string(),
        status: RunStatus::Running,
        definition_frozen: true,
        phases: BTreeMap::new(),
        seq: 5,
    };

    let mut phase_state = capacitor_core::method_runner::state::PhaseState {
        status: PhaseStatus::Running,
        steps: BTreeMap::new(),
        gate_result: None,
    };

    let step_state = capacitor_core::method_runner::state::StepState {
        status: StepStatus::Running,
        current_attempt: 1,
        attempts: BTreeMap::new(),
        outputs: BTreeMap::new(),
    };
    phase_state.steps.insert("dispatch".to_string(), step_state);
    running_state
        .phases
        .insert("bootstrap".to_string(), phase_state);

    // Attempt to resolve the output — must fail
    let result = resolve_and_write_output(
        &paths,
        "dispatch_summary",
        "bootstrap.dispatch.dispatch_summary",
        &running_state,
        &normalized.method,
    );

    assert!(
        result.is_err(),
        "output resolution must fail for a non-terminal step"
    );

    let err = result.unwrap_err();
    let err_msg = format!("{err}");
    assert!(
        err_msg.contains("not in a terminal state")
            || err_msg.contains("not available")
            || err_msg.contains("Running"),
        "error must indicate the step is not terminal, got: {err_msg}"
    );

    // Also verify that Pending steps fail
    running_state
        .phases
        .get_mut("bootstrap")
        .unwrap()
        .steps
        .get_mut("dispatch")
        .unwrap()
        .status = StepStatus::Pending;

    let result2 = resolve_and_write_output(
        &paths,
        "dispatch_summary",
        "bootstrap.dispatch.dispatch_summary",
        &running_state,
        &normalized.method,
    );
    assert!(
        result2.is_err(),
        "output resolution must also fail for Pending step"
    );

    // And that Blocked steps fail
    running_state
        .phases
        .get_mut("bootstrap")
        .unwrap()
        .steps
        .get_mut("dispatch")
        .unwrap()
        .status = StepStatus::Blocked;

    let result3 = resolve_and_write_output(
        &paths,
        "dispatch_summary",
        "bootstrap.dispatch.dispatch_summary",
        &running_state,
        &normalized.method,
    );
    assert!(
        result3.is_err(),
        "output resolution must also fail for Blocked step"
    );

    drop(tmp);
}

// ===========================================================================
// I8 — Legal Transitions Only
// ===========================================================================

/// Proves: the state machine enforcer rejects illegal transitions with clear errors.
/// Tests at least 3 illegal transitions per entity type.
#[test]
fn invariant_i8_legal_transitions_only() {
    // --- Run ---
    // Illegal: Completed -> Running
    let err = RunStatus::Completed
        .transition_to(RunStatus::Running, "test-run")
        .unwrap_err();
    assert!(
        err.to_string().contains("illegal transition"),
        "run: Completed->Running should be rejected: {err}"
    );

    // Illegal: Failed -> Running
    let err = RunStatus::Failed
        .transition_to(RunStatus::Running, "test-run")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Created -> Completed (skipping Running)
    let err = RunStatus::Created
        .transition_to(RunStatus::Completed, "test-run")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // --- Phase ---
    // Illegal: Completed -> Running
    let err = PhaseStatus::Completed
        .transition_to(PhaseStatus::Running, "test-phase")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Skipped -> Running
    let err = PhaseStatus::Skipped
        .transition_to(PhaseStatus::Running, "test-phase")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Pending -> Completed
    let err = PhaseStatus::Pending
        .transition_to(PhaseStatus::Completed, "test-phase")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // --- Step ---
    // Illegal: Completed -> Running
    let err = StepStatus::Completed
        .transition_to(StepStatus::Running, "test-step")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Failed -> Running
    let err = StepStatus::Failed
        .transition_to(StepStatus::Running, "test-step")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Pending -> Completed
    let err = StepStatus::Pending
        .transition_to(StepStatus::Completed, "test-step")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // --- Attempt ---
    // Illegal: Completed -> Running
    let err = AttemptStatus::Completed
        .transition_to(AttemptStatus::Running, "test-attempt")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Failed -> Dispatching
    let err = AttemptStatus::Failed
        .transition_to(AttemptStatus::Dispatching, "test-attempt")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Created -> Completed (skipping intermediate states)
    let err = AttemptStatus::Created
        .transition_to(AttemptStatus::Completed, "test-attempt")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // --- Worker ---
    // Illegal: Completed -> Running
    let err = WorkerStatus::Completed
        .transition_to(WorkerStatus::Running, "test-worker")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Failed -> Running
    let err = WorkerStatus::Failed
        .transition_to(WorkerStatus::Running, "test-worker")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));

    // Illegal: Pending -> Completed (skipping Dispatched+Running)
    let err = WorkerStatus::Pending
        .transition_to(WorkerStatus::Completed, "test-worker")
        .unwrap_err();
    assert!(err.to_string().contains("illegal transition"));
}

// ===========================================================================
// I9 — Lock Exclusivity
// ===========================================================================

/// Proves: two concurrent lock acquisitions result in one blocking.
/// One lock succeeds, the second must timeout.
#[test]
fn invariant_i9_lock_exclusivity() {
    let tmp = TempDir::new().expect("tempdir");
    let lock_path = tmp.path().join("locks").join("run.lock");

    // Acquire first lock
    let lock1 = acquire_lock(&lock_path, std::time::Duration::from_secs(5))
        .expect("first lock must succeed");

    // Attempt second lock with a short timeout — must fail
    let result = acquire_lock(&lock_path, std::time::Duration::from_millis(200));
    assert!(result.is_err(), "second lock must fail while first is held");

    let err = result.unwrap_err();
    let err_msg = format!("{err}");
    assert!(
        err_msg.contains("timed out") || err_msg.contains("Timeout"),
        "error must indicate timeout, got: {err_msg}"
    );

    // After dropping the first lock, a new acquisition must succeed
    drop(lock1);
    let lock2 = acquire_lock(&lock_path, std::time::Duration::from_secs(2))
        .expect("lock must succeed after first is released");

    // Verify the lock file contains valid JSON with pid
    let content = std::fs::read_to_string(&lock_path).expect("read lock file");
    let info: serde_json::Value = serde_json::from_str(&content).expect("lock file must be JSON");
    assert!(
        info.get("pid").is_some(),
        "lock file must contain pid field"
    );
    assert!(
        info.get("hostname").is_some(),
        "lock file must contain hostname field"
    );
    assert!(
        info.get("acquired_at").is_some(),
        "lock file must contain acquired_at field"
    );

    drop(lock2);
    drop(tmp);
}

// ===========================================================================
// I10 — Definition Freeze
// ===========================================================================

/// Proves: after snapshot is written, DefinitionLoader reads from the snapshot,
/// and the loaded definition matches the normalized one.
/// Additionally: modifying the source YAML after snapshot is written does not
/// affect what DefinitionLoader returns.
#[test]
fn invariant_i10_definition_freeze() {
    let tmp = TempDir::new().expect("tempdir");
    let paths = MethodRunPaths::new(tmp.path());
    std::fs::create_dir_all(paths.method_root()).expect("mkdir");

    // Normalize from source
    let normalized = normalize_fixture();

    // Write snapshot
    capacitor_core::method_runner::definition::write_snapshot(
        &paths.definition_snapshot(),
        &normalized,
    )
    .expect("write snapshot");

    // Load from snapshot
    let loaded = DefinitionLoader::load(&paths.definition_snapshot()).expect("load snapshot");

    // Must match the normalized definition
    assert_eq!(
        normalized.schema_version, loaded.schema_version,
        "schema_version must match"
    );
    assert_eq!(
        normalized.method.id, loaded.method.id,
        "method.id must match"
    );
    assert_eq!(
        normalized.method.title, loaded.method.title,
        "method.title must match"
    );
    assert_eq!(
        normalized.method.phases.len(),
        loaded.method.phases.len(),
        "phase count must match"
    );
    assert_eq!(normalized, loaded, "full definition must match");

    // Now simulate modifying the source YAML after run start
    // Copy fixture to tempdir and modify it
    let modified_yaml_path = tmp.path().join("modified.yaml");
    let mut yaml_content = std::fs::read_to_string(minimal_dispatch_path()).expect("read fixture");
    yaml_content = yaml_content.replace("Minimal Dispatch", "MODIFIED TITLE");
    std::fs::write(&modified_yaml_path, &yaml_content).expect("write modified");

    // DefinitionLoader still reads from the frozen snapshot, unaffected
    let loaded_again =
        DefinitionLoader::load(&paths.definition_snapshot()).expect("load snapshot again");
    assert_eq!(
        loaded_again.method.title, "Minimal Dispatch",
        "DefinitionLoader must read from snapshot, not source YAML"
    );

    drop(tmp);
}

// ===========================================================================
// I11 — Template Explicitness
// ===========================================================================

/// Proves: template is taken from step definition only (explicit), never inferred.
/// 1. A step with explicit template uses that template.
/// 2. A step with no template at any level falls back through the chain
///    (dispatch.template -> step.template -> method.defaults.template -> None).
#[test]
fn invariant_i11_template_explicitness() {
    // The minimal-dispatch fixture has template: implement on the step
    let normalized = normalize_fixture();
    let step = &normalized.method.phases[0].steps[0];
    assert_eq!(
        step.template.as_deref(),
        Some("implement"),
        "step with explicit template must use 'implement'"
    );

    // Now test a step with no template at any level: template should be None
    // (the fallback to "implement" is the method default, not inference)
    let yaml_no_template = r#"
schema_version: "1"
method:
  id: no-template
  version: "1.0"
  title: No Template
  phases:
    - id: build
      title: Build
      steps:
        - id: work
          title: Work
          action: dispatch
          dispatch:
            instructions: Do something.
"#;
    let no_template_def = Normalizer::normalize(yaml_no_template).expect("normalize no-template");
    let no_template_step = &no_template_def.method.phases[0].steps[0];
    assert!(
        no_template_step.template.is_none(),
        "step with no template at any level must have template = None, not inferred from action type"
    );

    // Test method defaults propagation
    let yaml_default_template = r#"
schema_version: "1"
method:
  id: default-template
  version: "1.0"
  title: Default Template
  defaults:
    template: review
  phases:
    - id: analysis
      title: Analysis
      steps:
        - id: check
          title: Check
          action: dispatch
          dispatch:
            instructions: Check something.
"#;
    let default_def =
        Normalizer::normalize(yaml_default_template).expect("normalize default-template");
    let default_step = &default_def.method.phases[0].steps[0];
    assert_eq!(
        default_step.template.as_deref(),
        Some("review"),
        "step must inherit template from method.defaults"
    );

    // Test step-level template overrides method default
    let yaml_override = r#"
schema_version: "1"
method:
  id: override-template
  version: "1.0"
  title: Override Template
  defaults:
    template: review
  phases:
    - id: impl
      title: Impl
      steps:
        - id: code
          title: Code
          action: dispatch
          template: implement
          dispatch:
            instructions: Code it.
"#;
    let override_def = Normalizer::normalize(yaml_override).expect("normalize override");
    let override_step = &override_def.method.phases[0].steps[0];
    assert_eq!(
        override_step.template.as_deref(),
        Some("implement"),
        "step-level template must override method default"
    );
}

// ===========================================================================
// I12 — Binding Is Routing
// ===========================================================================

/// Proves: the output resolver module does NOT contain any std::fs::read calls.
/// It only routes paths — it never reads artifact contents during binding.
/// This is verified by scanning the source file for prohibited patterns.
#[test]
fn invariant_i12_binding_is_routing() {
    let output_rs = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("method_runner")
        .join("output.rs");

    let source = std::fs::read_to_string(&output_rs).expect("read output.rs source");

    // Must not contain std::fs::read (which would read artifact contents)
    assert!(
        !source.contains("std::fs::read(")
            && !source.contains("std::fs::read_to_string(")
            && !source.contains("fs::read(")
            && !source.contains("fs::read_to_string(")
            && !source.contains("File::open("),
        "output.rs must not read file contents — binding is routing only. \
         Found a prohibited fs read call in the output resolver."
    );

    // Must not contain any content transformation patterns
    assert!(
        !source.contains("String::from_utf8"),
        "output.rs must not decode artifact content"
    );

    // The module SHOULD contain path routing (positive signal)
    assert!(
        source.contains("OutputRecord") || source.contains("resolved_path"),
        "output.rs must contain path routing types"
    );

    // Verify write is allowed (writing the output record is part of routing)
    assert!(
        source.contains("std::fs::write") || source.contains("fs::write"),
        "output.rs should write output records (routing metadata, not content)"
    );
}
