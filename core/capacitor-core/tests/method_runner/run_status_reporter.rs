use std::cell::RefCell;
use std::io::Write;
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::common::read_http_request;
use capacitor_core::domain::{MutateRunCommand, RunMutationKind};
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::events::{recover_events, MethodEventKind};
use capacitor_core::method_runner::executor::execute_run_with_reporter;
use capacitor_core::method_runner::resume::resume_run_with_reporter;
use capacitor_core::method_runner::run_status_reporter::{
    RunStatusEvent, RunStatusEventKind, RunStatusReporter, RuntimeRunStatusReporter,
};
use capacitor_core::method_runner::state::RunStatus;
use capacitor_core::method_runner::storage::MethodRunPaths;
use capacitor_core::runtime::service::RuntimeServiceEndpoint;

#[derive(Debug, Clone)]
struct CapturedRequest {
    request_line: String,
    body: String,
}

struct StubMutationServer {
    requests: Receiver<CapturedRequest>,
    handle: Option<JoinHandle<()>>,
    port: u16,
}

impl StubMutationServer {
    fn spawn(auth_token: &str, expected_requests: usize) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind stub mutation server");
        listener
            .set_nonblocking(true)
            .expect("set nonblocking listener");

        let port = listener.local_addr().expect("listener address").port();
        let expected_auth = format!("Authorization: Bearer {auth_token}");
        let (tx, requests) = mpsc::channel();

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
                            .expect("request line")
                            .trim_end_matches('\r')
                            .to_string();
                        tx.send(CapturedRequest {
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
                            .expect("write response");

                        served_requests += 1;
                        if served_requests >= expected_requests {
                            break;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
                            panic!("timed out waiting for reporter request");
                        }
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("accept request: {error}"),
                }
            }
        });

        Self {
            requests,
            handle: Some(handle),
            port,
        }
    }

    fn endpoint(&self, auth_token: &str) -> RuntimeServiceEndpoint {
        RuntimeServiceEndpoint::localhost(self.port, auth_token)
    }

    fn captured_request(&self) -> CapturedRequest {
        self.requests
            .recv_timeout(Duration::from_secs(2))
            .expect("receive captured request")
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

#[derive(Default)]
struct SpyRunStatusReporter {
    events: RefCell<Vec<RunStatusEvent>>,
}

impl SpyRunStatusReporter {
    fn events(&self) -> Vec<RunStatusEvent> {
        self.events.borrow().clone()
    }
}

impl RunStatusReporter for SpyRunStatusReporter {
    fn report(&self, event: RunStatusEvent) {
        self.events.borrow_mut().push(event);
    }
}

struct FailingReporter;

impl RunStatusReporter for FailingReporter {
    fn report(&self, _event: RunStatusEvent) {
        panic!("reporter panic");
    }
}

fn two_phase_method_yaml() -> String {
    r#"schema_version: "1"
method:
  id: reporter-test
  version: "2026-03-26"
  title: Reporter Test
  defaults:
    max_attempts: 1
    completion_policy: all_complete
  outputs:
    final:
      from: phase-2.step-2.result
      required: true
  phases:
    - id: phase-1
      title: Discovery
      execution: serial
      steps:
        - id: step-1
          title: First pass
          action: dispatch
          outputs:
            result:
              path: artifacts/first.md
              type: markdown
          dispatch:
            instructions: Do the first thing.
    - id: phase-2
      title: Implementation
      execution: serial
      steps:
        - id: step-2
          title: Final pass
          action: dispatch
          outputs:
            result:
              path: artifacts/final.md
              type: markdown
          dispatch:
            instructions: Do the final thing.
"#
    .to_string()
}

fn gated_method_yaml() -> String {
    r#"schema_version: "1"
method:
  id: reporter-gated-test
  version: "2026-03-26"
  title: Reporter Gated Test
  defaults:
    max_attempts: 1
    completion_policy: all_complete
  phases:
    - id: phase-1
      title: Discovery
      execution: serial
      gate:
        id: discovery-gate
        type: approval
      steps:
        - id: step-1
          title: First pass
          action: dispatch
          outputs:
            result:
              path: artifacts/first.md
              type: markdown
          dispatch:
            instructions: Do the first thing.
"#
    .to_string()
}

fn two_phase_gated_method_yaml() -> String {
    r#"schema_version: "1"
method:
  id: reporter-two-phase-gated-test
  version: "2026-03-26"
  title: Reporter Two Phase Gated Test
  defaults:
    max_attempts: 1
    completion_policy: all_complete
  phases:
    - id: phase-1
      title: Discovery
      execution: serial
      gate:
        id: discovery-gate
        type: approval
      steps:
        - id: step-1
          title: First pass
          action: dispatch
          outputs:
            result:
              path: artifacts/first.md
              type: markdown
          dispatch:
            instructions: Do the first thing.
    - id: phase-2
      title: Implementation
      execution: serial
      steps:
        - id: step-2
          title: Final pass
          action: dispatch
          outputs:
            result:
              path: artifacts/final.md
              type: markdown
          dispatch:
            instructions: Do the final thing.
"#
    .to_string()
}

fn write_definition(temp: &tempfile::TempDir, yaml: &str) -> DefinitionSource {
    let definition_path = temp.path().join("method.yaml");
    std::fs::write(&definition_path, yaml).expect("write definition");
    DefinitionSource {
        definition_path,
        execution_root: temp.path().join("run"),
    }
}

#[test]
fn execute_run_reports_start_heartbeats_and_complete_in_order() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_method_yaml());
    let reporter = SpyRunStatusReporter::default();
    let interactive = FakeInteractiveIO::new("approved");

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &interactive,
        &reporter,
    )
    .expect("execute run");

    let events = reporter.events();
    assert_eq!(
        events.first().map(|event| event.kind),
        Some(RunStatusEventKind::Start)
    );
    assert!(
        events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Heartbeat),
        "expected at least one heartbeat event: {events:?}"
    );
    assert!(
        events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::AdvancePhase),
        "expected an advance phase event: {events:?}"
    );
    assert_eq!(
        events.last().map(|event| event.kind),
        Some(RunStatusEventKind::Complete)
    );
}

