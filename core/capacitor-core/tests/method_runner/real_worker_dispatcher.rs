//! Integration tests for CodexWorkerDispatcher (IF2): T9–T11, T15–T20, T30.
//!
//! Tests exercise the real worker dispatcher against `fake-codex.sh`.
//! Fake-codex behavior is controlled via env_overrides on AdapterConfig,
//! not process-level env vars, ensuring the allowlisted env is correct.

use std::path::PathBuf;
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{
    AdapterError, WorkerDispatchRequest, WorkerDispatcher,
};
use capacitor_core::method_runner::worker_dispatch_adapter::CodexWorkerDispatcher;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fake_codex_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../scripts/test/fake-codex.sh")
        .canonicalize()
        .expect("fake-codex.sh must exist")
}

fn make_config_with_overrides(
    project_root: &std::path::Path,
    env_overrides: Vec<(String, String)>,
) -> AdapterConfig {
    let script_path = project_root.join("dummy-compose.sh");
    std::fs::write(&script_path, "#!/bin/bash\necho ok\n").unwrap();

    AdapterConfig {
        script_path,
        codex_path: fake_codex_path(),
        project_root: project_root.to_path_buf(),
        default_timeout: Duration::from_secs(30),
        kill_grace_period: Duration::from_secs(2),
        codex_version: Some("fake 0.1.0".into()),
        env_overrides,
    }
}

/// Build fake-codex env overrides passed through the adapter's env.
fn fake_env(
    capture_dir: &std::path::Path,
    exit_code: i32,
    write_handoff: bool,
    write_last_message: bool,
) -> Vec<(String, String)> {
    vec![
        (
            "FAKE_CODEX_CAPTURE_DIR".into(),
            capture_dir.to_string_lossy().into_owned(),
        ),
        ("FAKE_CODEX_EXIT_CODE".into(), exit_code.to_string()),
        ("FAKE_CODEX_SLEEP_SECS".into(), "0".into()),
        (
            "FAKE_CODEX_WRITE_HANDOFF".into(),
            if write_handoff { "1" } else { "0" }.into(),
        ),
        (
            "FAKE_CODEX_WRITE_LAST_MESSAGE".into(),
            if write_last_message { "1" } else { "0" }.into(),
        ),
    ]
}

fn setup(
    project_root: &std::path::Path,
    relay_root: PathBuf,
    prompt_content: &str,
    overrides: Vec<(String, String)>,
) -> (CodexWorkerDispatcher, WorkerDispatchRequest) {
    let config = make_config_with_overrides(project_root, overrides);
    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let prompt_path = relay_root.join("prompt.md");
    std::fs::write(&prompt_path, prompt_content).unwrap();

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root,
        prompt_path,
    };

    (dispatcher, request)
}

// =========================================================================
// T9: Happy path exit 0
// =========================================================================

#[test]
fn t9_happy_path_exit_zero() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);

    let (dispatcher, request) = setup(
        tmp.path(),
        relay_root.clone(),
        "Build the thing.",
        overrides,
    );
    let result = dispatcher.dispatch(&request).unwrap();

    assert_eq!(result.exit_code, 0, "should exit 0");
    assert_eq!(result.signal, None, "no signal on clean exit");
    assert_eq!(result.worker_id, "w1");
    assert!(
        relay_root.join("last-message.txt").exists(),
        "last-message.txt should exist on clean exit"
    );
}

// =========================================================================
// T10: Non-zero worker exit → Ok(result), not AdapterError
// =========================================================================

#[test]
fn t10_nonzero_exit_is_ok_result_not_error() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 1, true, false);

    let (dispatcher, request) = setup(tmp.path(), relay_root, "Build the thing.", overrides);
    let result = dispatcher.dispatch(&request);

    assert!(
        result.is_ok(),
        "non-zero exit should be Ok(result), got: {:?}",
        result.err()
    );
    let result = result.unwrap();
    assert_eq!(result.exit_code, 1, "exit code should be 1");
}

// =========================================================================
// T11: Dispatch-time spawn failure after successful preflight
// =========================================================================

