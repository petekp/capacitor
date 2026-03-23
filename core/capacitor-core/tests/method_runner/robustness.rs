//! Filesystem robustness and concurrency safety tests for the method runner.
//!
//! Covers: lock protocol, event persistence, atomic state writes,
//! and end-to-end filesystem layout verification.

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::{DefinitionLoader, DefinitionSource, Normalizer};
use capacitor_core::method_runner::events::{
    append_event, make_envelope, recover_events, MethodEventEnvelope, MethodEventKind,
};
use capacitor_core::method_runner::executor::execute_run;
use capacitor_core::method_runner::state::{write_state_atomic, MethodRunState, RunStatus};
use capacitor_core::method_runner::storage::{acquire_lock, LockInfo, MethodRunPaths};

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../methods/fixtures/minimal-dispatch.yaml")
}

// =========================================================================
// Lock protocol tests
// =========================================================================

#[test]
fn robustness_lock_acquire_and_release() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Acquire lock — file must exist while held
    {
        let _lock = acquire_lock(&lock_path, Duration::from_secs(1)).unwrap();
        assert!(lock_path.exists(), "lock file should exist while held");
    }

    // After drop — file must be removed
    assert!(
        !lock_path.exists(),
        "lock file should be removed after drop"
    );
}

#[test]
fn robustness_lock_stale_pid_detection() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Create parent dirs and write a lock file with a PID that is (almost certainly) dead
    std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
    let stale_info = LockInfo {
        pid: 99999,
        start_time: 1,
        hostname: "test-host".to_string(),
        acquired_at: "2020-01-01T00:00:00Z".to_string(),
    };
    let json = serde_json::to_string_pretty(&stale_info).unwrap();
    std::fs::write(&lock_path, json).unwrap();

    // acquire_lock should detect the stale PID and succeed
    let lock = acquire_lock(&lock_path, Duration::from_secs(1));
    assert!(lock.is_ok(), "should acquire lock over stale PID 99999");
}

#[test]
fn robustness_lock_invalid_json() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Write corrupt data to the lock file
    std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
    std::fs::write(&lock_path, "NOT VALID JSON {{{").unwrap();

    // Should succeed — corrupt lock files are treated as stale and overwritten
    let lock = acquire_lock(&lock_path, Duration::from_secs(1));
    assert!(
        lock.is_ok(),
        "should acquire lock when existing file contains corrupt JSON"
    );
}

#[test]
fn robustness_lock_empty_file() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Write an empty file at the lock path
    std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
    std::fs::write(&lock_path, "").unwrap();

    // Should succeed — empty file is invalid JSON, treated as stale
    let lock = acquire_lock(&lock_path, Duration::from_secs(1));
    assert!(
        lock.is_ok(),
        "should acquire lock when existing file is empty"
    );
}

#[test]
fn robustness_lock_missing_directory() {
    let tmp = tempfile::TempDir::new().unwrap();
    // Point to a lock path whose parent directory does not exist
    let lock_path = tmp.path().join("nonexistent").join("deep").join("run.lock");
    assert!(
        !lock_path.parent().unwrap().exists(),
        "parent dir should not exist before acquire"
    );

    let lock = acquire_lock(&lock_path, Duration::from_secs(1));
    assert!(
        lock.is_ok(),
        "acquire_lock should create missing parent directories"
    );
    assert!(lock_path.exists(), "lock file should exist after acquire");
}

#[test]
fn robustness_lock_rapid_acquire_release() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Acquire and release 50 times in quick succession — no fd leaks
    for i in 0..50 {
        let lock = acquire_lock(&lock_path, Duration::from_secs(1));
        assert!(
            lock.is_ok(),
            "iteration {i}: acquire should succeed after prior release"
        );
        // lock dropped here
    }
    assert!(
        !lock_path.exists(),
        "lock file should be gone after final drop"
    );
}

