use std::collections::BTreeMap;
use std::io::Read;
use std::io::Write;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::Mutex;
use std::thread;
use std::thread::JoinHandle;
use std::time::Duration;

use capacitor_core::domain::{
    CheckpointKind, MediaArtifact, MediaArtifactType, MermaidSource, MutateRunCommand,
    RunMutationKind,
};
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher, GateCheckpointContext,
    InteractiveIO, InteractivePrompt, InteractiveResponse,
};
use capacitor_core::method_runner::checkpoint_bridge::BridgeInteractiveIO;
use capacitor_core::method_runner::checkpoint_bridge_protocol::{
    decision_path, pending_path, write_json_atomic, CheckpointBridgeDecision,
    CheckpointBridgePending,
};
use capacitor_core::method_runner::definition::{
    ActionKind, CompletionPolicy, DefinitionSource, ExecutionMode, NormalizedGate, NormalizedPhase,
    NormalizedStep, NormalizedStepOutput, StepActionConfig,
};
use capacitor_core::method_runner::executor::{evaluate_gate, execute_run, GateOutcome};
use capacitor_core::method_runner::state::{
    AttemptState, AttemptStatus, MethodRunState, PhaseState, RunStatus, StepState, StepStatus,
    WorkerState, WorkerStatus,
};
use capacitor_core::method_runner::storage::MethodRunPaths;
use capacitor_core::runtime_service::RuntimeServiceEndpoint;

#[derive(Debug)]
struct CapturedRequest {
    request_line: String,
    body: String,
}

struct StubMutationServer {
    port: u16,
    requests: Receiver<CapturedRequest>,
    handle: Option<JoinHandle<()>>,
}

impl StubMutationServer {
    fn spawn(auth_token: &str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind stub mutation server");
        listener
            .set_nonblocking(true)
            .expect("set stub mutation server nonblocking");

        let port = listener
            .local_addr()
            .expect("stub mutation server addr")
            .port();
        let expected_auth = format!("Authorization: Bearer {auth_token}");
        let (request_tx, requests) = mpsc::channel();

        let handle = thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);

            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(1)))
                            .expect("set read timeout");
                        let request = read_http_request(&mut stream);
                        assert!(
                            request
                                .lines()
                                .any(|line| line.trim_end_matches('\r') == expected_auth),
                            "missing bearer token in request: {request}",
                        );

                        let (head, body) = request
                            .split_once("\r\n\r\n")
                            .expect("request must contain header/body separator");
                        let request_line = head
                            .lines()
                            .next()
                            .expect("request must contain a request line")
                            .trim_end_matches('\r')
                            .to_string();
                        request_tx
                            .send(CapturedRequest {
                                request_line,
                                body: body.to_string(),
                            })
                            .expect("send captured request");

                        let response_body = r#"{"ok":true,"message":"accepted"}"#;
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            response_body.len(),
                            response_body
                        );
                        stream
                            .write_all(response.as_bytes())
                            .expect("write stub response");
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if std::time::Instant::now() >= deadline {
                            panic!("timed out waiting for bridge mutation request");
                        }
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("accept bridge mutation request: {error}"),
                }
            }
        });

        Self {
            port,
            requests,
            handle: Some(handle),
        }
    }

    fn endpoint(&self, auth_token: &str) -> RuntimeServiceEndpoint {
        RuntimeServiceEndpoint::localhost(self.port, auth_token)
    }

    fn captured_request(&self) -> CapturedRequest {
        self.requests
            .recv_timeout(Duration::from_secs(2))
            .expect("receive captured bridge request")
    }

    fn finish(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.join().expect("join stub mutation server");
        }
    }
}

impl Drop for StubMutationServer {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            if std::thread::panicking() {
                let _ = handle.join();
            } else {
                handle.join().expect("join stub mutation server");
            }
        }
    }
}

