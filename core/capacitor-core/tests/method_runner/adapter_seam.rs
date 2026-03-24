//! Adapter seam tests (T21–T27).
//!
//! T21–T23: AdapterConfig construction and preflight validation.
//! T25–T27: Widened DTO contract and executor seam threading.

use std::cell::RefCell;
use std::io::Write;
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{
    AdapterError, FakePromptBuilder, FakeWorkerDispatcher, FileInteractiveIO, InteractiveIO,
    InteractivePrompt, PromptBuildRequest, PromptBuildResult, PromptBuilder, WorkerDispatchRequest,
    WorkerDispatchResult, WorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::executor::execute_run;

// ---------------------------------------------------------------------------
// Spy adapters for T27
// ---------------------------------------------------------------------------

/// Records all PromptBuildRequests it receives, delegates to FakePromptBuilder.
struct SpyPromptBuilder {
    calls: RefCell<Vec<PromptBuildRequest>>,
}

impl SpyPromptBuilder {
    fn new() -> Self {
        Self {
            calls: RefCell::new(Vec::new()),
        }
    }

    fn recorded_calls(&self) -> Vec<PromptBuildRequest> {
        self.calls.borrow().clone()
    }
}

impl PromptBuilder for SpyPromptBuilder {
    fn build_prompt(
        &self,
        request: &PromptBuildRequest,
    ) -> Result<PromptBuildResult, AdapterError> {
        self.calls.borrow_mut().push(request.clone());
        FakePromptBuilder.build_prompt(request)
    }
}

/// Records all WorkerDispatchRequests it receives, delegates to FakeWorkerDispatcher.
struct SpyWorkerDispatcher {
    calls: RefCell<Vec<WorkerDispatchRequest>>,
}

impl SpyWorkerDispatcher {
    fn new() -> Self {
        Self {
            calls: RefCell::new(Vec::new()),
        }
    }

    fn recorded_calls(&self) -> Vec<WorkerDispatchRequest> {
        self.calls.borrow().clone()
    }
}

impl WorkerDispatcher for SpyWorkerDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError> {
        self.calls.borrow_mut().push(request.clone());
        FakeWorkerDispatcher.dispatch(request)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create a minimal method YAML that exercises template + skills merging.
fn skills_template_yaml() -> String {
    r#"
schema_version: "1"
method:
  id: seam-test
  version: "1.0"
  title: Seam Test
  defaults:
    skills:
      - base-skill
    template: implement
    max_attempts: 1
    completion_policy: all_complete
  outputs:
    result:
      from: p1.s1.result
      required: true
  phases:
    - id: p1
      title: Phase 1
      skills:
        - phase-skill
      steps:
        - id: s1
          title: Step 1
          action: dispatch
          skills:
            - step-skill
          template: review
          outputs:
            result:
              path: artifacts/result.md
              type: markdown
          dispatch:
            instructions: do the thing
            workers:
              - id: w1
                title: Worker 1
                instructions: worker instructions
                skills:
                  - worker-skill
                  - base-skill
"#
    .to_string()
}

// =========================================================================
// T25: FakePromptBuilder under widened request
// =========================================================================

#[test]
fn t25_fake_prompt_builder_under_widened_request() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay");

    let request = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root: relay_root.clone(),
        instructions: "Build it.".into(),
        template: Some("implement".into()),
        skills: vec!["base-skill".into(), "phase-skill".into()],
    };

    let builder = FakePromptBuilder;
    let result = builder.build_prompt(&request).unwrap();

    // FakePromptBuilder succeeds without shell involvement
    assert!(result.header_path.exists(), "header must exist");
    assert!(result.prompt_path.exists(), "prompt must exist");

    // Verify contents still reflect the request metadata
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(header.contains("s1"), "header should contain step_id");
    assert!(header.contains("p1"), "header should contain phase_id");
}

// =========================================================================
// T26: FakeWorkerDispatcher under widened request/result
// =========================================================================

