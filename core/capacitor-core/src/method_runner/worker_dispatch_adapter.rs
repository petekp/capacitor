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

// ---------------------------------------------------------------------------
// CodexWorkerDispatcher
// ---------------------------------------------------------------------------

/// Real worker dispatcher that delegates to `codex exec`.
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
        // Write preflight record on first call
        write_preflight_if_needed(&request.relay_root, &self.config)
            .map_err(AdapterError::IoError)?;

        // Ensure relay root and adapter dir exist
        std::fs::create_dir_all(&request.relay_root)?;
        let adapter_dir = request.relay_root.join("adapter");
        std::fs::create_dir_all(&adapter_dir)?;

        // 1. Read prompt from prompt_path
        let prompt_bytes = std::fs::read(&request.prompt_path).map_err(|e| {
            AdapterError::IoError(std::io::Error::new(
                e.kind(),
                format!(
                    "failed to read prompt at {}: {}",
                    request.prompt_path.display(),
                    e
                ),
            ))
        })?;

        // 2. Build argv: codex exec --full-auto -o <tmp-output-path> [--add-dir <execution-root>] -
        //
        // The relay root lives under ~/.capacitor/runs/ which is outside
        // the codex sandbox allowlist. We write to $TMPDIR instead, then
        // copy the result back after the process exits.
        let tmpdir = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string());
        let unique_suffix = format!("{}-{:x}", request.worker_id, {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            request.relay_root.hash(&mut h);
            h.finish()
        });
        let tmp_output_dir =
            std::path::PathBuf::from(&tmpdir).join(format!("capacitor-run-{}", unique_suffix));
        std::fs::create_dir_all(&tmp_output_dir)?;
        let tmp_last_message = tmp_output_dir.join("last-message.txt");

        let last_message_path = request.relay_root.join("last-message.txt");
        let codex_path = &self.config.codex_path;
        let args = build_codex_exec_args(&request.relay_root, &tmp_last_message);

        // 3. Build allowlisted env with adapter-owned overrides
        let overrides: Vec<(&str, &str)> = self
            .config
            .env_overrides
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let env = build_allowed_env(&overrides);

        // 4. Spawn with process group isolation and stdin pipe
        let start = Instant::now();

        let mut child = Command::new(codex_path.to_string_lossy().as_ref())
            .args(&args)
            .env_clear()
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .current_dir(&self.config.project_root)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .process_group(0) // new process group for containment
            .spawn()
            .map_err(|e| AdapterError::SpawnFailed(format!("codex exec spawn failed: {}", e)))?;

        // 5. Pipe prompt to stdin and close
        let child_pid = child.id();
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(&prompt_bytes);
            // stdin is dropped (closed) here
        }

        // Take stdout/stderr handles before wait (wait_timeout needs &mut child)
        let _stdout_handle = child.stdout.take();
        let stderr_handle = child.stderr.take();

        // 6. Wait with timeout — TERM→grace→KILL process group escalation
        let timeout = self.config.default_timeout;
        let timed_out;
        let status;

        let mut remaining = timeout;
        loop {
            let wait_slice = remaining.min(WORKER_HEARTBEAT_INTERVAL);
            match child.wait_timeout(wait_slice) {
                Ok(Some(s)) => {
                    timed_out = false;
                    status = s;
                    break;
                }
                Ok(None) => {
                    let elapsed_secs = start.elapsed().as_secs();
                    remaining = timeout.saturating_sub(start.elapsed());
                    if remaining.is_zero() {
                        timed_out = true;
                        let pgid = child_pid as i32; // process_group(0) means pgid = child pid

                        unsafe {
                            libc::killpg(pgid, libc::SIGTERM);
                        }

                        match child.wait_timeout(self.config.kill_grace_period) {
                            Ok(Some(s)) => {
                                status = s;
                            }
                            Ok(None) | Err(_) => {
                                unsafe {
                                    libc::killpg(pgid, libc::SIGKILL);
                                }
                                status = child
                                    .wait()
                                    .unwrap_or_else(|_| std::process::ExitStatus::default());
                            }
                        }
                        break;
                    }

                    report_status_message(
                        self.reporter.as_ref(),
                        RunStatusEventKind::Heartbeat,
                        format!("Waiting for worker ({elapsed_secs}s)"),
                    );
                }
                Err(e) => {
                    return Err(AdapterError::SpawnFailed(format!(
                        "codex exec wait failed: {}",
                        e
                    )));
                }
            }
        }

        let elapsed = start.elapsed();

        // 7. Extract exit code and signal
        let exit_code = status.code().unwrap_or(-1);
        let signal = {
            use std::os::unix::process::ExitStatusExt;
            status.signal()
        };

        // 8. Capture stderr (read what we can from the handle)
        let stderr = stderr_handle
            .map(|mut h| {
                let mut buf = Vec::new();
                let _ = std::io::Read::read_to_end(&mut h, &mut buf);
                String::from_utf8_lossy(&buf).to_string()
            })
            .unwrap_or_default();

        if !stderr.is_empty() {
            let stderr_path = adapter_dir.join("worker-dispatch.stderr.log");
            let _ = std::fs::write(&stderr_path, &stderr);
        }

        // 9. Write metadata
        let metadata = serde_json::json!({
            "argv": args,
            "cwd": self.config.project_root.to_string_lossy(),
            "codex_path": codex_path.to_string_lossy(),
            "pid": child_pid,
            "pgid": child_pid, // process_group(0) → pgid = pid
            "exit_code": exit_code,
            "signal": signal,
            "elapsed_ms": elapsed.as_millis(),
            "timed_out": timed_out,
            "timeout_secs": timeout.as_secs_f64(),
            "prompt_path": request.prompt_path.to_string_lossy(),
            "tmp_last_message_path": tmp_last_message.to_string_lossy(),
            "last_message_path": last_message_path.to_string_lossy(),
            "worker_id": &request.worker_id,
        });
        let _ = std::fs::write(
            adapter_dir.join("worker-dispatch.metadata.json"),
            serde_json::to_string_pretty(&metadata).unwrap_or_default(),
        );

        // 10. Return Timeout error if timed out
        if timed_out {
            // Best-effort cleanup of temp dir even on timeout
            let _ = std::fs::remove_dir_all(&tmp_output_dir);
            return Err(AdapterError::Timeout);
        }

        // 10b. Copy output from $TMPDIR back to relay root
        if tmp_last_message.exists() {
            std::fs::copy(&tmp_last_message, &last_message_path)?;
        }
        // Best-effort cleanup of temp dir
        let _ = std::fs::remove_dir_all(&tmp_output_dir);

        // 11. Enforce -o contract on clean exit: last-message.txt must exist
        if exit_code == 0 && !last_message_path.exists() {
            return Err(AdapterError::ContractViolation(
                "codex exec exited 0 but last-message.txt does not exist (suppressed -o output)"
                    .into(),
            ));
        }

        Ok(WorkerDispatchResult {
            worker_id: request.worker_id.clone(),
            exit_code,
            signal,
            elapsed,
        })
    }
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