#[test]
fn execute_run_reports_spec_status_messages() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &gated_method_yaml());
    let reporter = SpyRunStatusReporter::default();
    let interactive = FakeInteractiveIO::new("approved");

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &interactive,
        &reporter,
    )
    .expect("execute run");

    let reporter_events = reporter.events();
    let heartbeat_messages: Vec<&str> = reporter_events
        .iter()
        .filter(|event| event.kind == RunStatusEventKind::Heartbeat)
        .filter_map(|event| event.status_message.as_deref())
        .collect();

    assert!(
        heartbeat_messages.contains(&"Dispatching Codex"),
        "expected Dispatching Codex heartbeat: {heartbeat_messages:?}"
    );
    assert!(
        heartbeat_messages.contains(&"Waiting for checkpoint"),
        "expected Waiting for checkpoint heartbeat: {heartbeat_messages:?}"
    );
}

#[test]
fn rejected_gate_reports_pause_instead_of_fail() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &gated_method_yaml());
    let reporter = SpyRunStatusReporter::default();
    let interactive = FakeInteractiveIO::new("rejected");

    let state = execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &interactive,
        &reporter,
    )
    .expect("rejected gate should produce a controlled blocked handoff");
    assert_eq!(state.status, RunStatus::Blocked);

    let paths = MethodRunPaths::new(&source.execution_root);
    let method_events = recover_events(&paths.events_log()).expect("recover events");
    assert_eq!(
        method_events.last().map(|event| event.kind),
        Some(MethodEventKind::RunBlocked),
        "blocked gate should persist a run-blocked lifecycle event"
    );

    let events = reporter.events();
    assert!(
        events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Pause),
        "expected rejected gate to pause the runtime run: {events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Fail),
        "rejected gate should not report a terminal runtime failure: {events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Complete),
        "rejected gate should not report runtime completion: {events:?}"
    );
}