#[test]
fn t11_spawn_failure_after_preflight() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");

    // Create a config with a codex path that exists at construction time
    let codex_path = tmp.path().join("codex-will-vanish");
    std::fs::write(&codex_path, "#!/bin/bash\necho ok").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&codex_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let script_path = tmp.path().join("dummy-compose.sh");
    std::fs::write(&script_path, "#!/bin/bash\necho ok").unwrap();

    let config = AdapterConfig::new(
        script_path,
        codex_path.clone(),
        tmp.path().to_path_buf(),
        Duration::from_secs(30),
        Duration::from_secs(2),
    )
    .unwrap();

    // Delete codex between config construction and dispatch
    std::fs::remove_file(&codex_path).unwrap();

    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let prompt_path = relay_root.join("prompt.md");
    std::fs::write(&prompt_path, "Build the thing.").unwrap();

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root,
        prompt_path,
    };

    let result = dispatcher.dispatch(&request);
    assert!(result.is_err(), "should fail when codex vanishes");
    match result.unwrap_err() {
        AdapterError::SpawnFailed(msg) => {
            assert!(
                msg.contains("spawn failed"),
                "should mention spawn failure: {msg}"
            );
        }
        other => panic!("expected SpawnFailed, got: {other:?}"),
    }
}

// =========================================================================
// T15: Prompt piped to stdin
// =========================================================================

#[test]
fn t15_prompt_piped_to_stdin() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);
    let prompt_content = "This is the exact prompt content for T15.";

    let (dispatcher, request) = setup(tmp.path(), relay_root, prompt_content, overrides);
    let _result = dispatcher.dispatch(&request).unwrap();

    let captured_stdin = std::fs::read_to_string(capture_dir.join("stdin.txt")).unwrap();
    assert_eq!(
        captured_stdin, prompt_content,
        "captured stdin should match prompt file bytes exactly"
    );
}

// =========================================================================
// T16: Dispatcher cwd = project_root
// =========================================================================

#[test]
fn t16_dispatcher_cwd_is_project_root() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);

    let (dispatcher, request) = setup(tmp.path(), relay_root, "Build it.", overrides);
    let _result = dispatcher.dispatch(&request).unwrap();

    let captured_cwd = std::fs::read_to_string(capture_dir.join("cwd.txt"))
        .unwrap()
        .trim()
        .to_string();

    let expected = tmp.path().canonicalize().unwrap();
    let actual = PathBuf::from(&captured_cwd).canonicalize().unwrap();
    assert_eq!(actual, expected, "cwd should be project_root");
}

// =========================================================================
// T17: IF2 allowlisted env excludes ambient non-allowlisted keys
// =========================================================================

#[test]
fn t17_allowlisted_env_excludes_ambient() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);

    // Set a non-allowlisted env var on the current process
    std::env::set_var("__IF2_TEST_SECRET", "should_not_leak");

    let (dispatcher, request) = setup(tmp.path(), relay_root, "Build it.", overrides);
    let _result = dispatcher.dispatch(&request).unwrap();

    let captured_env = std::fs::read_to_string(capture_dir.join("env.txt")).unwrap();
    assert!(
        !captured_env.contains("__IF2_TEST_SECRET"),
        "non-allowlisted env var must not appear in subprocess env"
    );

    std::env::remove_var("__IF2_TEST_SECRET");
}

// =========================================================================
// T18: Worker metadata JSON
// =========================================================================

#[test]
fn t18_metadata_json_written() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);

    let (dispatcher, request) = setup(tmp.path(), relay_root.clone(), "Build it.", overrides);
    let _result = dispatcher.dispatch(&request).unwrap();

    let metadata_path = relay_root.join("adapter/worker-dispatch.metadata.json");
    assert!(metadata_path.exists(), "metadata JSON must be written");

    let metadata: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&metadata_path).unwrap()).unwrap();

    assert!(metadata["argv"].is_array(), "should have argv");
    assert!(metadata["exit_code"].is_number(), "should have exit_code");
    assert!(metadata["elapsed_ms"].is_number(), "should have elapsed_ms");
    assert!(
        metadata["prompt_path"].is_string(),
        "should have prompt_path"
    );
    assert!(metadata["worker_id"].is_string(), "should have worker_id");
}

// =========================================================================
// T19: Missing prompt file → IoError
// =========================================================================

#[test]
fn t19_missing_prompt_file() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");

    let config = make_config_with_overrides(tmp.path(), vec![]);
    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root,
        prompt_path: tmp.path().join("nonexistent-prompt.md"),
    };

    let result = dispatcher.dispatch(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::IoError(_) => {} // expected
        other => panic!("expected IoError, got: {other:?}"),
    }
}

// =========================================================================
// T20: -o contract on clean exit — suppressing output yields ContractViolation
// =========================================================================

