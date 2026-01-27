//! Lock holder daemon for Claude HUD.
//!
//! This background process monitors a Claude Code process and releases the lock
//! when the process exits.
//!
//! ## v4 Session-Based Locks
//!
//! With session-based locking, each process has its own lock file keyed by session_id + PID.
//! When the monitored PID exits, we simply release this process's lock. There's no
//! need for handoff since each concurrent process has its own independent lock.
//!
//! ## Lifecycle
//!
//! 1. Spawned by `handle` command on SessionStart/UserPromptSubmit
//! 2. Monitors the Claude process PID via `kill -0`
//! 3. When PID exits: release this session's lock (remove directory)

use fs_err as fs;
use hud_core::state::{is_pid_alive, release_lock_by_session};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

/// Maximum lifetime for a lock holder (24 hours).
/// This is a safety valve to prevent perpetually running lock holders
/// in case something goes wrong with PID monitoring.
const MAX_LIFETIME_SECS: u64 = 24 * 60 * 60;

pub fn run(session_id: &str, cwd: &str, pid: u32, lock_dir: &Path) {
    let start = Instant::now();

    // Monitor the PID until it exits
    while is_pid_alive(pid) {
        // Safety timeout: exit after 24 hours to prevent perpetually running lock holders
        if start.elapsed().as_secs() > MAX_LIFETIME_SECS {
            tracing::info!(
                session = %session_id,
                cwd = %cwd,
                "Lock holder exceeded max lifetime (24h), exiting"
            );
            break;
        }

        // Check if lock directory still exists
        if !lock_dir.exists() {
            tracing::debug!(
                session = %session_id,
                cwd = %cwd,
                "Lock directory removed externally, exiting holder"
            );
            return;
        }

        // Check if lock was taken over by another process (shouldn't happen with session-based locks)
        if let Some(lock_pid) = read_lock_pid(lock_dir) {
            if lock_pid != pid {
                tracing::debug!(
                    session = %session_id,
                    cwd = %cwd,
                    new_pid = lock_pid,
                    old_pid = pid,
                    "Lock taken over by another process, exiting holder"
                );
                return;
            }
        }

        thread::sleep(Duration::from_secs(1));
    }

    // PID has exited - release this session's lock
    // With session-based locking, we don't do handoffs since each session has its own lock
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => {
            tracing::warn!(
                session = %session_id,
                "Cannot determine home directory, releasing lock directly"
            );
            // Try to remove the lock directory directly as a fallback
            let _ = fs::remove_dir_all(lock_dir);
            return;
        }
    };

    let lock_base = home.join(".capacitor/sessions");
    if release_lock_by_session(&lock_base, session_id, pid) {
        tracing::info!(
            session = %session_id,
            pid = pid,
            cwd = %cwd,
            "Lock released (PID exited)"
        );
    } else {
        tracing::warn!(
            session = %session_id,
            pid = pid,
            cwd = %cwd,
            "Failed to release lock (PID exited)"
        );
    }
}

fn read_lock_pid(lock_dir: &Path) -> Option<u32> {
    let pid_path = lock_dir.join("pid");
    let pid_str = fs::read_to_string(pid_path).ok()?;
    pid_str.trim().parse().ok()
}
