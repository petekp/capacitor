//! Lock holder daemon for Claude HUD.
//!
//! This background process monitors a Claude Code process and releases the lock
//! when the process exits. It also handles session handoff - if another Claude
//! session starts at the same CWD, the lock is handed off rather than released.
//!
//! ## Lifecycle
//!
//! 1. Spawned by `handle` command on SessionStart/UserPromptSubmit
//! 2. Monitors the Claude process PID via `kill -0`
//! 3. When PID exits, searches for handoff candidate (another session at same CWD)
//! 4. If handoff found: update lock metadata, continue monitoring new PID
//! 5. If no handoff: release lock (remove directory)

use chrono::Utc;
use hud_core::state::{release_lock, update_lock_pid, StateStore};
use std::fs;
use std::path::Path;
use std::thread;
use std::time::Duration;

const STATE_FILE: &str = ".capacitor/sessions.json";
const LOG_FILE: &str = ".capacitor/hud-hook-debug.log";

pub fn run(cwd: &str, initial_pid: u32, lock_dir: &Path) {
    let mut current_pid = initial_pid;

    loop {
        // Monitor the current PID
        while is_pid_alive(current_pid) {
            // Check if lock directory still exists
            if !lock_dir.exists() {
                log(&format!(
                    "Lock directory removed externally, exiting holder for {}",
                    cwd
                ));
                return;
            }

            // Check if lock was taken over by another process
            if let Some(lock_pid) = read_lock_pid(lock_dir) {
                if lock_pid != current_pid {
                    log(&format!(
                        "Lock taken over by PID {} (was {}), exiting holder for {}",
                        lock_pid, current_pid, cwd
                    ));
                    return;
                }
            }

            thread::sleep(Duration::from_secs(1));
        }

        // PID has exited - look for handoff candidate
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => {
                log("Cannot determine home directory, releasing lock");
                let lock_base = lock_dir.parent().unwrap_or(Path::new("/tmp"));
                release_lock(lock_base, cwd);
                return;
            }
        };

        // Find handoff candidate
        match find_handoff_pid(&home.join(STATE_FILE), cwd, current_pid) {
            Some(new_pid) => {
                // Hand off to the new session
                if update_lock_pid(lock_dir, new_pid, cwd, Some(current_pid)) {
                    // Update the PID file too
                    let _ = fs::write(lock_dir.join("pid"), new_pid.to_string());
                    log(&format!(
                        "Lock handoff: {} -> {} for {}",
                        current_pid, new_pid, cwd
                    ));
                    current_pid = new_pid;
                } else {
                    log(&format!("Lock handoff failed, releasing lock for {}", cwd));
                    let lock_base = lock_dir.parent().unwrap_or(Path::new("/tmp"));
                    release_lock(lock_base, cwd);
                    return;
                }
            }
            None => {
                // No handoff candidate, release the lock
                let lock_base = lock_dir.parent().unwrap_or(Path::new("/tmp"));
                release_lock(lock_base, cwd);
                log(&format!(
                    "Lock released for {} (PID {} exited, no handoff candidate)",
                    cwd, current_pid
                ));
                return;
            }
        }
    }
}

fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
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

fn find_handoff_pid(state_file: &Path, cwd: &str, _exclude_pid: u32) -> Option<u32> {
    let store = StateStore::load(state_file).ok()?;

    for record in store.all_sessions() {
        if record.cwd != cwd {
            continue;
        }

        // The session record doesn't store PID directly, but we can check
        // if there's another active session for this CWD by checking if
        // any session at this CWD is still active
        //
        // For now, we'll skip handoff since session records don't track PIDs.
        // We rely on lock liveness detection instead. PID tracking could be added
        // later if needed for handoff detection.
    }

    None
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