#[test]
fn t20_suppressed_output_on_clean_exit_is_contract_violation() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    // Exit 0 but DON'T write last-message
    let overrides = fake_env(&capture_dir, 0, true, false);

    let (dispatcher, request) = setup(tmp.path(), relay_root, "Build it.", overrides);

    let result = dispatcher.dispatch(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::ContractViolation(msg) => {
            assert!(
                msg.contains("last-message.txt"),
                "should mention the missing output: {msg}"
            );
        }
        other => panic!("expected ContractViolation, got: {other:?}"),
    }
}

// =========================================================================
// T30: IF2 absolute paths in metadata
// =========================================================================

#[test]
fn t30_absolute_paths_in_metadata() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let overrides = fake_env(&capture_dir, 0, true, true);

    let (dispatcher, request) = setup(tmp.path(), relay_root.clone(), "Build it.", overrides);
    let _result = dispatcher.dispatch(&request).unwrap();

    let metadata_path = relay_root.join("adapter/worker-dispatch.metadata.json");
    let metadata: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&metadata_path).unwrap()).unwrap();

    let prompt_path = metadata["prompt_path"].as_str().unwrap();
    assert!(
        std::path::Path::new(prompt_path).is_absolute(),
        "prompt_path in metadata must be absolute: {prompt_path}"
    );

    let last_message_path = metadata["last_message_path"].as_str().unwrap();
    assert!(
        std::path::Path::new(last_message_path).is_absolute(),
        "last_message_path in metadata must be absolute: {last_message_path}"
    );
}

// =========================================================================
// T12: Timeout then TERM-clean exit → Timeout error, process group reaped
// =========================================================================

#[test]
fn t12_timeout_then_clean_term_exit() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");

    // Harness sleeps 60s (longer than timeout), traps TERM and exits cleanly
    let mut overrides = fake_env(&capture_dir, 0, false, false);
    overrides.push(("FAKE_CODEX_SLEEP_SECS".into(), "60".into()));
    overrides.push(("FAKE_CODEX_TERM_MODE".into(), "clean".into()));

    // Use a short timeout (2s) so the test runs quickly
    let config = AdapterConfig {
        script_path: tmp.path().join("dummy-compose.sh"),
        codex_path: fake_codex_path(),
        project_root: tmp.path().to_path_buf(),
        default_timeout: Duration::from_secs(2),
        kill_grace_period: Duration::from_secs(2),
        codex_version: None,
        env_overrides: overrides,
    };
    std::fs::write(&config.script_path, "#!/bin/bash\necho ok").unwrap();

    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let prompt_path = relay_root.join("prompt.md");
    std::fs::write(&prompt_path, "Build it.").unwrap();

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root: relay_root.clone(),
        prompt_path,
    };

    let start = std::time::Instant::now();
    let result = dispatcher.dispatch(&request);
    let wall_time = start.elapsed();

    // Should return Timeout
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::Timeout => {} // expected
        other => panic!("expected Timeout, got: {other:?}"),
    }

    // Should have completed in roughly 2-4s (timeout + grace at most)
    assert!(
        wall_time.as_secs() < 10,
        "should complete within ~timeout+grace, took {}s",
        wall_time.as_secs()
    );

    // Metadata should record timed_out = true
    let metadata_path = relay_root.join("adapter/worker-dispatch.metadata.json");
    if metadata_path.exists() {
        let metadata: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&metadata_path).unwrap()).unwrap();
        assert_eq!(
            metadata["timed_out"], true,
            "metadata should record timed_out"
        );
    }
}

// =========================================================================
// T13: Timeout then KILL escalation with descendant
// =========================================================================

