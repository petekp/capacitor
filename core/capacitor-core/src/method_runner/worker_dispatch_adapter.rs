//! Real CodexWorkerDispatcher — wraps `codex exec` as a subprocess.
//!
//! This adapter reads the prompt from `prompt_path`, spawns `codex exec`
//! with stdin piping, captures exit code / signal / elapsed, writes metadata,
//! and enforces the `-o` output contract.

use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use wait_timeout::ChildExt;

use crate::method_runner::adapter_config::{
    build_allowed_env, write_preflight_if_needed, AdapterConfig,
};
use crate::method_runner::adapters::{
    AdapterError, WorkerDispatchRequest, WorkerDispatchResult, WorkerDispatcher,
};
use crate::method_runner::run_status_reporter::{
    report_status_message, NoopRunStatusReporter, RunStatusEventKind, RunStatusReporter,
};

const WORKER_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

struct DispatchWorkspace {
    adapter_dir: std::path::PathBuf,
    tmp_output_dir: std::path::PathBuf,
    tmp_last_message: std::path::PathBuf,
    last_message_path: std::path::PathBuf,
}

struct SpawnedDispatch {
    child: std::process::Child,
    child_pid: u32,
    stderr_handle: Option<std::process::ChildStderr>,
    start: Instant,
}

struct TimedStatus {
    status: std::process::ExitStatus,
    timed_out: bool,
}

struct DispatchOutcome {
    exit_code: i32,
    signal: Option<i32>,
    elapsed: Duration,
    timed_out: bool,
    stderr: String,
}

fn execution_root_from_relay_root(relay_root: &Path) -> Option<std::path::PathBuf> {
    relay_root.ancestors().find_map(|ancestor| {
        if ancestor.file_name().and_then(|name| name.to_str()) == Some(".method") {
            ancestor.parent().map(|parent| parent.to_path_buf())
        } else {
            None
        }
    })
}

fn build_codex_exec_args(relay_root: &Path, tmp_last_message: &Path) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "exec".into(),
        "--full-auto".into(),
        "-o".into(),
        tmp_last_message.to_string_lossy().into_owned(),
    ];

    if let Some(execution_root) = execution_root_from_relay_root(relay_root) {
        args.push("--add-dir".into());
        args.push(execution_root.to_string_lossy().into_owned());
    }

    args.push("-".into());
    args
}

pub struct CodexWorkerDispatcher {
    config: AdapterConfig,
    reporter: Arc<dyn RunStatusReporter + Send + Sync>,
}

impl CodexWorkerDispatcher {
    pub fn new(config: AdapterConfig) -> Self {
        Self::with_reporter(config, Arc::new(NoopRunStatusReporter))
    }

    pub fn with_reporter(
        config: AdapterConfig,
        reporter: Arc<dyn RunStatusReporter + Send + Sync>,
    ) -> Self {
        Self { config, reporter }
    }
}

impl WorkerDispatcher for CodexWorkerDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError> {
        write_preflight_if_needed(&request.relay_root, &self.config)
            .map_err(AdapterError::IoError)?;
        let workspace = prepare_dispatch_workspace(request)?;
        let prompt_bytes = read_prompt_bytes(request)?;
        let args = build_codex_exec_args(&request.relay_root, &workspace.tmp_last_message);
        let env = build_dispatch_env(&self.config);
        let spawned = spawn_dispatch_process(&self.config, &args, &env, &prompt_bytes)?;
        let child_pid = spawned.child_pid;
        let outcome = wait_for_dispatch(
            spawned,
            self.config.default_timeout,
            self.config.kill_grace_period,
            self.reporter.as_ref(),
        )?;
        write_dispatch_stderr(&workspace, &outcome.stderr);
        write_dispatch_metadata(
            &workspace,
            &self.config,
            request,
            &args,
            child_pid,
            &outcome,
        );
        finalize_dispatch_output(&workspace, &outcome)?;

        Ok(WorkerDispatchResult {
            worker_id: request.worker_id.clone(),
            exit_code: outcome.exit_code,
            signal: outcome.signal,
            elapsed: outcome.elapsed,
        })
    }
}

fn prepare_dispatch_workspace(
    request: &WorkerDispatchRequest,
) -> Result<DispatchWorkspace, AdapterError> {
    std::fs::create_dir_all(&request.relay_root)?;
    let adapter_dir = request.relay_root.join("adapter");
    std::fs::create_dir_all(&adapter_dir)?;
    let tmpdir = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string());
    let tmp_output_dir = std::path::PathBuf::from(tmpdir)
        .join(format!("capacitor-run-{}", unique_worker_suffix(request)));
    std::fs::create_dir_all(&tmp_output_dir)?;
    Ok(DispatchWorkspace {
        adapter_dir,
        tmp_last_message: tmp_output_dir.join("last-message.txt"),
        last_message_path: request.relay_root.join("last-message.txt"),
        tmp_output_dir,
    })
}