fn read_http_request(stream: &mut std::net::TcpStream) -> String {
    let mut request = Vec::new();
    let mut headers_end = None;
    let mut content_length = 0usize;
    let deadline = std::time::Instant::now() + Duration::from_secs(2);

    loop {
        let mut buf = [0u8; 4096];
        let read = match stream.read(&mut buf) {
            Ok(read) => read,
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::TimedOut =>
            {
                if std::time::Instant::now() >= deadline {
                    panic!("timed out reading bridge request: {error}");
                }
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => panic!("read bridge request: {error}"),
        };
        if read == 0 {
            break;
        }
        request.extend_from_slice(&buf[..read]);

        if headers_end.is_none() {
            if let Some(end) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                let end = end + 4;
                headers_end = Some(end);
                let headers = String::from_utf8_lossy(&request[..end]);
                content_length = headers
                    .lines()
                    .find_map(|line| {
                        let line = line.trim_end_matches('\r');
                        let (name, value) = line.split_once(':')?;
                        if name.eq_ignore_ascii_case("Content-Length") {
                            value.trim().parse::<usize>().ok()
                        } else {
                            None
                        }
                    })
                    .unwrap_or(0);
            }
        }

        if let Some(headers_end) = headers_end {
            let body_len = request.len().saturating_sub(headers_end);
            if body_len >= content_length {
                break;
            }
        }
    }

    String::from_utf8(request).expect("request should be valid UTF-8")
}

fn bridge_context(manifest_path: &Path) -> GateCheckpointContext {
    GateCheckpointContext {
        gate_id: "gate-review".to_string(),
        gate_type: "approval".to_string(),
        phase_id: "phase-001".to_string(),
        checkpoint_kind: CheckpointKind::ImplementationMilestone,
        checkpoint_title: "Review checkpoint".to_string(),
        checkpoint_summary: "Confirm the bridge posts a checkpoint.".to_string(),
        manifest_path: manifest_path.to_path_buf(),
        media_artifacts: vec![MediaArtifact {
            artifact_type: MediaArtifactType::Screenshot,
            path: manifest_path
                .with_extension("png")
                .to_string_lossy()
                .to_string(),
            label: "Checkpoint screenshot".to_string(),
            width: Some(1440),
            height: Some(900),
            duration_secs: None,
        }],
        mermaid_sources: vec![MermaidSource {
            label: "Gate flow".to_string(),
            source: "graph TD; A-->B;".to_string(),
        }],
        prompt_message: "Gate 'gate-review': Do you approve this phase?".to_string(),
    }
}

fn make_bridge(
    run_id: &str,
    project_path: PathBuf,
    home_dir: PathBuf,
    endpoint: RuntimeServiceEndpoint,
) -> BridgeInteractiveIO {
    BridgeInteractiveIO::new(
        endpoint,
        project_path,
        run_id.to_string(),
        home_dir,
        Box::new(FakeInteractiveIO::new("fallback-approved")),
    )
}

#[derive(Debug)]
struct RecordingInteractiveIO {
    response: String,
    prompts: Mutex<Vec<String>>,
    gate_checkpoints: Mutex<Vec<GateCheckpointContext>>,
}

impl RecordingInteractiveIO {
    fn new(response: &str) -> Self {
        Self {
            response: response.to_string(),
            prompts: Mutex::new(Vec::new()),
            gate_checkpoints: Mutex::new(Vec::new()),
        }
    }

    fn prompt_messages(&self) -> Vec<String> {
        self.prompts.lock().expect("lock prompts").clone()
    }

    fn gate_contexts(&self) -> Vec<GateCheckpointContext> {
        self.gate_checkpoints
            .lock()
            .expect("lock gate checkpoints")
            .clone()
    }
}

impl InteractiveIO for RecordingInteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt) {
        self.prompts
            .lock()
            .expect("lock prompts")
            .push(prompt.message.clone());
    }

    fn capture_response(&self) -> InteractiveResponse {
        InteractiveResponse {
            body: self.response.clone(),
        }
    }

    fn emit_gate_checkpoint(&self, context: &GateCheckpointContext) {
        self.gate_checkpoints
            .lock()
            .expect("lock gate checkpoints")
            .push(context.clone());
    }
}

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn interactive_approval_fixture() -> PathBuf {
    crate_root().join("../../methods/fixtures/interactive-approval.yaml")
}