#[test]
fn robustness_lock_timeout() {
    let tmp = tempfile::TempDir::new().unwrap();
    let paths = MethodRunPaths::new(tmp.path());
    let lock_path = paths.lock_file();

    // Hold the first lock so the second attempt cannot succeed
    let _held = acquire_lock(&lock_path, Duration::from_secs(1)).unwrap();

    // Second acquisition with a short timeout should fail with Timeout
    let result = acquire_lock(&lock_path, Duration::from_millis(100));
    assert!(result.is_err(), "second acquire should fail");
    let err_msg = format!("{}", result.unwrap_err());
    assert!(
        err_msg.contains("timed out"),
        "error should indicate timeout, got: {err_msg}"
    );
}

// =========================================================================
// Event persistence tests
// =========================================================================

#[test]
fn robustness_append_100_events() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("events.ndjson");
    let run_id = "test-run-100";
    let mut seq: u64 = 0;

    for _ in 0..100 {
        let mut env = make_envelope(run_id, MethodEventKind::GateEvaluated);
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    assert_eq!(seq, 100, "final seq should be 100");

    // Verify file is well-formed ndjson: each line parses independently
    let content = std::fs::read_to_string(&events_path).unwrap();
    let lines: Vec<&str> = content.lines().collect();
    assert_eq!(lines.len(), 100, "should have exactly 100 lines");
    for (i, line) in lines.iter().enumerate() {
        let envelope: MethodEventEnvelope =
            serde_json::from_str(line).unwrap_or_else(|e| panic!("line {i} invalid JSON: {e}"));
        assert_eq!(envelope.seq, (i as u64) + 1, "seq mismatch at line {i}");
    }
}

#[test]
fn robustness_events_with_unicode() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("events.ndjson");
    let run_id = "unicode-run";
    let mut seq: u64 = 0;

    let payloads = [
        serde_json::json!({"msg": "Hello, world!"}),
        serde_json::json!({"msg": "Emoji: \u{1F680}\u{1F30D}\u{2728}"}),
        serde_json::json!({"msg": "\u{4f60}\u{597d}\u{4e16}\u{754c}"}),
        serde_json::json!({"msg": "Accents: \u{00e9}\u{00e8}\u{00ea}\u{00eb}"}),
        serde_json::json!({"msg": "Cyrillic: \u{041f}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"}),
    ];

    for payload in &payloads {
        let mut env = make_envelope(run_id, MethodEventKind::GateEvaluated);
        env.payload = payload.clone();
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    // Recover and verify round-trip preserves unicode
    let recovered = recover_events(&events_path).unwrap();
    assert_eq!(recovered.len(), payloads.len());
    for (i, event) in recovered.iter().enumerate() {
        assert_eq!(
            event.payload, payloads[i],
            "unicode payload {i} should round-trip cleanly"
        );
    }
}

#[test]
fn robustness_torn_tail_recovery() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("events.ndjson");
    let run_id = "torn-tail-run";
    let mut seq: u64 = 0;

    // Write 5 valid events
    for _ in 0..5 {
        let mut env = make_envelope(run_id, MethodEventKind::GateEvaluated);
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    // Append a truncated (invalid) last line
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&events_path)
        .unwrap();
    write!(file, r#"{{"seq":6,"truncated"#).unwrap();
    drop(file);

    // recover_events should return the 5 valid events and truncate
    let recovered = recover_events(&events_path).unwrap();
    assert_eq!(
        recovered.len(),
        5,
        "should recover exactly 5 valid events, skipping torn tail"
    );

    // File should now be truncated to only the 5 valid lines
    let content = std::fs::read_to_string(&events_path).unwrap();
    let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(
        lines.len(),
        5,
        "file should contain exactly 5 lines after truncation"
    );
}

#[test]
fn robustness_torn_tail_empty_last_line() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("events.ndjson");
    let run_id = "trailing-empty-run";
    let mut seq: u64 = 0;

    // Write 3 valid events
    for _ in 0..3 {
        let mut env = make_envelope(run_id, MethodEventKind::GateEvaluated);
        append_event(&events_path, &mut env, &mut seq).unwrap();
    }

    // Append empty trailing lines
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&events_path)
        .unwrap();
    writeln!(file).unwrap();
    writeln!(file).unwrap();
    writeln!(file, "   ").unwrap();
    drop(file);

    // Empty trailing lines should be ignored
    let recovered = recover_events(&events_path).unwrap();
    assert_eq!(recovered.len(), 3, "empty trailing lines should be ignored");
}

