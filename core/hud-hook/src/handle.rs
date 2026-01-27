//! Event handler for Claude Code hooks.
//!
//! Reads JSON from stdin, parses the hook event, and updates session state.
//!
//! ## State Machine
//!
//! ```text
//! SessionStart           → ready    (+ creates lock)
//! UserPromptSubmit       → working  (+ creates lock if missing)
//! PreToolUse/PostToolUse → working  (heartbeat if already working)
//! PermissionRequest      → waiting
//! Notification           → ready    (only idle_prompt type)
//! PreCompact             → compacting
//! Stop                   → ready    (unless stop_hook_active=true)
//! SessionEnd             → removes session record
//! ```

use chrono::Utc;
use hud_core::state::{
    count_other_session_locks, create_session_lock, release_lock_by_session, HookEvent, HookInput,
    StateStore,
};
use hud_core::types::SessionState;
use std::env;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const LOG_FILE: &str = ".capacitor/hud-hook-debug.log";
const STATE_FILE: &str = ".capacitor/sessions.json";
const LOCK_DIR: &str = ".capacitor/sessions";
const ACTIVITY_FILE: &str = ".capacitor/file-activity.json";
const TOMBSTONES_DIR: &str = ".capacitor/ended-sessions";
const HEARTBEAT_FILE: &str = ".capacitor/hud-hook-heartbeat";

pub fn run() -> Result<(), String> {
    // Skip if this is a summary generation subprocess
    if env::var("HUD_SUMMARY_GEN")
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        // Drain stdin and exit
        let _ = io::stdin().read_to_end(&mut Vec::new());
        return Ok(());
    }

    // Touch heartbeat file immediately to prove hooks are firing
    touch_heartbeat();

    // Read JSON from stdin
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| format!("Failed to read stdin: {}", e))?;

    if input.trim().is_empty() {
        return Ok(());
    }

    // Parse the hook input
    let hook_input: HookInput =
        serde_json::from_str(&input).map_err(|e| format!("Failed to parse hook input: {}", e))?;

    // Get the event type
    let event = match hook_input.to_event() {
        Some(e) => e,
        None => return Ok(()), // No event name, skip
    };

    // Get session ID (required for most events)
    let session_id = match &hook_input.session_id {
        Some(id) => id.clone(),
        None => {
            log(&format!(
                "Skipping event (missing session_id): {:?}",
                hook_input.hook_event_name
            ));
            return Ok(());
        }
    };

    // Get paths
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    let tombstones_dir = home.join(TOMBSTONES_DIR);

    // Check if this session has already ended (tombstone exists)
    // This prevents race conditions where events arrive after SessionEnd
    // SessionStart is exempt - it can start a new session with the same ID
    if event != HookEvent::SessionEnd
        && event != HookEvent::SessionStart
        && has_tombstone(&tombstones_dir, &session_id)
    {
        log(&format!(
            "Skipping event for ended session: {:?} session={}",
            hook_input.hook_event_name, session_id
        ));
        return Ok(());
    }

    // If SessionStart arrives for a tombstoned session, clear the tombstone
    if event == HookEvent::SessionStart && has_tombstone(&tombstones_dir, &session_id) {
        remove_tombstone(&tombstones_dir, &session_id);
    }

    // Get remaining paths
    let state_file = home.join(STATE_FILE);
    let lock_base = home.join(LOCK_DIR);
    let activity_file = home.join(ACTIVITY_FILE);

    // Ensure directories exist
    if let Some(parent) = state_file.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    std::fs::create_dir_all(&lock_base).ok();

    // Load current state
    let mut store = StateStore::load(&state_file).unwrap_or_else(|_| StateStore::new(&state_file));

    // Get current session state and CWD
    let current_record = store.get_by_session_id(&session_id);
    let current_state = current_record.map(|r| r.state);
    let current_cwd = current_record.map(|r| r.cwd.as_str());

    // Resolve CWD
    let cwd = hook_input.resolve_cwd(current_cwd);

    // Get Claude's PID (our parent process)
    let claude_pid = std::process::id();
    let ppid = get_ppid().unwrap_or(claude_pid);

    // Log the event
    log(&format!(
        "Hook: event={:?} session={} cwd={:?} current_state={:?}",
        hook_input.hook_event_name, session_id, cwd, current_state
    ));

    // Process the event
    let (action, new_state, file_activity) = process_event(&event, current_state, &hook_input);

    // Skip if no CWD and not deleting
    if cwd.is_none() && action != Action::Delete {
        log(&format!(
            "Skipping event (missing cwd): {:?} session={}",
            hook_input.hook_event_name, session_id
        ));
        return Ok(());
    }

    let cwd = cwd.unwrap_or_default();

    // Log the action
    log(&format!(
        "State update: action={:?} new_state={:?} session={} cwd={}",
        action, new_state, session_id, cwd
    ));

    // Apply the state change
    match action {
        Action::Delete => {
            // Check if OTHER processes are still using this session_id
            // (can happen when Claude resumes the same session in multiple terminals)
            let other_locks = count_other_session_locks(&lock_base, &session_id, ppid);
            let preserve_record = other_locks > 0;

            if preserve_record {
                log(&format!(
                    "Session {} has {} other active locks, preserving session record",
                    session_id, other_locks
                ));
            } else {
                // No other locks - clean up completely
                // Order matters: remove record BEFORE lock to prevent race condition
                // where UI sees no lock + fresh record → shows Ready briefly before Idle

                // 1. Create tombstone to prevent late-arriving events
                create_tombstone(&tombstones_dir, &session_id);

                // 2. Remove session record and save to disk
                store.remove(&session_id);
                store
                    .save()
                    .map_err(|e| format!("Failed to save state: {}", e))?;

                // 3. Remove from activity file
                remove_session_activity(&activity_file, &session_id);
            }

            // 4. Release lock LAST - UI will see no record AND no lock atomically
            if release_lock_by_session(&lock_base, &session_id, ppid) {
                log(&format!(
                    "Released lock for session {} (PID {})",
                    session_id, ppid
                ));
            }
        }
        Action::Upsert | Action::Heartbeat => {
            // Determine the target state
            let existing = store.get_by_session_id(&session_id);
            let state = new_state
                .unwrap_or_else(|| existing.map(|r| r.state).unwrap_or(SessionState::Ready));

            // Update the store (this handles state_changed_at internally)
            store.update(&session_id, state, &cwd);
            store
                .save()
                .map_err(|e| format!("Failed to save state: {}", e))?;
        }
        Action::Skip => {
            // Nothing to do for state, but lock may still need spawning
        }
    }

    // Spawn lock holder for session-establishing events (even if state was skipped)
    // This ensures locks are recreated after resets or when SessionStart is skipped
    // for active sessions. create_session_lock() is idempotent - returns None if lock exists.
    if matches!(event, HookEvent::SessionStart | HookEvent::UserPromptSubmit) {
        spawn_lock_holder(&lock_base, &session_id, &cwd, ppid);
    }

    // Record file activity if applicable
    if let Some((file_path, tool_name)) = file_activity {
        record_file_activity(&activity_file, &session_id, &cwd, &file_path, &tool_name);
    }

    Ok(())
}

