use std::collections::BTreeMap;
use std::io::Write;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::common::{read_http_request, RunCommandBuilder, RunMutationKind};
use capacitor_core::domain::{
    CheckpointDecisionRelay, CheckpointKind, MediaArtifact, MediaArtifactType, MermaidSource,
    MutateRunCommand, RunMutationKind as RealRunMutationKind,
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
use capacitor_core::runtime::service::RuntimeServiceEndpoint;
use capacitor_core::CoreRuntime;

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
        Self::spawn_n(auth_token, 1)
    }

    fn spawn_n(auth_token: &str, expected_requests: usize) -> Self {
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
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut served_requests = 0usize;

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
                        served_requests += 1;
                        if served_requests >= expected_requests {
                            break;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
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

struct RuntimeMutationServer {
    port: u16,
    handle: Option<JoinHandle<()>>,
}

impl RuntimeMutationServer {
    fn spawn(runtime: Arc<CoreRuntime>, auth_token: &str, expected_requests: usize) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind runtime mutation server");
        listener
            .set_nonblocking(true)
            .expect("set runtime mutation server nonblocking");

        let port = listener
            .local_addr()
            .expect("runtime mutation server addr")
            .port();
        let expected_auth = format!("Authorization: Bearer {auth_token}");

        let handle = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut served_requests = 0usize;

            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(1)))
                            .expect("set runtime server read timeout");
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
                            .trim_end_matches('\r');
                        assert_eq!(request_line, "POST /runtime/run/mutate HTTP/1.1");

                        let command: MutateRunCommand =
                            serde_json::from_str(body).expect("parse mutate run command");
                        let outcome = runtime
                            .mutate_run(command)
                            .expect("runtime-backed mutation should not error");
                        let response_body =
                            serde_json::to_string(&outcome).expect("serialize mutation outcome");
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            response_body.len(),
                            response_body
                        );
                        stream
                            .write_all(response.as_bytes())
                            .expect("write runtime server response");

                        served_requests += 1;
                        if served_requests >= expected_requests {
                            break;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
                            panic!("timed out waiting for runtime-backed bridge mutation request");
                        }
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("accept runtime-backed bridge mutation request: {error}"),
                }
            }
        });

        Self {
            port,
            handle: Some(handle),
        }
    }

    fn endpoint(&self, auth_token: &str) -> RuntimeServiceEndpoint {
        RuntimeServiceEndpoint::localhost(self.port, auth_token)
    }

    fn finish(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.join().expect("join runtime mutation server");
        }
    }
}