fn empty_phase(phase_id: &str, title: &str, description: &str) -> NormalizedPhase {
    NormalizedPhase {
        id: phase_id.to_string(),
        title: title.to_string(),
        description: description.to_string(),
        execution: ExecutionMode::Serial,
        skills: Vec::new(),
        gate: None,
        steps: Vec::new(),
    }
}

fn gate(gate_id: &str, gate_type: &str, outputs: &[&str]) -> NormalizedGate {
    NormalizedGate {
        id: gate_id.to_string(),
        gate_type: gate_type.to_string(),
        outputs: outputs.iter().map(|output| (*output).to_string()).collect(),
    }
}

fn empty_state_for_phase(phase_id: &str) -> MethodRunState {
    MethodRunState {
        run_id: "run-bridge-tests".to_string(),
        status: RunStatus::Completed,
        definition_frozen: true,
        phases: BTreeMap::from([(
            phase_id.to_string(),
            PhaseState {
                status: capacitor_core::method_runner::state::PhaseStatus::Completed,
                steps: BTreeMap::new(),
                gate_result: None,
            },
        )]),
        seq: 0,
    }
}

fn normalized_output(path: &str, output_type: &str) -> NormalizedStepOutput {
    NormalizedStepOutput {
        path: path.to_string(),
        output_type: output_type.to_string(),
    }
}

fn completed_step_state(
    outputs: &[(&str, &str)],
    workers: &[(&str, bool)],
    attempt_status: AttemptStatus,
) -> StepState {
    let output_map: BTreeMap<String, String> = outputs
        .iter()
        .map(|(name, path)| ((*name).to_string(), (*path).to_string()))
        .collect();
    let worker_map: BTreeMap<String, WorkerState> = workers
        .iter()
        .map(|(worker_id, handoff_received)| {
            (
                (*worker_id).to_string(),
                WorkerState {
                    status: WorkerStatus::Completed,
                    handoff_received: *handoff_received,
                },
            )
        })
        .collect();

    StepState {
        status: StepStatus::Completed,
        current_attempt: 1,
        attempts: BTreeMap::from([(
            1,
            AttemptState {
                status: attempt_status,
                workers: worker_map,
                output_bindings: output_map.clone(),
            },
        )]),
        outputs: output_map,
    }
}

fn write_artifact(path: &Path, contents: impl AsRef<[u8]>) {
    std::fs::create_dir_all(path.parent().expect("artifact parent")).expect("create artifact dir");
    std::fs::write(path, contents).expect("write artifact");
}

#[test]
fn t4_checkpoint_bridge_protocol_paths_are_stable() {
    let home = Path::new("/tmp/home");

    assert_eq!(
        pending_path(home, "run-42", "gate-review"),
        PathBuf::from(
            "/tmp/home/.capacitor/runtime/checkpoint-bridge/run-42/gate-review.pending.json",
        )
    );
    assert_eq!(
        decision_path(home, "run-42", "gate-review"),
        PathBuf::from("/tmp/home/.capacitor/runtime/checkpoint-bridge/run-42/gate-review.json")
    );
}

#[test]
fn t5_bridge_emits_runtime_mutation_and_pending_marker() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-42",
        project_path.clone(),
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );
    let context = bridge_context(&manifest_path);

    bridge.emit_gate_checkpoint(&context);

    let request = server.captured_request();
    assert_eq!(request.request_line, "POST /runtime/run/mutate HTTP/1.1");

    let command: MutateRunCommand =
        serde_json::from_str(&request.body).expect("parse mutate run command");
    assert_eq!(command.kind, RunMutationKind::EmitCheckpoint);
    assert_eq!(command.run_id, "run-42");
    assert_eq!(command.project_path, project_path.to_string_lossy());
    assert_eq!(command.checkpoint_id.as_deref(), Some("gate-review"));
    assert_eq!(
        command.checkpoint_kind,
        Some(CheckpointKind::ImplementationMilestone)
    );
    assert_eq!(
        command.checkpoint_manifest_path.as_deref(),
        Some(manifest_path.to_string_lossy().as_ref())
    );
    assert_eq!(
        command.checkpoint_title.as_deref(),
        Some("Review checkpoint")
    );
    assert_eq!(
        command.checkpoint_summary.as_deref(),
        Some("Confirm the bridge posts a checkpoint.")
    );
    assert_eq!(command.checkpoint_media_artifacts.len(), 1);
    assert_eq!(command.checkpoint_mermaid_sources.len(), 1);

    let pending = pending_path(&home_dir, "run-42", "gate-review");
    assert!(
        pending.exists(),
        "pending marker must exist at {:?}",
        pending
    );
    let pending_payload = std::fs::read_to_string(&pending).expect("read pending marker");
    let pending_marker: CheckpointBridgePending =
        serde_json::from_str(&pending_payload).expect("parse pending marker");
    assert_eq!(pending_marker.version, 1);
    assert_eq!(pending_marker.run_id, "run-42");
    assert_eq!(pending_marker.checkpoint_id, "gate-review");
    assert_eq!(pending_marker.phase_id, "phase-001");
    assert_eq!(pending_marker.gate_type, "approval");
    assert_eq!(pending_marker.project_path, project_path.to_string_lossy());
    assert_eq!(
        pending_marker.manifest_path,
        manifest_path.to_string_lossy().as_ref()
    );

    server.finish();
}