fn unique_worker_suffix(request: &WorkerDispatchRequest) -> String {
    use std::hash::{Hash, Hasher};

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    request.relay_root.hash(&mut hasher);
    format!("{}-{:x}", request.worker_id, hasher.finish())
}

fn read_prompt_bytes(request: &WorkerDispatchRequest) -> Result<Vec<u8>, AdapterError> {
    std::fs::read(&request.prompt_path).map_err(|error| {
        AdapterError::IoError(std::io::Error::new(
            error.kind(),
            format!(
                "failed to read prompt at {}: {}",
                request.prompt_path.display(),
                error
            ),
        ))
    })
}

fn build_dispatch_env(config: &AdapterConfig) -> Vec<(String, String)> {
    let overrides: Vec<(&str, &str)> = config
        .env_overrides
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    build_allowed_env(&overrides)
}

fn spawn_dispatch_process(
    config: &AdapterConfig,
    args: &[String],
    env: &[(String, String)],
    prompt_bytes: &[u8],
) -> Result<SpawnedDispatch, AdapterError> {
    let start = Instant::now();
    let mut child = Command::new(config.codex_path.to_string_lossy().as_ref())
        .args(args)
        .env_clear()
        .envs(
            env.iter()
                .map(|(key, value)| (key.as_str(), value.as_str())),
        )
        .current_dir(&config.project_root)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|error| {
            AdapterError::SpawnFailed(format!("codex exec spawn failed: {}", error))
        })?;
    let child_pid = child.id();
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt_bytes);
    }
    let _stdout_handle = child.stdout.take();
    let stderr_handle = child.stderr.take();
    Ok(SpawnedDispatch {
        child,
        child_pid,
        stderr_handle,
        start,
    })
}

fn wait_for_dispatch(
    mut spawned: SpawnedDispatch,
    timeout: Duration,
    kill_grace_period: Duration,
    reporter: &dyn RunStatusReporter,
) -> Result<DispatchOutcome, AdapterError> {
    let status = wait_for_dispatch_status(
        &mut spawned.child,
        spawned.child_pid,
        spawned.start,
        timeout,
        kill_grace_period,
        reporter,
    )?;
    let elapsed = spawned.start.elapsed();
    let timed_out = status.timed_out;
    let exit_code = status.status.code().unwrap_or(-1);
    let signal = {
        use std::os::unix::process::ExitStatusExt;
        status.status.signal()
    };
    Ok(DispatchOutcome {
        exit_code,
        signal,
        elapsed,
        timed_out,
        stderr: read_dispatch_stderr(spawned.stderr_handle),
    })
}

fn wait_for_dispatch_status(
    child: &mut std::process::Child,
    child_pid: u32,
    start: Instant,
    timeout: Duration,
    kill_grace_period: Duration,
    reporter: &dyn RunStatusReporter,
) -> Result<TimedStatus, AdapterError> {
    let mut remaining = timeout;
    loop {
        let wait_slice = remaining.min(WORKER_HEARTBEAT_INTERVAL);
        match child.wait_timeout(wait_slice) {
            Ok(Some(status)) => {
                return Ok(TimedStatus {
                    status,
                    timed_out: false,
                });
            }
            Ok(None) => {
                remaining = timeout.saturating_sub(start.elapsed());
                if remaining.is_zero() {
                    return wait_for_timed_out_dispatch(child, child_pid, kill_grace_period);
                }
                report_waiting_for_worker(start, reporter);
            }
            Err(error) => {
                return Err(AdapterError::SpawnFailed(format!(
                    "codex exec wait failed: {}",
                    error
                )));
            }
        }
    }
}

fn wait_for_timed_out_dispatch(
    child: &mut std::process::Child,
    child_pid: u32,
    kill_grace_period: Duration,
) -> Result<TimedStatus, AdapterError> {
    let pgid = child_pid as i32;
    signal_process_group(pgid, libc::SIGTERM);
    let status = match child.wait_timeout(kill_grace_period) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            signal_process_group(pgid, libc::SIGKILL);
            child
                .wait()
                .unwrap_or_else(|_| std::process::ExitStatus::default())
        }
    };
    Ok(TimedStatus {
        status,
        timed_out: true,
    })
}