impl Drop for RuntimeMutationServer {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            if std::thread::panicking() {
                let _ = handle.join();
            } else {
                handle.join().expect("join runtime mutation server");
            }
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

fn interactive_approval_fixture() -> PathBuf {
    crate::common::fixtures::method_fixture_path("interactive-approval.yaml")
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

fn wait_for(description: &str, timeout: Duration, mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    loop {
        if predicate() {
            return;
        }

        assert!(
            Instant::now() < deadline,
            "timed out waiting for {description}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn runtime_create_cmd(project_path: &str, run_id: &str, method_id: &str) -> RunCommandBuilder {
    RunCommandBuilder {
        project_path: project_path.to_string(),
        run_id: run_id.to_string(),
        method_id: Some(method_id.to_string()),
        ..RunCommandBuilder::default()
    }
}

fn runtime_base_cmd(project_path: &str, run_id: &str) -> RunCommandBuilder {
    RunCommandBuilder {
        project_path: project_path.to_string(),
        run_id: run_id.to_string(),
        ..RunCommandBuilder::default()
    }
}

fn runtime_mutate(
    runtime: &CoreRuntime,
    command: RunCommandBuilder,
    kind: RunMutationKind,
) -> capacitor_core::domain::MutationOutcome {
    runtime
        .mutate_run(command.into_command(kind))
        .expect("runtime mutation should not error")
}

fn runtime_checkpoint_created_at(runtime: &CoreRuntime, run_id: &str) -> String {
    runtime
        .app_snapshot()
        .expect("runtime snapshot")
        .runs
        .iter()
        .find(|run| run.id == run_id)
        .expect("run exists")
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists")
        .created_at
        .clone()
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
    assert_eq!(command.run_id, "run-42");
    assert_eq!(command.project_path, project_path.to_string_lossy());
    let RealRunMutationKind::EmitCheckpoint {
        checkpoint_kind,
        checkpoint_title,
        checkpoint_summary,
        checkpoint_manifest_path,
        checkpoint_media_artifacts,
        checkpoint_mermaid_sources,
        checkpoint_decision_relay,
        checkpoint_id,
        ..
    } = &command.kind
    else {
        panic!("expected emit_checkpoint, got {:?}", command.kind);
    };
    assert_eq!(checkpoint_id.as_deref(), Some("gate-review"));
    assert_eq!(
        *checkpoint_kind,
        Some(CheckpointKind::ImplementationMilestone)
    );
    assert_eq!(
        *checkpoint_decision_relay,
        Some(CheckpointDecisionRelay::CheckpointBridge)
    );
    assert_eq!(
        checkpoint_manifest_path.as_deref(),
        Some(manifest_path.to_string_lossy().as_ref())
    );
    assert_eq!(checkpoint_title.as_deref(), Some("Review checkpoint"));
    assert_eq!(
        checkpoint_summary.as_deref(),
        Some("Confirm the bridge posts a checkpoint.")
    );
    assert_eq!(checkpoint_media_artifacts.len(), 1);
    assert_eq!(checkpoint_mermaid_sources.len(), 1);

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

#[test]
fn t13_bridge_crash_recovery_reemits_idempotently_and_returns_existing_decision_immediately() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let context = bridge_context(&manifest_path);
    let runtime = CoreRuntime::new().expect("runtime");
    let run_id = "run-crash-recovery";
    let project_path_string = project_path.to_string_lossy().to_string();

    let create = runtime
        .mutate_run(
            runtime_create_cmd(&project_path_string, run_id, "execution_only")
                .into_command(RunMutationKind::Create),
        )
        .expect("create run");
    assert!(create.ok, "create failed: {}", create.message);

    let mut attach_command = runtime_base_cmd(&project_path_string, run_id);
    attach_command.session_id = Some("session-crash-recovery".to_string());
    let attach = runtime_mutate(
        runtime.as_ref(),
        attach_command,
        RunMutationKind::AttachSession,
    );
    assert!(attach.ok, "attach failed: {}", attach.message);

    let mut emit_command = runtime_base_cmd(&project_path_string, run_id);
    emit_command.checkpoint_id = Some(context.gate_id.clone());
    emit_command.checkpoint_kind = Some(context.checkpoint_kind.clone());
    emit_command.checkpoint_title = Some(context.checkpoint_title.clone());
    emit_command.checkpoint_summary = Some(context.checkpoint_summary.clone());
    emit_command.checkpoint_manifest_path = Some(manifest_path.to_string_lossy().to_string());
    let first_emit = runtime_mutate(
        runtime.as_ref(),
        emit_command,
        RunMutationKind::EmitCheckpoint,
    );
    assert!(first_emit.ok, "first emit failed: {}", first_emit.message);

    let first_created_at = runtime_checkpoint_created_at(runtime.as_ref(), run_id);

    let pending_file = pending_path(&home_dir, run_id, &context.gate_id);
    write_json_atomic(
        &pending_file,
        &CheckpointBridgePending {
            version: 1,
            project_path: project_path_string.clone(),
            run_id: run_id.to_string(),
            checkpoint_id: context.gate_id.clone(),
            phase_id: context.phase_id.clone(),
            gate_type: context.gate_type.clone(),
            manifest_path: manifest_path.to_string_lossy().to_string(),
            created_at: "2026-03-24T12:00:00Z".to_string(),
        },
    )
    .expect("write pending marker");

    let decision_file = decision_path(&home_dir, run_id, &context.gate_id);
    write_json_atomic(
        &decision_file,
        &CheckpointBridgeDecision {
            version: 1,
            run_id: run_id.to_string(),
            checkpoint_id: context.gate_id.clone(),
            action: "approve".to_string(),
            note: Some("Recovered during restart".to_string()),
            decided_at: "2026-03-24T12:01:00Z".to_string(),
        },
    )
    .expect("write pre-existing decision");

    let server = RuntimeMutationServer::spawn(runtime.clone(), "bridge-token", 1);
    let bridge = make_bridge(
        run_id,
        project_path.clone(),
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );

    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let resumed_created_at = runtime_checkpoint_created_at(runtime.as_ref(), run_id);
    assert_eq!(resumed_created_at, first_created_at);

    let start = Instant::now();
    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "approved");
    assert!(
        start.elapsed() < Duration::from_millis(400),
        "capture_response should return immediately when the decision file already exists"
    );
    assert!(
        !decision_file.exists(),
        "decision file should be cleaned up after crash recovery read"
    );
    assert!(
        !pending_file.exists(),
        "pending marker should be cleaned up after reading a recovered decision"
    );
}

#[test]
fn t14_bridge_isolates_same_gate_id_across_concurrent_runs() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let pending_a = pending_path(&home_dir, "run-A", "gate-review");
    let pending_b = pending_path(&home_dir, "run-B", "gate-review");
    let decision_a = decision_path(&home_dir, "run-A", "gate-review");
    let decision_b = decision_path(&home_dir, "run-B", "gate-review");
    assert_ne!(pending_a, pending_b);
    assert_ne!(decision_a, decision_b);

    let server = StubMutationServer::spawn_n("bridge-token", 2);
    let endpoint = server.endpoint("bridge-token");

    let project_path_a = project_path.clone();
    let project_path_b = project_path.clone();
    let home_dir_a = home_dir.clone();
    let home_dir_b = home_dir.clone();
    let manifest_path_a = manifest_path.clone();
    let manifest_path_b = manifest_path.clone();
    let endpoint_a = endpoint.clone();
    let endpoint_b = endpoint;

    let run_a = thread::spawn(move || {
        let bridge = make_bridge("run-A", project_path_a, home_dir_a, endpoint_a);
        let context = bridge_context(&manifest_path_a);
        bridge.emit_gate_checkpoint(&context);
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge).body
    });
    let run_b = thread::spawn(move || {
        let bridge = make_bridge("run-B", project_path_b, home_dir_b, endpoint_b);
        let context = bridge_context(&manifest_path_b);
        bridge.emit_gate_checkpoint(&context);
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge).body
    });