#[test]
fn t6_bridge_normalizes_approve_to_approved() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-42",
        project_path,
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );
    let context = bridge_context(&manifest_path);
    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let decision_file = decision_path(&home_dir, "run-42", "gate-review");
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        write_json_atomic(
            &decision_file,
            &CheckpointBridgeDecision {
                version: 1,
                run_id: "run-42".to_string(),
                checkpoint_id: "gate-review".to_string(),
                action: "approve".to_string(),
                note: Some("Ship it".to_string()),
                decided_at: "2026-03-24T12:00:00Z".to_string(),
            },
        )
        .expect("write decision");
    });

    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "approved");
    assert!(
        !decision_path(&home_dir, "run-42", "gate-review").exists(),
        "decision file should be cleaned up after read"
    );
}

#[test]
fn t7_bridge_normalizes_request_changes_to_rejected() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-99",
        project_path,
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );
    let mut context = bridge_context(&manifest_path);
    context.gate_id = "gate-a".to_string();
    context.prompt_message = "Gate 'gate-a': Do you approve this phase?".to_string();
    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let decision_file = decision_path(&home_dir, "run-99", "gate-a");
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        write_json_atomic(
            &decision_file,
            &CheckpointBridgeDecision {
                version: 1,
                run_id: "run-99".to_string(),
                checkpoint_id: "gate-a".to_string(),
                action: "request_changes".to_string(),
                note: Some("Needs another pass".to_string()),
                decided_at: "2026-03-24T12:05:00Z".to_string(),
            },
        )
        .expect("write decision");
    });

    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "rejected");
}