#[test]
fn t26_fake_worker_dispatcher_under_widened_request_result() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay/workers/w1");

    let request = WorkerDispatchRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        worker_id: "w1".into(),
        relay_root: relay_root.clone(),
        prompt_path: relay_root.join("prompt.md"),
    };

    let dispatcher = FakeWorkerDispatcher;
    let result = dispatcher.dispatch(&request).unwrap();

    // Verify widened result fields have sensible defaults
    assert_eq!(result.exit_code, 0, "clean exit");
    assert_eq!(result.signal, None, "no signal for fake dispatch");
    assert_eq!(
        result.elapsed,
        Duration::ZERO,
        "zero elapsed for fake dispatch"
    );
    assert_eq!(result.worker_id, "w1");

    // Handoff still written
    assert!(
        relay_root.join("HANDOFF.md").exists(),
        "HANDOFF.md must exist"
    );
}

// =========================================================================
// T27: Executor seam threading — spy adapters observe merged skills,
//      template, and dispatch receives exact prompt_path from IF1
// =========================================================================

#[test]
fn t27_executor_seam_threads_skills_template_and_prompt_path() {
    let tmp = tempfile::tempdir().unwrap();
    let exec_root = tmp.path().join("run");
    let def_path = tmp.path().join("method.yaml");

    // Write the method YAML
    std::fs::write(&def_path, skills_template_yaml()).unwrap();

    let source = DefinitionSource {
        definition_path: def_path,
        execution_root: exec_root.clone(),
    };

    let spy_builder = SpyPromptBuilder::new();
    let spy_dispatcher = SpyWorkerDispatcher::new();
    let interactive = capacitor_core::method_runner::adapters::FakeInteractiveIO::new("approved");

    let _state = execute_run(&source, &spy_builder, &spy_dispatcher, &interactive).unwrap();

    // --- Verify IF1 (prompt builder) received merged skills and template ---
    let builder_calls = spy_builder.recorded_calls();
    assert_eq!(builder_calls.len(), 1, "exactly one prompt build call");

    let build_req = &builder_calls[0];
    assert_eq!(
        build_req.template,
        Some("review".into()),
        "step-level template should override method default"
    );

    // Merged skills: base-skill (method), phase-skill (phase), step-skill (step), worker-skill (worker)
    // "base-skill" appears in both method defaults and worker skills — should be deduplicated
    assert!(
        build_req.skills.contains(&"base-skill".to_string()),
        "should have method default skill"
    );
    assert!(
        build_req.skills.contains(&"phase-skill".to_string()),
        "should have phase skill"
    );
    assert!(
        build_req.skills.contains(&"step-skill".to_string()),
        "should have step skill"
    );
    assert!(
        build_req.skills.contains(&"worker-skill".to_string()),
        "should have worker skill"
    );
    // Deduplicated: base-skill appears only once
    let base_count = build_req
        .skills
        .iter()
        .filter(|s| *s == "base-skill")
        .count();
    assert_eq!(base_count, 1, "base-skill should be deduplicated");

    // --- Verify IF2 (dispatcher) received prompt_path from IF1 result ---
    let dispatch_calls = spy_dispatcher.recorded_calls();
    assert_eq!(dispatch_calls.len(), 1, "exactly one dispatch call");

    let dispatch_req = &dispatch_calls[0];
    assert!(
        dispatch_req.prompt_path.exists(),
        "prompt_path must point to a file that IF1 created"
    );
    assert!(
        dispatch_req.prompt_path.is_absolute(),
        "prompt_path must be absolute"
    );

    // The prompt_path should be the prompt.md that FakePromptBuilder wrote
    let prompt_content = std::fs::read_to_string(&dispatch_req.prompt_path).unwrap();
    assert!(
        prompt_content.contains("worker instructions"),
        "prompt should contain the worker instructions"
    );
}

// =========================================================================
// T21: Valid AdapterConfig
// =========================================================================