#[test]
fn t13_timeout_kill_escalation_with_descendant() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let ready_file = tmp.path().join("ready");

    // Harness sleeps 60s, ignores TERM, has a descendant that also ignores TERM
    let mut overrides = fake_env(&capture_dir, 0, false, false);
    overrides.push(("FAKE_CODEX_SLEEP_SECS".into(), "60".into()));
    overrides.push(("FAKE_CODEX_TERM_MODE".into(), "ignore".into()));
    overrides.push(("FAKE_CODEX_FORK_DESCENDANT".into(), "1".into()));
    overrides.push(("FAKE_CODEX_DESCENDANT_SLEEP_SECS".into(), "60".into()));
    overrides.push(("FAKE_CODEX_DESCENDANT_TERM_MODE".into(), "ignore".into()));
    overrides.push((
        "FAKE_CODEX_READY_FILE".into(),
        ready_file.to_string_lossy().into_owned(),
    ));

    let config = AdapterConfig {
        script_path: tmp.path().join("dummy-compose.sh"),
        codex_path: fake_codex_path(),
        project_root: tmp.path().to_path_buf(),
        default_timeout: Duration::from_secs(2),
        kill_grace_period: Duration::from_secs(1),
        codex_version: None,
        env_overrides: overrides,
    };
    std::fs::write(&config.script_path, "#!/bin/bash\necho ok").unwrap();

    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let prompt_path = relay_root.join("prompt.md");
    std::fs::write(&prompt_path, "Build it.").unwrap();

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root: relay_root.clone(),
        prompt_path,
    };

    let result = dispatcher.dispatch(&request);

    // Should return Timeout (KILL escalation happened)
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::Timeout => {} // expected
        other => panic!("expected Timeout, got: {other:?}"),
    }

    // If the ready file was created, check status.json for descendant PID
    if ready_file.exists() {
        let status_path = capture_dir.join("status.json");
        if status_path.exists() {
            if let Ok(status_str) = std::fs::read_to_string(&status_path) {
                if let Ok(status) = serde_json::from_str::<serde_json::Value>(&status_str) {
                    if let Some(desc_pid) = status["descendant_pid"].as_u64() {
                        // Brief wait for process reaping
                        std::thread::sleep(Duration::from_millis(100));
                        // Verify descendant is no longer alive
                        let alive = unsafe { libc::kill(desc_pid as i32, 0) };
                        assert_ne!(
                            alive, 0,
                            "descendant PID {} should no longer be alive after SIGKILL group",
                            desc_pid
                        );
                    }
                }
            }
        }
    }
}

// =========================================================================
// T14: External SIGTERM → Ok(result) with signal == Some(SIGTERM)
// =========================================================================

#[test]
fn t14_external_sigterm_captured() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");
    let capture_dir = tmp.path().join("capture");
    let ready_file = tmp.path().join("ready");

    // Harness sleeps 30s, default signal mode (exec sleep → TERM kills sleep directly)
    let mut overrides = fake_env(&capture_dir, 0, false, false);
    overrides.push(("FAKE_CODEX_SLEEP_SECS".into(), "30".into()));
    overrides.push(("FAKE_CODEX_TERM_MODE".into(), "default".into()));
    overrides.push((
        "FAKE_CODEX_READY_FILE".into(),
        ready_file.to_string_lossy().into_owned(),
    ));

    // 30s timeout — we'll send SIGTERM before this expires
    let config = AdapterConfig {
        script_path: tmp.path().join("dummy-compose.sh"),
        codex_path: fake_codex_path(),
        project_root: tmp.path().to_path_buf(),
        default_timeout: Duration::from_secs(30),
        kill_grace_period: Duration::from_secs(2),
        codex_version: None,
        env_overrides: overrides,
    };
    std::fs::write(&config.script_path, "#!/bin/bash\necho ok").unwrap();

    let dispatcher = CodexWorkerDispatcher::new(config);

    std::fs::create_dir_all(&relay_root).unwrap();
    let prompt_path = relay_root.join("prompt.md");
    std::fs::write(&prompt_path, "Build it.").unwrap();

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root: relay_root.clone(),
        prompt_path,
    };

    // Run dispatch in a thread so we can send SIGTERM externally
    let handle = std::thread::spawn(move || dispatcher.dispatch(&request));

    // Wait for harness to be ready, then send SIGTERM to the process group
    let ready_start = std::time::Instant::now();
    while !ready_file.exists() && ready_start.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(ready_file.exists(), "fake-codex should signal readiness");

    // Read the status.json to get the actual PID
    let status_path = capture_dir.join("status.json");
    assert!(status_path.exists(), "status.json must exist after ready");
    let status: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&status_path).unwrap()).unwrap();
    let child_pid = status["parent_pid"].as_i64().unwrap() as i32;

    // Send SIGTERM to the child process (not the group — simulate external kill)
    unsafe {
        libc::kill(child_pid, libc::SIGTERM);
    }

    // Wait for dispatch to complete
    let result = handle.join().expect("dispatch thread panicked");

    // External SIGTERM should produce Ok(result) with signal=Some(SIGTERM)
    match result {
        Ok(res) => {
            assert_eq!(res.signal, Some(libc::SIGTERM), "signal should be SIGTERM");
        }
        Err(AdapterError::Timeout) => {
            // Also acceptable if the kill raced with timeout
        }
        Err(other) => panic!("unexpected error: {other:?}"),
    }
}