#[test]
fn t8_executor_only_bridges_human_gates() {
    let temp = tempfile::tempdir().expect("tempdir");
    let paths = MethodRunPaths::new(temp.path());

    let approval_phase = empty_phase("alignment", "Alignment", "Check alignment.");
    let approval_gate = gate("approval-gate", "approval", &[]);
    let approval_state = empty_state_for_phase("alignment");
    let approval_io = RecordingInteractiveIO::new("approved");

    let approval_outcome = evaluate_gate(
        &approval_gate,
        &approval_phase,
        &approval_state,
        &paths,
        &approval_io,
    );

    assert_eq!(approval_outcome, GateOutcome::Approved);
    assert_eq!(approval_io.gate_contexts().len(), 1);
    assert!(approval_io.prompt_messages().is_empty());
    assert_eq!(
        approval_io.gate_contexts()[0].checkpoint_kind,
        CheckpointKind::AlignmentReview
    );

    let manual_phase = empty_phase("qa", "QA", "Confirm manual verification.");
    let manual_gate = gate("qa-gate", "manual_test_complete", &[]);
    let manual_state = empty_state_for_phase("qa");
    let manual_io = RecordingInteractiveIO::new("approved");

    let manual_outcome = evaluate_gate(
        &manual_gate,
        &manual_phase,
        &manual_state,
        &paths,
        &manual_io,
    );

    assert_eq!(manual_outcome, GateOutcome::Approved);
    assert_eq!(manual_io.gate_contexts().len(), 1);
    assert!(manual_io.prompt_messages().is_empty());
    assert_eq!(
        manual_io.gate_contexts()[0].checkpoint_kind,
        CheckpointKind::ImplementationMilestone
    );

    let interactive_root = tempfile::tempdir().expect("interactive tempdir");
    let interactive_source = DefinitionSource {
        definition_path: interactive_approval_fixture(),
        execution_root: interactive_root.path().to_path_buf(),
    };
    let interactive_io = RecordingInteractiveIO::new("approved");

    let interactive_state = execute_run(
        &interactive_source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &interactive_io,
    )
    .expect("execute interactive approval fixture");

    assert_eq!(interactive_state.status, RunStatus::Completed);
    assert_eq!(interactive_io.gate_contexts().len(), 0);
    assert_eq!(interactive_io.prompt_messages().len(), 1);
    assert_eq!(
        interactive_io.prompt_messages()[0],
        "Do you approve the draft?"
    );

    let validation_phase = empty_phase("validation", "Validation", "Check outputs.");
    let validation_gate = gate("outputs-gate", "outputs_present", &[]);
    let validation_state = empty_state_for_phase("validation");
    let validation_io = RecordingInteractiveIO::new("approved");

    let validation_outcome = evaluate_gate(
        &validation_gate,
        &validation_phase,
        &validation_state,
        &paths,
        &validation_io,
    );

    assert_eq!(validation_outcome, GateOutcome::Approved);
    assert!(validation_io.gate_contexts().is_empty());
    assert!(validation_io.prompt_messages().is_empty());
}