#[test]
fn t21_valid_adapter_config_construction() {
    let tmp = tempfile::tempdir().unwrap();

    // Create fake script and codex binary files
    let script_path = tmp.path().join("compose-prompt.sh");
    std::fs::write(&script_path, "#!/bin/bash\necho ok").unwrap();

    let codex_path = tmp.path().join("fake-codex");
    // Write a script that responds to --version
    {
        let mut f = std::fs::File::create(&codex_path).unwrap();
        writeln!(f, "#!/bin/bash").unwrap();
        writeln!(f, "echo 'codex 0.1.0-test'").unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&codex_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let config = AdapterConfig::new(
        script_path.clone(),
        codex_path.clone(),
        tmp.path().to_path_buf(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    )
    .unwrap();

    assert_eq!(config.script_path, script_path);
    assert_eq!(config.codex_path, codex_path);
    assert_eq!(config.default_timeout, Duration::from_secs(300));
    assert_eq!(config.kill_grace_period, Duration::from_secs(5));
    // Version probe may or may not succeed depending on OS permissions
    // Just verify the field is populated (it's best-effort)
    // The important thing is construction didn't fail
}

// =========================================================================
// T22: Missing compose script path
// =========================================================================

#[test]
fn t22_missing_compose_script_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let codex_path = tmp.path().join("fake-codex");
    std::fs::write(&codex_path, "#!/bin/bash\necho ok").unwrap();

    let result = AdapterConfig::new(
        tmp.path().join("nonexistent-script.sh"),
        codex_path,
        tmp.path().to_path_buf(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    );

    assert!(result.is_err(), "missing script should fail");
    let err = result.unwrap_err();
    match err {
        AdapterError::SpawnFailed(msg) => {
            assert!(
                msg.contains("compose-prompt script not found"),
                "error should mention compose-prompt: {msg}"
            );
        }
        other => panic!("expected SpawnFailed, got: {other:?}"),
    }
}

// =========================================================================
// T23: Missing codex path
// =========================================================================

#[test]
fn t23_missing_codex_path_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let script_path = tmp.path().join("compose-prompt.sh");
    std::fs::write(&script_path, "#!/bin/bash\necho ok").unwrap();

    let result = AdapterConfig::new(
        script_path,
        tmp.path().join("nonexistent-codex"),
        tmp.path().to_path_buf(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    );

    assert!(result.is_err(), "missing codex should fail");
    let err = result.unwrap_err();
    match err {
        AdapterError::SpawnFailed(msg) => {
            assert!(
                msg.contains("codex binary not found"),
                "error should mention codex: {msg}"
            );
        }
        other => panic!("expected SpawnFailed, got: {other:?}"),
    }
}

// =========================================================================
// FileInteractiveIO: reads gate responses from pre-staged JSON files
// =========================================================================

#[test]
fn file_interactive_io_reads_gate_responses() {
    let tmp = tempfile::tempdir().unwrap();
    let response_dir = tmp.path().join("responses");
    std::fs::create_dir_all(&response_dir).unwrap();

    // Stage a response file for gate "build-gate"
    std::fs::write(
        response_dir.join("build-gate.json"),
        r#"{"action": "approved", "note": "Looks good"}"#,
    )
    .unwrap();

    let io = FileInteractiveIO::new(response_dir);

    // When prompted with gate id "build-gate", should return "approved"
    io.emit_prompt(&InteractivePrompt {
        message: "Gate 'build-gate': Do you approve this phase?".into(),
    });
    let response = io.capture_response();
    assert_eq!(response.body.trim(), "approved");
}

#[test]
fn file_interactive_io_falls_back_to_approved() {
    let tmp = tempfile::tempdir().unwrap();
    let io = FileInteractiveIO::new(tmp.path().to_path_buf());

    io.emit_prompt(&InteractivePrompt {
        message: "Gate 'unknown-gate': Do you approve?".into(),
    });
    let response = io.capture_response();
    assert_eq!(response.body.trim(), "approved");
}