#[derive(Debug, PartialEq)]
enum Action {
    Upsert,
    Heartbeat,
    Delete,
    Skip,
}

fn process_event(
    event: &HookEvent,
    current_state: Option<SessionState>,
    _input: &HookInput,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    match event {
        HookEvent::SessionStart => {
            // Don't override active states
            if matches!(
                current_state,
                Some(SessionState::Working)
                    | Some(SessionState::Waiting)
                    | Some(SessionState::Compacting)
            ) {
                return (Action::Skip, None, None);
            }
            (Action::Upsert, Some(SessionState::Ready), None)
        }

        HookEvent::UserPromptSubmit => (Action::Upsert, Some(SessionState::Working), None),

        HookEvent::PreToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Heartbeat, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PostToolUse {
            tool_name,
            file_path,
        } => {
            let file_activity = match tool_name.as_deref() {
                Some("Edit" | "Write" | "Read" | "NotebookEdit") => file_path
                    .clone()
                    .and_then(|fp| tool_name.clone().map(|tn| (fp, tn))),
                _ => None,
            };

            if current_state == Some(SessionState::Working) {
                (Action::Heartbeat, None, file_activity)
            } else {
                (Action::Upsert, Some(SessionState::Working), file_activity)
            }
        }

        HookEvent::PermissionRequest => (Action::Upsert, Some(SessionState::Waiting), None),

        HookEvent::PreCompact => (Action::Upsert, Some(SessionState::Compacting), None),

        HookEvent::Notification { notification_type } => {
            if notification_type == "idle_prompt" {
                (Action::Upsert, Some(SessionState::Ready), None)
            } else {
                (Action::Skip, None, None)
            }
        }

        HookEvent::Stop { stop_hook_active } => {
            if *stop_hook_active {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::SessionEnd => (Action::Delete, None, None),

        HookEvent::Unknown { event_name } => {
            log(&format!("Unhandled event: {}", event_name));
            (Action::Skip, None, None)
        }
    }
}

fn spawn_lock_holder(lock_base: &Path, session_id: &str, cwd: &str, pid: u32) {
    // Try to create the session-based lock
    let lock_dir = match create_session_lock(lock_base, session_id, cwd, pid) {
        Some(dir) => dir,
        None => {
            // Lock already held or creation failed
            return;
        }
    };

    // Spawn the lock holder daemon
    let current_exe = match env::current_exe() {
        Ok(exe) => exe,
        Err(_) => return,
    };

    let result = Command::new(current_exe)
        .args([
            "lock-holder",
            "--session-id",
            session_id,
            "--cwd",
            cwd,
            "--pid",
            &pid.to_string(),
            "--lock-dir",
            lock_dir.to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    match result {
        Ok(_) => log(&format!(
            "Lock holder spawned for session {} at {} (PID {})",
            session_id, cwd, pid
        )),
        Err(e) => log(&format!("Failed to spawn lock holder: {}", e)),
    }
}

fn get_ppid() -> Option<u32> {
    #[cfg(unix)]
    {
        Some(unsafe { libc::getppid() } as u32)
    }
    #[cfg(not(unix))]
    {
        None
    }
}

fn touch_heartbeat() {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };
    let heartbeat_path = home.join(HEARTBEAT_FILE);

    if let Some(parent) = heartbeat_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    use std::fs::OpenOptions;
    use std::io::Write as _;

    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&heartbeat_path)
    {
        let _ = writeln!(file, "{}", Utc::now().timestamp());
    }
}

fn log(message: &str) {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };
    let log_file = home.join(LOG_FILE);

    // Ensure log directory exists
    if let Some(parent) = log_file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    // Rotate if needed (simple size check)
    if let Ok(meta) = std::fs::metadata(&log_file) {
        if meta.len() > 1_048_576 {
            // 1MB
            // Simple rotation: backup and truncate
            let backup = home.join(".capacitor/hud-hook-debug.log.1");
            let _ = std::fs::copy(&log_file, &backup);
            let _ = std::fs::write(&log_file, "");
        }
    }

    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
    let line = format!("{} | {}\n", timestamp, message);

    use std::fs::OpenOptions;
    use std::io::Write;

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_file) {
        let _ = file.write_all(line.as_bytes());
    }
}