#[test]
fn resumed_rejected_gate_reports_pause_instead_of_fail() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &gated_method_yaml());

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed complete gated run");

    let paths = MethodRunPaths::new(&source.execution_root);
    let events_path = paths.events_log();
    let events = recover_events(&events_path).expect("recover events");
    let gate_index = events
        .iter()
        .position(|event| event.kind == MethodEventKind::GateEvaluated)
        .expect("expected gate evaluation event");

    {
        let mut file = std::fs::File::create(&events_path).expect("rewrite events log");
        for event in &events[..gate_index] {
            writeln!(
                file,
                "{}",
                serde_json::to_string(event).expect("serialize event")
            )
            .expect("write truncated event");
        }
    }

    let reporter = SpyRunStatusReporter::default();
    let state = resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("rejected"),
        &reporter,
    )
    .expect("rejected resumed gate should produce a controlled blocked handoff");
    assert_eq!(state.status, RunStatus::Blocked);

    let method_events = recover_events(&events_path).expect("recover resumed events");
    assert_eq!(
        method_events.last().map(|event| event.kind),
        Some(MethodEventKind::RunBlocked),
        "resumed rejected gate should persist a run-blocked lifecycle event"
    );

    let events = reporter.events();
    assert!(
        events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Pause),
        "expected rejected resumed gate to pause the runtime run: {events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|event| event.kind == RunStatusEventKind::Fail),
        "rejected resumed gate should not report a terminal runtime failure: {events:?}"
    );
}

#[test]
fn resume_blocked_gate_reports_resume_before_advancing_phase() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_gated_method_yaml());

    let blocked_state = execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("rejected"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed blocked gated run");
    assert_eq!(blocked_state.status, RunStatus::Blocked);

    let reporter = SpyRunStatusReporter::default();
    let resumed_state = resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &reporter,
    )
    .expect("resume blocked run");
    assert_eq!(resumed_state.status, RunStatus::Completed);

    let events = reporter.events();
    let resume_index = events
        .iter()
        .position(|event| event.kind == RunStatusEventKind::Resume)
        .expect("expected runtime resume event");
    let advance_index = events
        .iter()
        .position(|event| event.kind == RunStatusEventKind::AdvancePhase)
        .expect("expected runtime advance event");
    assert!(
        resume_index < advance_index,
        "runtime resume must precede advance: {events:?}"
    );

    let paths = MethodRunPaths::new(&source.execution_root);
    let method_events = recover_events(&paths.events_log()).expect("recover events");
    let phase_blocked_index = method_events
        .iter()
        .position(|event| event.kind == MethodEventKind::PhaseBlocked)
        .expect("expected phase blocked event");
    let phase_restarted_index = method_events
        .iter()
        .enumerate()
        .skip(phase_blocked_index + 1)
        .find(|(_, event)| {
            event.kind == MethodEventKind::PhaseStarted
                && event.phase_id.as_deref() == Some("phase-1")
        })
        .map(|(index, _)| index)
        .expect("expected blocked phase to restart before completion");
    let phase_completed_index = method_events
        .iter()
        .enumerate()
        .skip(phase_restarted_index + 1)
        .find(|(_, event)| {
            event.kind == MethodEventKind::PhaseCompleted
                && event.phase_id.as_deref() == Some("phase-1")
        })
        .map(|(index, _)| index)
        .expect("expected restarted phase to complete");
    assert!(
        phase_restarted_index < phase_completed_index,
        "blocked phase must restart before completing"
    );
}