fn signal_process_group(pgid: i32, signal: i32) {
    unsafe {
        libc::killpg(pgid, signal);
    }
}

fn report_waiting_for_worker(start: Instant, reporter: &dyn RunStatusReporter) {
    let elapsed_secs = start.elapsed().as_secs();
    report_status_message(
        reporter,
        RunStatusEventKind::Heartbeat,
        format!("Waiting for worker ({elapsed_secs}s)"),
    );
}

fn read_dispatch_stderr(stderr_handle: Option<std::process::ChildStderr>) -> String {
    stderr_handle
        .map(|mut handle| {
            let mut buffer = Vec::new();
            let _ = std::io::Read::read_to_end(&mut handle, &mut buffer);
            String::from_utf8_lossy(&buffer).to_string()
        })
        .unwrap_or_default()
}

fn write_dispatch_stderr(workspace: &DispatchWorkspace, stderr: &str) {
    if stderr.is_empty() {
        return;
    }
    let stderr_path = workspace.adapter_dir.join("worker-dispatch.stderr.log");
    let _ = std::fs::write(stderr_path, stderr);
}

fn write_dispatch_metadata(
    workspace: &DispatchWorkspace,
    config: &AdapterConfig,
    request: &WorkerDispatchRequest,
    args: &[String],
    child_pid: u32,
    outcome: &DispatchOutcome,
) {
    let metadata = serde_json::json!({
        "argv": args,
        "cwd": config.project_root.to_string_lossy(),
        "codex_path": config.codex_path.to_string_lossy(),
        "pid": child_pid,
        "pgid": child_pid,
        "exit_code": outcome.exit_code,
        "signal": outcome.signal,
        "elapsed_ms": outcome.elapsed.as_millis(),
        "timed_out": outcome.timed_out,
        "timeout_secs": config.default_timeout.as_secs_f64(),
        "prompt_path": request.prompt_path.to_string_lossy(),
        "tmp_last_message_path": workspace.tmp_last_message.to_string_lossy(),
        "last_message_path": workspace.last_message_path.to_string_lossy(),
        "worker_id": &request.worker_id,
    });
    let _ = std::fs::write(
        workspace.adapter_dir.join("worker-dispatch.metadata.json"),
        serde_json::to_string_pretty(&metadata).unwrap_or_default(),
    );
}

fn finalize_dispatch_output(
    workspace: &DispatchWorkspace,
    outcome: &DispatchOutcome,
) -> Result<(), AdapterError> {
    if outcome.timed_out {
        let _ = std::fs::remove_dir_all(&workspace.tmp_output_dir);
        return Err(AdapterError::Timeout);
    }
    if workspace.tmp_last_message.exists() {
        std::fs::copy(&workspace.tmp_last_message, &workspace.last_message_path)?;
    }
    let _ = std::fs::remove_dir_all(&workspace.tmp_output_dir);
    if outcome.exit_code == 0 && !workspace.last_message_path.exists() {
        return Err(AdapterError::ContractViolation(
            "codex exec exited 0 but last-message.txt does not exist (suppressed -o output)".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_codex_args_includes_add_dir_when_execution_root_is_available() {
        let temp = tempfile::tempdir().expect("tempdir");
        let execution_root = temp.path();
        let relay_root = execution_root
            .join(".method")
            .join("steps")
            .join("phase-a")
            .join("step-a")
            .join("attempts")
            .join("001")
            .join("relay")
            .join("workers")
            .join("worker-a");
        std::fs::create_dir_all(&relay_root).expect("relay root");

        let args = build_codex_exec_args(&relay_root, Path::new("/tmp/last-message.txt"));

        let add_dir_index = args
            .iter()
            .position(|arg| arg == "--add-dir")
            .expect("expected --add-dir to be present");

        assert_eq!(
            args.get(add_dir_index + 1).map(String::as_str),
            Some(execution_root.to_string_lossy().as_ref())
        );
        assert_eq!(args.last().map(String::as_str), Some("-"));
    }

    #[test]
    fn test_build_codex_args_omits_add_dir_when_execution_root_is_unavailable() {
        let temp = tempfile::tempdir().expect("tempdir");
        let relay_root = temp.path().join("relay-root");
        std::fs::create_dir_all(&relay_root).expect("relay root");

        let args = build_codex_exec_args(&relay_root, Path::new("/tmp/last-message.txt"));

        assert!(
            !args.iter().any(|arg| arg == "--add-dir"),
            "--add-dir should be omitted when execution root cannot be derived"
        );
        assert_eq!(args.last().map(String::as_str), Some("-"));
    }
}