    wait_for("both pending markers", Duration::from_secs(2), || {
        pending_a.exists() && pending_b.exists()
    });

    write_json_atomic(
        &decision_a,
        &CheckpointBridgeDecision {
            version: 1,
            run_id: "run-A".to_string(),
            checkpoint_id: "gate-review".to_string(),
            action: "approve".to_string(),
            note: Some("Run A approved".to_string()),
            decided_at: "2026-03-24T12:10:00Z".to_string(),
        },
    )
    .expect("write run-A decision");

    wait_for("run-A response", Duration::from_secs(2), || {
        run_a.is_finished()
    });
    let run_a_response = run_a.join().expect("join run-A bridge");
    assert_eq!(run_a_response, "approved");

    thread::sleep(Duration::from_millis(700));
    assert!(
        !run_b.is_finished(),
        "run-B should remain blocked until its own decision file appears"
    );

    write_json_atomic(
        &decision_b,
        &CheckpointBridgeDecision {
            version: 1,
            run_id: "run-B".to_string(),
            checkpoint_id: "gate-review".to_string(),
            action: "request_changes".to_string(),
            note: Some("Run B needs changes".to_string()),
            decided_at: "2026-03-24T12:11:00Z".to_string(),
        },
    )
    .expect("write run-B decision");

    wait_for("run-B response", Duration::from_secs(2), || {
        run_b.is_finished()
    });
    let run_b_response = run_b.join().expect("join run-B bridge");
    assert_eq!(run_b_response, "rejected");

    server.finish();
}

// ---------------------------------------------------------------------------
// Fail-closed: bridge falls back to prompt when mutation is rejected
// ---------------------------------------------------------------------------

struct RejectingStubServer {
    port: u16,
    handle: Option<JoinHandle<()>>,
}

impl RejectingStubServer {
    fn spawn(auth_token: &str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind rejecting stub server");
        listener
            .set_nonblocking(true)
            .expect("set rejecting stub server nonblocking");
        let port = listener
            .local_addr()
            .expect("rejecting stub server addr")
            .port();
        let expected_auth = format!("Authorization: Bearer {auth_token}");

        let handle = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
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
                        let response_body =
                            r#"{"ok":false,"message":"checkpoint rejected by runtime"}"#;
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            response_body.len(),
                            response_body
                        );
                        stream
                            .write_all(response.as_bytes())
                            .expect("write rejecting stub response");
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
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
            handle: Some(handle),
        }
    }

    fn endpoint(&self, auth_token: &str) -> RuntimeServiceEndpoint {
        RuntimeServiceEndpoint::localhost(self.port, auth_token)
    }

    fn finish(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.join().expect("join rejecting stub server");
        }
    }
}

#[test]
fn t15_bridge_falls_back_to_prompt_when_mutation_rejected() {
    let token = "reject-test-token";
    let server = RejectingStubServer::spawn(token);
    let endpoint = server.endpoint(token);
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().to_path_buf();
    let project_path = PathBuf::from("/test/project");

    let bridge = BridgeInteractiveIO::new(
        endpoint,
        project_path,
        "run-rejected".to_string(),
        home_dir.clone(),
        Box::new(FakeInteractiveIO::new("fallback-approved")),
    );

    let mut context = bridge_context(Path::new("/test/manifest.json"));
    context.gate_id = "gate-rejected".to_string();
    context.prompt_message = "Gate 'gate-rejected': Do you approve?".to_string();
    bridge.emit_gate_checkpoint(&context);

    // The pending marker should have been cleaned up after mutation rejection
    let marker = pending_path(&home_dir, "run-rejected", "gate-rejected");
    assert!(
        !marker.exists(),
        "pending marker should be cleaned up after mutation rejection"
    );

    // capture_response() should delegate to the fallback (not block forever)
    // because emit_gate_checkpoint() did not arm current_gate_id
    let response = bridge.capture_response();
    assert_eq!(
        response.body, "fallback-approved",
        "bridge should fall back to standard prompt when mutation is rejected"
    );

    server.finish();
}