#[test]
fn resume_blocked_gate_reexecutes_phase_steps_before_checkpoint_reapproval() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_gated_method_yaml());

    let blocked_state = execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("rejected"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed blocked gated run");
    assert_eq!(blocked_state.status, RunStatus::Blocked);

    let resumed_state = resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("resume blocked run");
    assert_eq!(resumed_state.status, RunStatus::Completed);
    assert_eq!(
        resumed_state
            .phases
            .get("phase-1")
            .and_then(|phase| phase.steps.get("step-1"))
            .map(|step| step.current_attempt),
        Some(2),
        "request-changes resume should create a new step attempt"
    );

    let paths = MethodRunPaths::new(&source.execution_root);
    let method_events = recover_events(&paths.events_log()).expect("recover events");
    let phase_blocked_index = method_events
        .iter()
        .position(|event| event.kind == MethodEventKind::PhaseBlocked)
        .expect("expected phase blocked event");
    let phase_restarted_index = method_events
        .iter()
        .enumerate()
        .skip(phase_blocked_index + 1)
        .find(|(_, event)| {
            event.kind == MethodEventKind::PhaseStarted
                && event.phase_id.as_deref() == Some("phase-1")
        })
        .map(|(index, _)| index)
        .expect("expected blocked phase to restart");
    let second_gate_index = method_events
        .iter()
        .enumerate()
        .skip(phase_restarted_index + 1)
        .find(|(_, event)| {
            event.kind == MethodEventKind::GateEvaluated
                && event.phase_id.as_deref() == Some("phase-1")
        })
        .map(|(index, _)| index)
        .expect("expected gate to be re-evaluated after restart");

    let worker_dispatch_attempts: Vec<u32> = method_events
        .iter()
        .filter(|event| {
            event.kind == MethodEventKind::WorkerDispatched
                && event.phase_id.as_deref() == Some("phase-1")
                && event.step_id.as_deref() == Some("step-1")
        })
        .filter_map(|event| event.attempt)
        .collect();
    assert_eq!(
        worker_dispatch_attempts,
        vec![1, 2],
        "request-changes resume should preserve the old attempt and run a fresh one"
    );

    let second_dispatch_index = method_events
        .iter()
        .enumerate()
        .find(|(_, event)| {
            event.kind == MethodEventKind::WorkerDispatched
                && event.phase_id.as_deref() == Some("phase-1")
                && event.step_id.as_deref() == Some("step-1")
                && event.attempt == Some(2)
        })
        .map(|(index, _)| index)
        .expect("expected second worker dispatch");
    assert!(
        phase_restarted_index < second_dispatch_index && second_dispatch_index < second_gate_index,
        "phase restart must re-run worker before re-evaluating the gate"
    );
}

#[test]
fn request_changes_can_repeat_before_final_approval() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_gated_method_yaml());

    let first_blocked_state = execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("rejected"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed first blocked gated run");
    assert_eq!(first_blocked_state.status, RunStatus::Blocked);

    let second_blocked_state = resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("rejected"),
        &SpyRunStatusReporter::default(),
    )
    .expect("second request-changes round should remain a controlled block");
    assert_eq!(second_blocked_state.status, RunStatus::Blocked);

    let completed_state = resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("third round should approve and complete");
    assert_eq!(completed_state.status, RunStatus::Completed);
    assert_eq!(
        completed_state
            .phases
            .get("phase-1")
            .and_then(|phase| phase.steps.get("step-1"))
            .map(|step| step.current_attempt),
        Some(3),
        "each request-changes round should preserve the previous attempt and create the next one"
    );

    let paths = MethodRunPaths::new(&source.execution_root);
    let method_events = recover_events(&paths.events_log()).expect("recover events");
    let worker_dispatch_attempts: Vec<u32> = method_events
        .iter()
        .filter(|event| {
            event.kind == MethodEventKind::WorkerDispatched
                && event.phase_id.as_deref() == Some("phase-1")
                && event.step_id.as_deref() == Some("step-1")
        })
        .filter_map(|event| event.attempt)
        .collect();
    assert_eq!(worker_dispatch_attempts, vec![1, 2, 3]);
    assert_eq!(
        method_events
            .iter()
            .filter(|event| {
                event.kind == MethodEventKind::PhaseBlocked
                    && event.phase_id.as_deref() == Some("phase-1")
            })
            .count(),
        2,
        "two request-changes decisions should produce two blocked phase lifecycles"
    );
}