fn record_file_activity(
    activity_file: &PathBuf,
    session_id: &str,
    cwd: &str,
    file_path: &str,
    tool_name: &str,
) {
    use serde_json::{json, Value};
    use std::fs;

    // Resolve file path
    let resolved_path = if file_path.starts_with('/') {
        file_path.to_string()
    } else {
        format!("{}/{}", cwd, file_path)
    };

    // Load existing activity
    let mut activity: Value = fs::read_to_string(activity_file)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({"version": 1, "sessions": {}}));

    // Ensure structure
    if !activity.is_object() {
        activity = json!({"version": 1, "sessions": {}});
    }
    if !activity
        .get("sessions")
        .map(|s| s.is_object())
        .unwrap_or(false)
    {
        activity["sessions"] = json!({});
    }

    // Get or create session
    let sessions = activity["sessions"].as_object_mut().unwrap();
    let session = sessions
        .entry(session_id.to_string())
        .or_insert_with(|| json!({"cwd": cwd, "files": []}));

    // Ensure files array exists
    if !session.get("files").map(|f| f.is_array()).unwrap_or(false) {
        session["files"] = json!([]);
    }

    // Add new file activity at the start
    let timestamp = Utc::now().to_rfc3339();
    let entry = json!({
        "file_path": resolved_path,
        "tool": tool_name,
        "timestamp": timestamp,
    });

    let files = session["files"].as_array_mut().unwrap();
    files.insert(0, entry);

    // Limit to 100 entries
    files.truncate(100);

    // Update cwd
    session["cwd"] = json!(cwd);

    // Write back
    match serde_json::to_string_pretty(&activity) {
        Ok(content) => {
            if let Err(e) = fs::write(activity_file, content) {
                log(&format!("Failed to write activity file: {}", e));
            }
        }
        Err(e) => {
            log(&format!("Failed to serialize activity: {}", e));
        }
    }
}