#[test]
fn robustness_empty_events_file() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("events.ndjson");

    // Create an empty file
    std::fs::write(&events_path, "").unwrap();

    let recovered = recover_events(&events_path).unwrap();
    assert!(recovered.is_empty(), "empty file should produce empty vec");
}

#[test]
fn robustness_missing_events_file() {
    let tmp = tempfile::TempDir::new().unwrap();
    let events_path = tmp.path().join("does-not-exist.ndjson");

    assert!(!events_path.exists());
    let recovered = recover_events(&events_path).unwrap();
    assert!(
        recovered.is_empty(),
        "missing file should produce empty vec"
    );
}

// =========================================================================
// Atomic state write tests
// =========================================================================

#[test]
fn robustness_atomic_state_write() {
    let tmp = tempfile::TempDir::new().unwrap();
    let state_path = tmp.path().join("state.json");
    let tmp_path = state_path.with_extension("json.tmp");

    let state = MethodRunState {
        run_id: "atomic-test-run".to_string(),
        status: RunStatus::Running,
        definition_frozen: true,
        phases: std::collections::BTreeMap::new(),
        seq: 5,
    };

    write_state_atomic(&state_path, &state).unwrap();

    // state.json should exist
    assert!(state_path.exists(), "state.json should exist after write");

    // .tmp file should NOT remain
    assert!(
        !tmp_path.exists(),
        "state.json.tmp should not remain after atomic rename"
    );
}

#[test]
fn robustness_state_file_is_valid_json() {
    let tmp = tempfile::TempDir::new().unwrap();
    let state_path = tmp.path().join("state.json");

    let state = MethodRunState {
        run_id: "json-round-trip".to_string(),
        status: RunStatus::Completed,
        definition_frozen: true,
        phases: std::collections::BTreeMap::new(),
        seq: 42,
    };

    write_state_atomic(&state_path, &state).unwrap();

    // Read back and deserialize
    let content = std::fs::read_to_string(&state_path).unwrap();
    let deserialized: MethodRunState =
        serde_json::from_str(&content).expect("state file should be valid JSON");

    assert_eq!(deserialized.run_id, "json-round-trip");
    assert_eq!(deserialized.status, RunStatus::Completed);
    assert!(deserialized.definition_frozen);
    assert_eq!(deserialized.seq, 42);
}

// =========================================================================
// End-to-end filesystem tests
// =========================================================================

#[test]
fn robustness_method_tree_structure() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: fixture_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;

    let state = execute_run(
        &source,
        &prompt_builder,
        &dispatcher,
        &FakeInteractiveIO {
            response: "approved".to_string(),
        },
    )
    .unwrap();
    assert_eq!(state.status, RunStatus::Completed);

    let paths = MethodRunPaths::new(tmp.path());

    // Verify canonical directory/file structure
    assert!(paths.method_root().exists(), ".method/ should exist");
    assert!(
        paths.definition_snapshot().exists(),
        "definition.snapshot.yaml should exist"
    );
    assert!(paths.events_log().exists(), "events.ndjson should exist");
    assert!(paths.state_json().exists(), "state.json should exist");
    assert!(
        paths.method_root().join("steps").exists(),
        ".method/steps/ should exist"
    );
    assert!(
        paths.method_root().join("locks").exists(),
        ".method/locks/ should exist"
    );
    assert!(
        paths
            .method_root()
            .join("artifacts")
            .join("handoffs")
            .exists(),
        ".method/artifacts/handoffs/ should exist"
    );
    assert!(
        paths
            .method_root()
            .join("artifacts")
            .join("outputs")
            .exists(),
        ".method/artifacts/outputs/ should exist"
    );

    // Verify per-step structure (the fixture has bootstrap.dispatch)
    let step_dir = paths.step_dir("bootstrap", "dispatch");
    assert!(step_dir.exists(), "step dir should exist");
    assert!(
        step_dir.join("step.json").exists(),
        "step.json should exist"
    );

    // Verify attempt directory
    let attempt_dir = paths.attempt_dir("bootstrap", "dispatch", 1);
    assert!(attempt_dir.exists(), "attempt dir should exist");
    assert!(
        attempt_dir.join("attempt.json").exists(),
        "attempt.json should exist"
    );
    assert!(
        attempt_dir.join("input-bindings.json").exists(),
        "input-bindings.json should exist"
    );
    assert!(
        attempt_dir.join("output-bindings.json").exists(),
        "output-bindings.json should exist"
    );

    // Verify worker relay structure
    let relay_root = paths.worker_relay_root("bootstrap", "dispatch", 1, "primary");
    assert!(relay_root.exists(), "worker relay root should exist");
    assert!(
        relay_root.join("HANDOFF.md").exists(),
        "HANDOFF.md should exist in relay root"
    );
    assert!(
        relay_root.join("prompt-header.md").exists(),
        "prompt-header.md should exist in relay root"
    );
    assert!(
        relay_root.join("prompt.md").exists(),
        "prompt.md should exist in relay root"
    );
}