#[test]
fn resume_run_emits_immediate_recovered_phase_heartbeat() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_method_yaml());

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed complete run");

    let paths = MethodRunPaths::new(&source.execution_root);
    let events_path = paths.events_log();
    let events = recover_events(&events_path).expect("recover events");
    let handoff_index = events
        .iter()
        .position(|event| event.kind == MethodEventKind::HandoffIngested)
        .expect("expected handoff ingested event");

    {
        let mut file = std::fs::File::create(&events_path).expect("rewrite events log");
        for event in &events[..handoff_index] {
            writeln!(
                file,
                "{}",
                serde_json::to_string(event).expect("serialize event")
            )
            .expect("write truncated event");
        }
    }

    let reporter = SpyRunStatusReporter::default();
    resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &reporter,
    )
    .expect("resume run");

    let events = reporter.events();
    assert_eq!(
        events.first().map(|event| event.kind),
        Some(RunStatusEventKind::Heartbeat)
    );
    assert_eq!(
        events[0].status_message.as_deref(),
        Some("Phase 'Discovery' started")
    );
    assert_eq!(
        events.last().map(|event| event.kind),
        Some(RunStatusEventKind::Complete)
    );
}

#[test]
fn resume_run_on_created_run_reports_start_before_recovered_phase_heartbeat() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &gated_method_yaml());

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed complete run");

    let paths = MethodRunPaths::new(&source.execution_root);
    let events_path = paths.events_log();
    let events = recover_events(&events_path).expect("recover events");

    {
        let mut file = std::fs::File::create(&events_path).expect("rewrite events log");
        writeln!(
            file,
            "{}",
            serde_json::to_string(&events[0]).expect("serialize event")
        )
        .expect("write definition frozen event");
    }

    let reporter = SpyRunStatusReporter::default();
    resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &reporter,
    )
    .expect("resume run");

    let events = reporter.events();
    assert_eq!(
        events.first().map(|event| event.kind),
        Some(RunStatusEventKind::Start)
    );
    assert_eq!(
        events
            .first()
            .and_then(|event| event.status_message.as_deref()),
        Some("Run started")
    );
    assert_eq!(
        events.get(1).map(|event| event.kind),
        Some(RunStatusEventKind::Heartbeat)
    );
    assert_eq!(
        events
            .get(1)
            .and_then(|event| event.status_message.as_deref()),
        Some("Phase 'Discovery' started")
    );

    let heartbeat_messages: Vec<&str> = events
        .iter()
        .filter(|event| event.kind == RunStatusEventKind::Heartbeat)
        .filter_map(|event| event.status_message.as_deref())
        .collect();
    assert!(
        heartbeat_messages.contains(&"Dispatching Codex"),
        "expected Dispatching Codex heartbeat: {heartbeat_messages:?}"
    );
    assert!(
        heartbeat_messages.contains(&"Waiting for checkpoint"),
        "expected Waiting for checkpoint heartbeat: {heartbeat_messages:?}"
    );
    assert_eq!(
        events.last().map(|event| event.kind),
        Some(RunStatusEventKind::Complete)
    );
}

#[test]
fn resume_run_reports_complete_when_reconcile_only_path_finalizes_run() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_method_yaml());

    execute_run_with_reporter(
        &source,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &SpyRunStatusReporter::default(),
    )
    .expect("seed complete run");

    let paths = MethodRunPaths::new(&source.execution_root);
    let events_path = paths.events_log();
    let events = recover_events(&events_path).expect("recover events");
    assert_eq!(
        events.last().map(|event| event.kind),
        Some(MethodEventKind::RunCompleted)
    );

    {
        let mut file = std::fs::File::create(&events_path).expect("rewrite events log");
        for event in &events[..events.len() - 1] {
            writeln!(
                file,
                "{}",
                serde_json::to_string(event).expect("serialize event")
            )
            .expect("write truncated event");
        }
    }

    let reporter = SpyRunStatusReporter::default();
    resume_run_with_reporter(
        &source.execution_root,
        &FakePromptBuilder,
        &FakeWorkerDispatcher,
        &FakeInteractiveIO::new("approved"),
        &reporter,
    )
    .expect("resume run");

    assert_eq!(
        reporter.events(),
        vec![RunStatusEvent::new(RunStatusEventKind::Complete, None)]
    );
}