fn remove_session_activity(activity_file: &PathBuf, session_id: &str) {
    use serde_json::Value;
    use std::fs;

    let mut activity: Value = match fs::read_to_string(activity_file) {
        Ok(content) => match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(e) => {
                log(&format!(
                    "Failed to parse activity file, skipping cleanup: {}",
                    e
                ));
                return;
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            log(&format!(
                "Failed to read activity file, skipping cleanup: {}",
                e
            ));
            return;
        }
    };

    if let Some(sessions) = activity.get_mut("sessions").and_then(|s| s.as_object_mut()) {
        sessions.remove(session_id);
    }

    match serde_json::to_string_pretty(&activity) {
        Ok(content) => {
            if let Err(e) = fs::write(activity_file, content) {
                log(&format!("Failed to write activity file: {}", e));
            }
        }
        Err(e) => {
            log(&format!("Failed to serialize activity: {}", e));
        }
    }
}

fn has_tombstone(tombstones_dir: &Path, session_id: &str) -> bool {
    tombstones_dir.join(session_id).exists()
}

fn create_tombstone(tombstones_dir: &Path, session_id: &str) {
    if let Err(e) = std::fs::create_dir_all(tombstones_dir) {
        log(&format!("Failed to create tombstones dir: {}", e));
        return;
    }

    let tombstone_path = tombstones_dir.join(session_id);
    if let Err(e) = std::fs::write(&tombstone_path, "") {
        log(&format!("Failed to create tombstone: {}", e));
    } else {
        log(&format!("Created tombstone for session {}", session_id));
    }
}

fn remove_tombstone(tombstones_dir: &Path, session_id: &str) {
    let tombstone_path = tombstones_dir.join(session_id);
    if tombstone_path.exists() {
        if let Err(e) = std::fs::remove_file(&tombstone_path) {
            log(&format!("Failed to remove tombstone: {}", e));
        } else {
            log(&format!(
                "Cleared tombstone for session {} (new SessionStart)",
                session_id
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_process_event_session_start() {
        let input = HookInput {
            hook_event_name: Some("SessionStart".to_string()),
            session_id: Some("test".to_string()),
            cwd: Some("/test".to_string()),
            trigger: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            source: None,
            reason: None,
            agent_id: None,
            agent_transcript_path: None,
        };

        let event = HookEvent::SessionStart;
        let (action, state, _) = process_event(&event, None, &input);

        assert_eq!(action, Action::Upsert);
        assert_eq!(state, Some(SessionState::Ready));
    }

    #[test]
    fn test_process_event_session_start_skips_working() {
        let input = HookInput {
            hook_event_name: Some("SessionStart".to_string()),
            session_id: Some("test".to_string()),
            cwd: Some("/test".to_string()),
            trigger: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            source: None,
            reason: None,
            agent_id: None,
            agent_transcript_path: None,
        };

        let event = HookEvent::SessionStart;
        let (action, state, _) = process_event(&event, Some(SessionState::Working), &input);

        assert_eq!(action, Action::Skip);
        assert_eq!(state, None);
    }

    #[test]
    fn test_process_event_user_prompt_submit() {
        let input = HookInput {
            hook_event_name: Some("UserPromptSubmit".to_string()),
            session_id: Some("test".to_string()),
            cwd: Some("/test".to_string()),
            trigger: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            source: None,
            reason: None,
            agent_id: None,
            agent_transcript_path: None,
        };

        let event = HookEvent::UserPromptSubmit;
        let (action, state, _) = process_event(&event, None, &input);

        assert_eq!(action, Action::Upsert);
        assert_eq!(state, Some(SessionState::Working));
    }

    #[test]
    fn test_process_event_stop_hook_active_true() {
        let input = HookInput {
            hook_event_name: Some("Stop".to_string()),
            session_id: Some("test".to_string()),
            cwd: Some("/test".to_string()),
            trigger: None,
            notification_type: None,
            stop_hook_active: Some(true),
            tool_name: None,
            tool_use_id: None,
            tool_input: None,
            tool_response: None,
            source: None,
            reason: None,
            agent_id: None,
            agent_transcript_path: None,
        };

        let event = HookEvent::Stop {
            stop_hook_active: true,
        };
        let (action, _, _) = process_event(&event, Some(SessionState::Working), &input);

        assert_eq!(action, Action::Skip);
    }
}