#[test]
fn t9_bridge_generated_manifest_stays_swift_compatible() {
    let temp = tempfile::tempdir().expect("tempdir");
    let paths = MethodRunPaths::new(temp.path());

    let phase = NormalizedPhase {
        id: "review".to_string(),
        title: "Review".to_string(),
        description: "Review the generated artifacts before continuing.".to_string(),
        execution: ExecutionMode::Serial,
        skills: Vec::new(),
        gate: None,
        steps: vec![
            NormalizedStep {
                id: "dispatch".to_string(),
                title: "Implementation".to_string(),
                action: ActionKind::Dispatch,
                description: String::new(),
                template: None,
                skills: Vec::new(),
                max_attempts: 1,
                completion_policy: CompletionPolicy::AllComplete,
                inputs: Vec::new(),
                outputs: BTreeMap::from([(
                    "summary".to_string(),
                    normalized_output("artifacts/summary.md", "markdown"),
                )]),
                gate: None,
                config: StepActionConfig::Dispatch {
                    instructions: "Implement the feature.".to_string(),
                    workers: Vec::new(),
                },
            },
            NormalizedStep {
                id: "capture".to_string(),
                title: "Screenshot".to_string(),
                action: ActionKind::Synthesis,
                description: String::new(),
                template: None,
                skills: Vec::new(),
                max_attempts: 1,
                completion_policy: CompletionPolicy::AllComplete,
                inputs: Vec::new(),
                outputs: BTreeMap::from([(
                    "screen".to_string(),
                    normalized_output("artifacts/screen.png", "screenshot"),
                )]),
                gate: None,
                config: StepActionConfig::Synthesis {
                    instructions: "Capture the result.".to_string(),
                    output: "screen".to_string(),
                },
            },
            NormalizedStep {
                id: "diagram".to_string(),
                title: "Architecture".to_string(),
                action: ActionKind::Synthesis,
                description: String::new(),
                template: None,
                skills: Vec::new(),
                max_attempts: 1,
                completion_policy: CompletionPolicy::AllComplete,
                inputs: Vec::new(),
                outputs: BTreeMap::from([(
                    "flow".to_string(),
                    normalized_output("artifacts/flow.mmd", "mermaid"),
                )]),
                gate: None,
                config: StepActionConfig::Synthesis {
                    instructions: "Describe the architecture.".to_string(),
                    output: "flow".to_string(),
                },
            },
        ],
    };
    let gate = gate("review-gate", "approval", &[]);

    let handoff_path = paths.canonical_handoff("review", "dispatch", 1, "primary");
    let summary_path = paths
        .attempt_dir("review", "dispatch", 1)
        .join("artifacts/summary.md");
    let screenshot_path = paths
        .attempt_dir("review", "capture", 1)
        .join("artifacts/screen.png");
    let mermaid_path = paths
        .attempt_dir("review", "diagram", 1)
        .join("artifacts/flow.mmd");

    write_artifact(&handoff_path, "# Handoff\n\nVerdict: CLEAN\n");
    write_artifact(&summary_path, "# Summary\n\nCheckpoint artifact.\n");
    write_artifact(&screenshot_path, b"not-a-real-png");
    write_artifact(&mermaid_path, "graph TD\nA-->B\n");

    let state = MethodRunState {
        run_id: "run-manifest".to_string(),
        status: RunStatus::Completed,
        definition_frozen: true,
        phases: BTreeMap::from([(
            "review".to_string(),
            PhaseState {
                status: capacitor_core::method_runner::state::PhaseStatus::Completed,
                steps: BTreeMap::from([
                    (
                        "dispatch".to_string(),
                        completed_step_state(
                            &[("summary", "artifacts/summary.md")],
                            &[("primary", true)],
                            AttemptStatus::Completed,
                        ),
                    ),
                    (
                        "capture".to_string(),
                        completed_step_state(
                            &[("screen", "artifacts/screen.png")],
                            &[],
                            AttemptStatus::OutputBound,
                        ),
                    ),
                    (
                        "diagram".to_string(),
                        completed_step_state(
                            &[("flow", "artifacts/flow.mmd")],
                            &[],
                            AttemptStatus::OutputBound,
                        ),
                    ),
                ]),
                gate_result: None,
            },
        )]),
        seq: 0,
    };
    let interactive_io = RecordingInteractiveIO::new("approved");

    let outcome = evaluate_gate(&gate, &phase, &state, &paths, &interactive_io);
    assert_eq!(outcome, GateOutcome::Approved);

    let gate_contexts = interactive_io.gate_contexts();
    assert_eq!(gate_contexts.len(), 1);
    assert_eq!(gate_contexts[0].media_artifacts.len(), 1);
    assert_eq!(
        gate_contexts[0].media_artifacts[0].artifact_type,
        MediaArtifactType::Screenshot
    );
    assert_eq!(gate_contexts[0].mermaid_sources.len(), 1);
    assert_eq!(
        gate_contexts[0].mermaid_sources[0].label,
        "Architecture: flow"
    );

    let manifest_path = paths.gate_manifest_path("review", "review-gate");
    assert!(manifest_path.exists(), "manifest must be written");

    let manifest_json = std::fs::read_to_string(&manifest_path).expect("read manifest");
    let manifest: serde_json::Value = serde_json::from_str(&manifest_json).expect("parse manifest");

    assert_eq!(manifest["version"], 1);
    assert_eq!(manifest["milestone_id"], "review-gate");
    assert_eq!(
        manifest["summary"],
        "Review the generated artifacts before continuing."
    );

    let artifacts = manifest["artifacts"].as_array().expect("artifacts array");
    assert!(
        artifacts
            .iter()
            .all(|artifact| artifact["label"].is_string() && artifact["path"].is_string()),
        "every artifact must include label and path"
    );

    let artifact_types: Vec<&str> = artifacts
        .iter()
        .filter_map(|artifact| artifact["artifact_type"].as_str())
        .collect();
    assert!(
        artifact_types.contains(&"text"),
        "manifest should include text artifacts"
    );
    assert!(
        artifact_types.contains(&"screenshot"),
        "manifest should include screenshot artifacts"
    );
    assert!(
        artifact_types.contains(&"mermaid"),
        "manifest should include mermaid artifacts"
    );
    assert!(
        artifacts.iter().all(|artifact| {
            artifact["path"]
                .as_str()
                .is_some_and(|path| Path::new(path).is_absolute())
        }),
        "executor should write absolute artifact paths for Swift consumers"
    );

    let decisions = &manifest["decisions"];
    assert!(decisions["approve"]["label"].is_string());
    assert!(decisions["approve"]["description"].is_string());
    assert!(decisions["request_changes"]["label"].is_string());
    assert!(decisions["request_changes"]["description"].is_string());
}