#[test]
fn reporter_panics_do_not_abort_run_execution() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = write_definition(&temp, &two_phase_method_yaml());
    let interactive = FakeInteractiveIO::new("approved");

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        execute_run_with_reporter(
            &source,
            &FakePromptBuilder,
            &FakeWorkerDispatcher,
            &interactive,
            &FailingReporter,
        )
    }));

    assert!(result.is_ok(), "execute_run should catch reporter panics");
    assert!(result.unwrap().is_ok(), "run should still succeed");
}

#[test]
fn runtime_reporter_posts_mutate_commands_with_expected_mapping() {
    let auth_token = "secret-token";
    let server = StubMutationServer::spawn(auth_token, 5);
    let reporter = RuntimeRunStatusReporter::new(
        server.endpoint(auth_token),
        PathBuf::from("/tmp/project"),
        "run-123",
    );

    reporter.report(RunStatusEvent::new(
        RunStatusEventKind::Start,
        Some("Run started".to_string()),
    ));
    reporter.report(RunStatusEvent::new(
        RunStatusEventKind::Heartbeat,
        Some("Composing prompt".to_string()),
    ));
    reporter.report(RunStatusEvent::new(
        RunStatusEventKind::Pause,
        Some("Run blocked: gate rejected".to_string()),
    ));
    reporter.report(RunStatusEvent::new(
        RunStatusEventKind::Resume,
        Some("Run resumed".to_string()),
    ));
    reporter.report(RunStatusEvent::new(RunStatusEventKind::Complete, None));

    let request_a = server.captured_request();
    let request_b = server.captured_request();
    let request_c = server.captured_request();
    let request_d = server.captured_request();
    let request_e = server.captured_request();

    assert_eq!(request_a.request_line, "POST /runtime/run/mutate HTTP/1.1");
    assert_eq!(request_b.request_line, "POST /runtime/run/mutate HTTP/1.1");
    assert_eq!(request_c.request_line, "POST /runtime/run/mutate HTTP/1.1");
    assert_eq!(request_d.request_line, "POST /runtime/run/mutate HTTP/1.1");
    assert_eq!(request_e.request_line, "POST /runtime/run/mutate HTTP/1.1");

    let command_a: MutateRunCommand =
        serde_json::from_str(&request_a.body).expect("parse start command");
    let command_b: MutateRunCommand =
        serde_json::from_str(&request_b.body).expect("parse heartbeat command");
    let command_c: MutateRunCommand =
        serde_json::from_str(&request_c.body).expect("parse pause command");
    let command_d: MutateRunCommand =
        serde_json::from_str(&request_d.body).expect("parse resume command");
    let command_e: MutateRunCommand =
        serde_json::from_str(&request_e.body).expect("parse complete command");

    assert_eq!(
        command_a.kind,
        RunMutationKind::Start {
            status_message: Some("Run started".to_string()),
        }
    );
    assert_eq!(
        command_b.kind,
        RunMutationKind::Heartbeat {
            status_message: Some("Composing prompt".to_string()),
        }
    );
    assert_eq!(
        command_c.kind,
        RunMutationKind::Pause {
            status_message: Some("Run blocked: gate rejected".to_string()),
        }
    );
    assert_eq!(
        command_d.kind,
        RunMutationKind::Resume {
            status_message: Some("Run resumed".to_string()),
        }
    );
    assert_eq!(
        command_e.kind,
        RunMutationKind::Complete {
            status_message: None,
        }
    );
}
