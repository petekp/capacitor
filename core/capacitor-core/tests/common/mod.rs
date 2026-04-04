#![allow(dead_code)]

use std::io::Read;
use std::time::{Duration, Instant};

use capacitor_core::domain::{
    HookEventType, IngestHookEventCommand, MutateRunCommand, RunMutationKind,
};
use capacitor_core::CoreRuntime;

pub mod fixtures;

pub fn valid_hook_event_command(event_type: HookEventType) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2099-02-28T19:00:00Z".to_string(),
        event_type,
        session_id: "session-1".to_string(),
        pid: Some(4242),
        project_path: "/tmp/core-project".to_string(),
        cwd: Some("/tmp/core-project".to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    }
}

pub fn read_http_request(stream: &mut std::net::TcpStream) -> String {
    let mut request = Vec::new();
    let mut headers_end = None;
    let mut content_length = 0usize;
    let deadline = Instant::now() + Duration::from_secs(2);

    loop {
        let mut buf = [0u8; 4096];
        let read = match stream.read(&mut buf) {
            Ok(read) => read,
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::TimedOut =>
            {
                if Instant::now() >= deadline {
                    panic!("timed out reading request: {error}");
                }
                std::thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => panic!("read request: {error}"),
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

    String::from_utf8(request).expect("request should be valid utf-8")
}

pub fn run_kernel_base_cmd(project_path: &str, run_id: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create,
        project_path: project_path.to_string(),
        run_id: run_id.to_string(),
        method_id: None,
        involvement: None,
        checkpoint_kind: None,
        checkpoint_title: None,
        checkpoint_summary: None,
        checkpoint_brief_path: None,
        checkpoint_manifest_path: None,
        checkpoint_media_artifacts: vec![],
        checkpoint_mermaid_sources: vec![],
        capture_url: None,
        checkpoint_id: None,
        capture_request_id: None,
        client_id: None,
        observed_capture_url: None,
        capture_failure_reason: None,
        decision_action: None,
        decision_note: None,
        session_id: None,
        delegation_worker_id: None,
        status_message: None,
        idea_id: None,
        idea_title: None,
        idea_description: None,
        completed_media_artifacts: vec![],
    }
}

pub fn run_kernel_create_cmd(
    project_path: &str,
    run_id: &str,
    method_id: &str,
) -> MutateRunCommand {
    let mut command = run_kernel_base_cmd(project_path, run_id);
    command.method_id = Some(method_id.to_string());
    command
}

pub fn mutate_run(
    runtime: &CoreRuntime,
    mut command: MutateRunCommand,
    kind: RunMutationKind,
) -> capacitor_core::domain::MutationOutcome {
    command.kind = kind;
    runtime
        .mutate_run(command)
        .expect("mutation should not error")
}

pub fn active_checkpoint_id(runtime: &CoreRuntime, run_id: &str) -> String {
    runtime
        .app_snapshot()
        .expect("snapshot")
        .runs
        .iter()
        .find(|run| run.id == run_id)
        .expect("run exists")
        .active_checkpoint
        .as_ref()
        .expect("checkpoint exists")
        .id
        .clone()
}
