//! Filesystem layout, locking, and persistence for the method runner.
//!
//! `MethodRunPaths` owns the canonical `.method/` directory layout.
//! `RunLock` provides advisory file-based locking with stale lock detection.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Canonical path builder
// ---------------------------------------------------------------------------

/// Owns all canonical paths within a `.method/` run directory.
/// This is the single source of truth for filesystem layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MethodRunPaths {
    root: PathBuf,
}

impl MethodRunPaths {
    /// Creates a path builder rooted at the execution directory that will own
    /// the `.method/` run tree.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Returns the execution root that contains the `.method/` directory.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Returns the root `.method/` directory for this run.
    pub fn method_root(&self) -> PathBuf {
        self.root.join(".method")
    }

    /// Returns `.method/definition.snapshot.yaml`.
    pub fn definition_snapshot(&self) -> PathBuf {
        self.method_root().join("definition.snapshot.yaml")
    }

    /// Returns `.method/events.ndjson`.
    pub fn events_log(&self) -> PathBuf {
        self.method_root().join("events.ndjson")
    }

    /// Returns `.method/state.json`.
    pub fn state_json(&self) -> PathBuf {
        self.method_root().join("state.json")
    }

    /// Returns `.method/locks/run.lock`.
    pub fn lock_file(&self) -> PathBuf {
        self.method_root().join("locks").join("run.lock")
    }

    /// Returns `.method/steps/<phase>/<step>/`.
    pub fn step_dir(&self, phase_id: impl AsRef<str>, step_id: impl AsRef<str>) -> PathBuf {
        self.method_root()
            .join("steps")
            .join(phase_id.as_ref())
            .join(step_id.as_ref())
    }

    /// Returns `.method/steps/<phase>/<step>/attempts/<n>/`.
    pub fn attempt_dir(
        &self,
        phase_id: impl AsRef<str>,
        step_id: impl AsRef<str>,
        attempt: u32,
    ) -> PathBuf {
        self.step_dir(phase_id, step_id)
            .join("attempts")
            .join(Self::format_attempt(attempt))
    }

    /// Returns `.method/steps/<phase>/<step>/attempts/<n>/relay/workers/<worker>/`.
    pub fn worker_relay_root(
        &self,
        phase_id: impl AsRef<str>,
        step_id: impl AsRef<str>,
        attempt: u32,
        worker_id: impl AsRef<str>,
    ) -> PathBuf {
        self.attempt_dir(phase_id, step_id, attempt)
            .join("relay")
            .join("workers")
            .join(worker_id.as_ref())
    }

    /// Returns `.method/artifacts/handoffs/<phase>--<step>--<attempt>--<worker>.md`.
    pub fn canonical_handoff(
        &self,
        phase_id: impl AsRef<str>,
        step_id: impl AsRef<str>,
        attempt: u32,
        worker_id: impl AsRef<str>,
    ) -> PathBuf {
        let filename = format!(
            "{}--{}--{}--{}.md",
            phase_id.as_ref(),
            step_id.as_ref(),
            Self::format_attempt(attempt),
            worker_id.as_ref()
        );

        self.method_root()
            .join("artifacts")
            .join("handoffs")
            .join(filename)
    }

    /// Returns `.method/artifacts/outputs/<name>.json`.
    pub fn output_record(&self, name: impl AsRef<str>) -> PathBuf {
        self.method_root()
            .join("artifacts")
            .join("outputs")
            .join(format!("{}.json", name.as_ref()))
    }

    /// Returns `.method/gates/<phase>/<gate>/`.
    pub fn gate_dir(&self, phase_id: impl AsRef<str>, gate_id: impl AsRef<str>) -> PathBuf {
        self.method_root()
            .join("gates")
            .join(phase_id.as_ref())
            .join(gate_id.as_ref())
    }

    /// Returns `.method/gates/<phase>/<gate>/review-manifest.json`.
    pub fn gate_manifest_path(
        &self,
        phase_id: impl AsRef<str>,
        gate_id: impl AsRef<str>,
    ) -> PathBuf {
        self.gate_dir(phase_id, gate_id)
            .join("review-manifest.json")
    }

    fn format_attempt(attempt: u32) -> String {
        format!("{attempt:03}")
    }
}

// ---------------------------------------------------------------------------
// Lock errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum LockError {
    #[error("run lock already held")]
    AlreadyLocked,

    #[error("lock acquisition timed out")]
    Timeout,

    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("invalid lock file: {0}")]
    InvalidLockFile(String),
}

// ---------------------------------------------------------------------------
// Lock info
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockInfo {
    pub pid: u32,
    pub start_time: u64,
    pub hostname: String,
    pub acquired_at: String,
}

// ---------------------------------------------------------------------------
// Run lock
// ---------------------------------------------------------------------------

/// Advisory file-based lock for exclusive run access.
/// Automatically releases (deletes) the lock file on drop.
#[derive(Debug)]
pub struct RunLock {
    path: PathBuf,
    _file: std::fs::File,
}

impl Drop for RunLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Get a simplified process start time (PID as u64 for tracer bullet).
pub fn get_process_start_time() -> u64 {
    std::process::id() as u64
}

/// Acquire an exclusive run lock, retrying until timeout.
/// Detects and removes stale locks from dead processes.
pub fn acquire_lock(lock_path: &Path, timeout: Duration) -> Result<RunLock, LockError> {
    if let Some(parent) = lock_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let start = Instant::now();
    loop {
        // Try exclusive creation
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(lock_path)
        {
            Ok(mut file) => {
                // Write lock info
                let info = LockInfo {
                    pid: std::process::id(),
                    start_time: get_process_start_time(),
                    hostname: hostname(),
                    acquired_at: chrono::Utc::now().to_rfc3339(),
                };
                let json = serde_json::to_string_pretty(&info).map_err(std::io::Error::other)?;
                use std::io::Write;
                file.write_all(json.as_bytes())?;
                return Ok(RunLock {
                    path: lock_path.to_path_buf(),
                    _file: file,
                });
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                // Lock file exists — check if stale
                if let Ok(content) = std::fs::read_to_string(lock_path) {
                    if let Ok(info) = serde_json::from_str::<LockInfo>(&content) {
                        if unsafe { libc::kill(info.pid as i32, 0) != 0 } {
                            // Stale lock — remove and retry
                            let _ = std::fs::remove_file(lock_path);
                            continue;
                        }
                    } else {
                        // Corrupt lock file — remove and retry
                        let _ = std::fs::remove_file(lock_path);
                        continue;
                    }
                }

                if start.elapsed() >= timeout {
                    return Err(LockError::Timeout);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(LockError::IoError(e)),
        }
    }
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "unknown".to_string())
}
