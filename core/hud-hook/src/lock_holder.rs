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

use chrono::Utc;
use hud_core::state::release_lock_by_session;
use std::fs;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

const LOG_FILE: &str = ".capacitor/hud-hook-debug.log";

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
            log(&format!(
                "Lock holder exceeded max lifetime (24h), exiting for session {} at {}",
                session_id, cwd
            ));
            break;
        }

        // Check if lock directory still exists
        if !lock_dir.exists() {
            log(&format!(
                "Lock directory removed externally, exiting holder for session {} at {}",
                session_id, cwd
            ));
            return;
        }

        // Check if lock was taken over by another process (shouldn't happen with session-based locks)
        if let Some(lock_pid) = read_lock_pid(lock_dir) {
            if lock_pid != pid {
                log(&format!(
                    "Lock taken over by PID {} (was {}), exiting holder for session {} at {}",
                    lock_pid, pid, session_id, cwd
                ));
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
            log(&format!(
                "Cannot determine home directory, releasing lock for session {}",
                session_id
            ));
            // Try to remove the lock directory directly as a fallback
            let _ = fs::remove_dir_all(lock_dir);
            return;
        }
    };

    let lock_base = home.join(".capacitor/sessions");
    if release_lock_by_session(&lock_base, session_id, pid) {
        log(&format!(
            "Lock released for session {}-{} at {} (PID exited)",
            session_id, pid, cwd
        ));
    } else {
        log(&format!(
            "Failed to release lock for session {}-{} at {} (PID exited)",
            session_id, pid, cwd
        ));
    }
}

fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // SAFETY: kill(pid, 0) is a standard POSIX liveness check that sends no signal.
        // Returns 0 if the process exists, -1 with ESRCH if the process doesn't exist.
        #[allow(unsafe_code)]
        unsafe {
            libc::kill(pid as i32, 0) == 0
        }
    }
    #[cfg(not(unix))]
    {
        false
    }
}

fn read_lock_pid(lock_dir: &Path) -> Option<u32> {
    let pid_path = lock_dir.join("pid");
    let pid_str = fs::read_to_string(pid_path).ok()?;
    pid_str.trim().parse().ok()
}

fn log(message: &str) {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };
    let log_file = home.join(LOG_FILE);

    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
    let line = format!("{} | lock_holder: {}\n", timestamp, message);

    use std::fs::OpenOptions;
    use std::io::Write;

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_file) {
        let _ = file.write_all(line.as_bytes());
    }
}