#[test]
fn t15_bridge_falls_back_to_prompt_when_server_unreachable() {
    // Connect to a port where nothing is listening
    let endpoint = RuntimeServiceEndpoint::localhost(1, "dead-token");
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().to_path_buf();
    let project_path = PathBuf::from("/test/project");

    let bridge = BridgeInteractiveIO::new(
        endpoint,
        project_path,
        "run-unreachable".to_string(),
        home_dir.clone(),
        Box::new(FakeInteractiveIO::new("fallback-approved")),
    );

    let mut context = bridge_context(Path::new("/test/manifest.json"));
    context.gate_id = "gate-unreachable".to_string();
    context.prompt_message = "Gate 'gate-unreachable': Do you approve?".to_string();
    bridge.emit_gate_checkpoint(&context);

    // Pending marker may or may not exist (write could succeed), but
    // capture_response() must not block forever
    let response = bridge.capture_response();
    assert_eq!(
        response.body, "fallback-approved",
        "bridge should fall back to standard prompt when server is unreachable"
    );
}

#[test]
fn t16_bridge_timeout_keeps_pending_marker_for_runtime_retry() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-timeout",
        project_path,
        home_dir.clone(),
        server.endpoint("bridge-token"),
    )
    .with_poll_timeout(Duration::ZERO);

    let mut context = bridge_context(&manifest_path);
    context.gate_id = "gate-timeout".to_string();
    context.prompt_message = "Gate 'gate-timeout': Do you approve?".to_string();

    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let marker = pending_path(&home_dir, "run-timeout", "gate-timeout");
    assert!(
        marker.exists(),
        "pending marker should exist before the decision poll times out"
    );

    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "rejected");
    assert!(
        marker.exists(),
        "pending marker should remain so the runtime-visible checkpoint can be retried"
    );
}

#[test]
fn t17_bridge_invalid_decision_keeps_pending_marker_and_removes_bad_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-invalid-decision",
        project_path,
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );

    let mut context = bridge_context(&manifest_path);
    context.gate_id = "gate-invalid-decision".to_string();
    context.prompt_message = "Gate 'gate-invalid-decision': Do you approve?".to_string();

    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let marker = pending_path(&home_dir, "run-invalid-decision", "gate-invalid-decision");
    let decision = decision_path(&home_dir, "run-invalid-decision", "gate-invalid-decision");
    std::fs::write(&decision, "{not valid json").expect("write malformed decision");

    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "rejected");
    assert!(
        marker.exists(),
        "pending marker should remain after an invalid decision so runtime retry is possible"
    );
    assert!(
        !decision.exists(),
        "invalid decision file should be removed so the next bridge attempt is not poisoned"
    );
}

#[test]
fn t18_bridge_unsupported_decision_version_keeps_pending_marker_and_removes_bad_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home_dir = temp.path().join("home");
    let project_path = temp.path().join("project");
    let manifest_path = project_path.join("artifacts/checkpoint-manifest.json");
    std::fs::create_dir_all(manifest_path.parent().expect("manifest parent"))
        .expect("create manifest parent");
    std::fs::write(&manifest_path, "{}").expect("write manifest");

    let server = StubMutationServer::spawn("bridge-token");
    let bridge = make_bridge(
        "run-unsupported-decision",
        project_path,
        home_dir.clone(),
        server.endpoint("bridge-token"),
    );

    let mut context = bridge_context(&manifest_path);
    context.gate_id = "gate-unsupported-decision".to_string();
    context.prompt_message = "Gate 'gate-unsupported-decision': Do you approve?".to_string();

    bridge.emit_gate_checkpoint(&context);
    server.finish();

    let marker = pending_path(
        &home_dir,
        "run-unsupported-decision",
        "gate-unsupported-decision",
    );
    let decision = decision_path(
        &home_dir,
        "run-unsupported-decision",
        "gate-unsupported-decision",
    );
    write_json_atomic(
        &decision,
        &CheckpointBridgeDecision {
            version: 99,
            run_id: "run-unsupported-decision".to_string(),
            checkpoint_id: "gate-unsupported-decision".to_string(),
            action: "approve".to_string(),
            note: Some("Future protocol".to_string()),
            decided_at: "2026-03-24T12:20:00Z".to_string(),
        },
    )
    .expect("write unsupported decision");

    let response =
        capacitor_core::method_runner::adapters::InteractiveIO::capture_response(&bridge);
    assert_eq!(response.body, "rejected");
    assert!(
        marker.exists(),
        "pending marker should remain after a version error so runtime retry is possible"
    );
    assert!(
        !decision.exists(),
        "unsupported decision file should be removed so the next bridge attempt is not poisoned"
    );
}