#[test]
fn robustness_clean_run_isolation() {
    let tmp_a = tempfile::TempDir::new().unwrap();
    let tmp_b = tempfile::TempDir::new().unwrap();

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;

    let source_a = DefinitionSource {
        definition_path: fixture_path(),
        execution_root: tmp_a.path().to_path_buf(),
    };
    let source_b = DefinitionSource {
        definition_path: fixture_path(),
        execution_root: tmp_b.path().to_path_buf(),
    };

    let fake_io = FakeInteractiveIO {
        response: "approved".to_string(),
    };
    let state_a = execute_run(&source_a, &prompt_builder, &dispatcher, &fake_io).unwrap();
    let state_b = execute_run(&source_b, &prompt_builder, &dispatcher, &fake_io).unwrap();

    // Run IDs must be different (ULIDs are unique)
    assert_ne!(
        state_a.run_id, state_b.run_id,
        "separate runs should produce different run_ids"
    );

    // Both completed
    assert_eq!(state_a.status, RunStatus::Completed);
    assert_eq!(state_b.status, RunStatus::Completed);

    // Events in A should only reference A's run_id
    let paths_a = MethodRunPaths::new(tmp_a.path());
    let events_a = recover_events(&paths_a.events_log()).unwrap();
    for event in &events_a {
        assert_eq!(
            event.run_id, state_a.run_id,
            "events in dir A should only reference run_id A"
        );
    }

    // Events in B should only reference B's run_id
    let paths_b = MethodRunPaths::new(tmp_b.path());
    let events_b = recover_events(&paths_b.events_log()).unwrap();
    for event in &events_b {
        assert_eq!(
            event.run_id, state_b.run_id,
            "events in dir B should only reference run_id B"
        );
    }
}

#[test]
fn robustness_definition_snapshot_is_valid_yaml() {
    let tmp = tempfile::TempDir::new().unwrap();
    let source = DefinitionSource {
        definition_path: fixture_path(),
        execution_root: tmp.path().to_path_buf(),
    };

    let prompt_builder = FakePromptBuilder;
    let dispatcher = FakeWorkerDispatcher;

    execute_run(
        &source,
        &prompt_builder,
        &dispatcher,
        &FakeInteractiveIO {
            response: "approved".to_string(),
        },
    )
    .unwrap();

    let paths = MethodRunPaths::new(tmp.path());
    let snapshot_path = paths.definition_snapshot();
    assert!(snapshot_path.exists(), "snapshot must exist after run");

    // Verify it's valid YAML that deserializes back into the normalized type
    let loaded = DefinitionLoader::load(&snapshot_path)
        .expect("definition.snapshot.yaml should parse as valid YAML");

    // Also verify against a fresh normalization of the source fixture
    let fixture_yaml = std::fs::read_to_string(fixture_path()).unwrap();
    let expected = Normalizer::normalize(&fixture_yaml).unwrap();

    assert_eq!(
        loaded.schema_version, expected.schema_version,
        "schema_version should match"
    );
    assert_eq!(
        loaded.method.id, expected.method.id,
        "method id should match"
    );
    assert_eq!(
        loaded.method.phases.len(),
        expected.method.phases.len(),
        "phase count should match"
    );
}
