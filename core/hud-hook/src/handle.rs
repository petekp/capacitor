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
use fs_err as fs;
use hud_core::boundaries::find_project_boundary;
use hud_core::state::{
    count_other_session_locks, create_session_lock, release_lock_by_session, HookEvent, HookInput,
    StateStore,
};
use hud_core::types::SessionState;
use std::env;
use std::io::{self, Read, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::NamedTempFile;

const STATE_FILE: &str = ".capacitor/sessions.json";
const LOCK_DIR: &str = ".capacitor/sessions";
const ACTIVITY_FILE: &str = ".capacitor/file-activity.json";
const TOMBSTONES_DIR: &str = ".capacitor/ended-sessions";
const HEARTBEAT_FILE: &str = ".capacitor/hud-hook-heartbeat";
const LOCK_MODE_ENV: &str = "CAPACITOR_DAEMON_LOCK_MODE";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LockMode {
    Full,
    ReadOnly,
    Off,
}

fn lock_mode() -> LockMode {
    lock_mode_from_env(env::var(LOCK_MODE_ENV).ok().as_deref())
}

fn lock_mode_from_env(value: Option<&str>) -> LockMode {
    match value.map(|v| v.trim().to_ascii_lowercase()) {
        Some(value)
            if matches!(
                value.as_str(),
                "readonly" | "read-only" | "read_only" | "ro"
            ) =>
        {
            LockMode::ReadOnly
        }
        Some(value) if matches!(value.as_str(), "off" | "disabled" | "none") => LockMode::Off,
        _ => LockMode::Full,
    }
}

fn lock_writes_enabled() -> bool {
    matches!(lock_mode(), LockMode::Full)
}

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

    handle_hook_input(hook_input)
}

fn handle_hook_input(hook_input: HookInput) -> Result<(), String> {
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    handle_hook_input_with_home(hook_input, &home)
}

fn handle_hook_input_with_home(hook_input: HookInput, home: &Path) -> Result<(), String> {
    // Get the event type
    let event = match hook_input.to_event() {
        Some(e) => e,
        None => return Ok(()), // No event name, skip
    };

    // Get session ID (required for most events)
    let session_id = match &hook_input.session_id {
        Some(id) => id.clone(),
        None => {
            tracing::debug!(
                event = ?hook_input.hook_event_name,
                "Skipping event (missing session_id)"
            );
            return Ok(());
        }
    };

    // Get paths
    let tombstones_dir = home.join(TOMBSTONES_DIR);

    // Check if this session has already ended (tombstone exists)
    // This prevents race conditions where events arrive after SessionEnd
    // SessionStart is exempt - it can start a new session with the same ID
    if event != HookEvent::SessionEnd
        && event != HookEvent::SessionStart
        && has_tombstone(&tombstones_dir, &session_id)
    {
        tracing::debug!(
            event = ?hook_input.hook_event_name,
            session = %session_id,
            "Skipping event for ended session"
        );
        return Ok(());
    }

    // Touch heartbeat for valid, actionable hook events
    touch_heartbeat(home);

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
        fs::create_dir_all(parent).ok();
    }
    fs::create_dir_all(&lock_base).ok();

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
    tracing::debug!(
        event = ?hook_input.hook_event_name,
        session = %session_id,
        cwd = ?cwd,
        current_state = ?current_state,
        "Processing hook"
    );

    // Process the event
    let (action, new_state, file_activity) = process_event(&event, current_state, &hook_input);

    // Skip if no CWD and not deleting
    if cwd.is_none() && action != Action::Delete {
        tracing::debug!(
            event = ?hook_input.hook_event_name,
            session = %session_id,
            "Skipping event (missing cwd)"
        );
        return Ok(());
    }

    let cwd = cwd.unwrap_or_default();

    if !cwd.is_empty() {
        crate::daemon_client::send_handle_event(&event, &session_id, ppid, &cwd);
    }

    // Log the action
    tracing::info!(
        action = ?action,
        new_state = ?new_state,
        session = %session_id,
        cwd = %cwd,
        "State update"
    );

    // Apply the state change
    match action {
        Action::Delete => {
            // Check if OTHER processes are still using this session_id
            // (can happen when Claude resumes the same session in multiple terminals)
            let other_locks = count_other_session_locks(&lock_base, &session_id, ppid);
            let preserve_record = other_locks > 0;

            if preserve_record {
                tracing::debug!(
                    session = %session_id,
                    other_locks = other_locks,
                    "Session has other active locks, preserving session record"
                );
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
            if lock_writes_enabled() {
                if release_lock_by_session(&lock_base, &session_id, ppid) {
                    tracing::info!(
                        session = %session_id,
                        pid = ppid,
                        "Released lock"
                    );
                }
            } else {
                tracing::debug!(
                    session = %session_id,
                    pid = ppid,
                    mode = ?lock_mode(),
                    "Skipping lock release (lock writes disabled)"
                );
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
    if matches!(event, HookEvent::SessionStart | HookEvent::UserPromptSubmit)
        && lock_writes_enabled()
    {
        spawn_lock_holder(&lock_base, &session_id, &cwd, ppid);
    } else if matches!(event, HookEvent::SessionStart | HookEvent::UserPromptSubmit) {
        tracing::debug!(
            session = %session_id,
            pid = ppid,
            mode = ?lock_mode(),
            "Skipping lock holder spawn (lock writes disabled)"
        );
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

/// Returns true if the session is in an active state that shouldn't be overridden.
fn is_active_state(state: Option<SessionState>) -> bool {
    matches!(
        state,
        Some(SessionState::Working) | Some(SessionState::Waiting) | Some(SessionState::Compacting)
    )
}

/// Extracts file activity info from file-modifying tools.
///
/// ## Tool Filtering (Intentional)
///
/// Only these tools are tracked:
/// - `Edit` - Modifies existing file content
/// - `Write` - Creates or overwrites files
/// - `Read` - Reads file content (important for context)
/// - `NotebookEdit` - Modifies Jupyter notebooks
///
/// Intentionally **NOT** tracked:
/// - `Glob`, `Grep` - File discovery tools (too noisy, many matches)
/// - `Bash` - Indirect file access (complex to parse which files)
/// - `Task`, `WebFetch`, etc. - Not file-focused
///
/// The goal is to show meaningful file modifications in the HUD activity feed,
/// not every file the agent happens to search through.
fn extract_file_activity(
    tool_name: &Option<String>,
    file_path: &Option<String>,
) -> Option<(String, String)> {
    match tool_name.as_deref() {
        Some("Edit" | "Write" | "Read" | "NotebookEdit") => {
            file_path.clone().zip(tool_name.clone())
        }
        _ => None,
    }
}

/// Returns the appropriate action for a tool use event.
fn tool_use_action(
    current_state: Option<SessionState>,
    file_activity: Option<(String, String)>,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    if current_state == Some(SessionState::Working) {
        (Action::Heartbeat, None, file_activity)
    } else {
        (Action::Upsert, Some(SessionState::Working), file_activity)
    }
}

fn process_event(
    event: &HookEvent,
    current_state: Option<SessionState>,
    _input: &HookInput,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    match event {
        HookEvent::SessionStart => {
            if is_active_state(current_state) {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::UserPromptSubmit => (Action::Upsert, Some(SessionState::Working), None),

        HookEvent::PreToolUse { .. } => tool_use_action(current_state, None),

        HookEvent::PostToolUse {
            tool_name,
            file_path,
        } => tool_use_action(current_state, extract_file_activity(tool_name, file_path)),

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
            tracing::debug!(event_name = %event_name, "Unhandled event");
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
        Ok(_) => tracing::debug!(
            session = %session_id,
            cwd = %cwd,
            pid = pid,
            "Lock holder spawned"
        ),
        Err(e) => tracing::warn!(error = %e, "Failed to spawn lock holder"),
    }
}

fn get_ppid() -> Option<u32> {
    #[cfg(unix)]
    {
        // SAFETY: getppid() is a simple syscall that returns the parent process ID.
        // It has no failure modes and always returns a valid PID (1 if parent exited).
        #[allow(unsafe_code)]
        Some(unsafe { libc::getppid() } as u32)
    }
    #[cfg(not(unix))]
    {
        None
    }
}

fn touch_heartbeat(home: &Path) {
    let heartbeat_path = home.join(HEARTBEAT_FILE);

    if let Some(parent) = heartbeat_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    use fs_err::OpenOptions;
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

/// Records file activity to the activity file atomically.
///
/// # Architecture Note
///
/// This is a lightweight activity implementation separate from `ActivityStore` in
/// `hud-core/src/activity.rs`. The separation exists because:
///
/// 1. **Hook must stay fast**: This code runs on every tool use event. Direct JSON
///    manipulation is faster than loading the full `ActivityStore`.
///
/// 2. **Write format parity**: The hook writes the native `activity` format used by
///    `ActivityStore` (with `project_path`) so the engine can read without conversion.
///    Legacy hook-format files with `files` arrays are migrated on write.
///
/// 3. **Atomicity**: Both implementations use atomic writes, but through different means.
///    This implementation uses `write_file_atomic()` with tempfile.
fn record_file_activity(
    activity_file: &PathBuf,
    session_id: &str,
    cwd: &str,
    file_path: &str,
    tool_name: &str,
) {
    use serde_json::{json, Value};

    // Resolve file path
    let resolved_path = if file_path.starts_with('/') {
        file_path.to_string()
    } else {
        format!("{}/{}", cwd, file_path)
    };

    let project_path = find_project_boundary(&resolved_path)
        .map(|b| b.path)
        .unwrap_or_else(|| cwd.to_string());

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
        .or_insert_with(|| json!({"cwd": cwd, "activity": []}));

    // Ensure activity array exists
    if !session
        .get("activity")
        .map(|a| a.is_array())
        .unwrap_or(false)
    {
        session["activity"] = json!([]);
    }

    // Migrate legacy hook format ("files") to native format ("activity")
    if session.get("files").map(|f| f.is_array()).unwrap_or(false) {
        let files = session["files"].as_array().cloned().unwrap_or_default();
        let session_cwd = session
            .get("cwd")
            .and_then(|v| v.as_str())
            .unwrap_or(cwd)
            .to_string();

        let mut existing_keys = std::collections::HashSet::new();
        if let Some(existing) = session["activity"].as_array() {
            for entry in existing {
                let key = format!(
                    "{}|{}|{}",
                    entry
                        .get("file_path")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default(),
                    entry
                        .get("timestamp")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default(),
                    entry
                        .get("tool")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                );
                existing_keys.insert(key);
            }
        }

        let activity_entries = session["activity"].as_array_mut().unwrap();
        for file in files {
            let Some(file_path) = file.get("file_path").and_then(|v| v.as_str()) else {
                continue;
            };
            let resolved_file_path = if Path::new(file_path).is_absolute() {
                file_path.to_string()
            } else {
                format!("{}/{}", session_cwd, file_path)
            };
            let tool = file
                .get("tool")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let timestamp = file
                .get("timestamp")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let key = format!("{}|{}|{}", resolved_file_path, timestamp, tool);
            if existing_keys.contains(&key) {
                continue;
            }
            let project_path = find_project_boundary(&resolved_file_path)
                .map(|b| b.path)
                .unwrap_or_else(|| session_cwd.clone());
            activity_entries.push(json!({
                "project_path": project_path,
                "file_path": resolved_file_path,
                "tool": tool,
                "timestamp": timestamp,
            }));
        }

        if let Some(obj) = session.as_object_mut() {
            obj.remove("files");
        }
    }

    // Add new file activity at the start
    let timestamp = Utc::now().to_rfc3339();
    let entry = json!({
        "project_path": project_path,
        "file_path": resolved_path,
        "tool": tool_name,
        "timestamp": timestamp,
    });

    let activity_entries = session["activity"].as_array_mut().unwrap();
    activity_entries.insert(0, entry);

    // Limit to 100 entries
    activity_entries.truncate(100);

    // Update cwd
    session["cwd"] = json!(cwd);

    // Write back atomically to prevent corruption on crash
    match serde_json::to_string_pretty(&activity) {
        Ok(content) => {
            if let Err(e) = write_file_atomic(activity_file, &content) {
                tracing::warn!(error = %e, "Failed to write activity file");
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to serialize activity");
        }
    }
}

fn remove_session_activity(activity_file: &PathBuf, session_id: &str) {
    use serde_json::Value;

    let mut activity: Value = match fs::read_to_string(activity_file) {
        Ok(content) => match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "Failed to parse activity file, skipping cleanup");
                return;
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            tracing::warn!(error = %e, "Failed to read activity file, skipping cleanup");
            return;
        }
    };

    if let Some(sessions) = activity.get_mut("sessions").and_then(|s| s.as_object_mut()) {
        sessions.remove(session_id);
    }

    // Write back atomically to prevent corruption on crash
    match serde_json::to_string_pretty(&activity) {
        Ok(content) => {
            if let Err(e) = write_file_atomic(activity_file, &content) {
                tracing::warn!(error = %e, "Failed to write activity file");
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to serialize activity");
        }
    }
}

fn has_tombstone(tombstones_dir: &Path, session_id: &str) -> bool {
    tombstones_dir.join(session_id).exists()
}

fn create_tombstone(tombstones_dir: &Path, session_id: &str) {
    if let Err(e) = fs::create_dir_all(tombstones_dir) {
        tracing::warn!(error = %e, "Failed to create tombstones dir");
        return;
    }

    let tombstone_path = tombstones_dir.join(session_id);
    if let Err(e) = fs::write(&tombstone_path, "") {
        tracing::warn!(error = %e, session = %session_id, "Failed to create tombstone");
    } else {
        tracing::debug!(session = %session_id, "Created tombstone");
    }
}

fn remove_tombstone(tombstones_dir: &Path, session_id: &str) {
    let tombstone_path = tombstones_dir.join(session_id);
    if tombstone_path.exists() {
        if let Err(e) = fs::remove_file(&tombstone_path) {
            tracing::warn!(error = %e, session = %session_id, "Failed to remove tombstone");
        } else {
            tracing::debug!(session = %session_id, "Cleared tombstone (new SessionStart)");
        }
    }
}

/// Writes content to a file atomically using a temporary file and rename.
/// This prevents data corruption if the process crashes mid-write.
fn write_file_atomic(path: &Path, content: &str) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = NamedTempFile::new_in(dir)?;
    tmp.write_all(content.as_bytes())?;
    tmp.flush()?;
    tmp.persist(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_lock_mode_from_env() {
        assert_eq!(lock_mode_from_env(None), LockMode::Full);
        assert_eq!(lock_mode_from_env(Some("readonly")), LockMode::ReadOnly);
        assert_eq!(lock_mode_from_env(Some("read-only")), LockMode::ReadOnly);
        assert_eq!(lock_mode_from_env(Some("ro")), LockMode::ReadOnly);
        assert_eq!(lock_mode_from_env(Some("off")), LockMode::Off);
        assert_eq!(lock_mode_from_env(Some("disabled")), LockMode::Off);
        assert_eq!(lock_mode_from_env(Some("unknown")), LockMode::Full);
    }

    fn make_hook_input(event_name: &str, session_id: Option<&str>, cwd: Option<&str>) -> HookInput {
        HookInput {
            hook_event_name: Some(event_name.to_string()),
            session_id: session_id.map(|id| id.to_string()),
            cwd: cwd.map(|path| path.to_string()),
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
        }
    }

    #[test]
    fn test_handle_hook_input_skips_tombstoned_session_without_heartbeat() {
        let temp = tempdir().unwrap();
        let session_id = "session-tombstoned";
        let tombstone_dir = temp.path().join(TOMBSTONES_DIR);
        fs::create_dir_all(&tombstone_dir).unwrap();
        fs::write(tombstone_dir.join(session_id), "").unwrap();

        let hook_input = make_hook_input("UserPromptSubmit", Some(session_id), Some("/tmp/test"));
        handle_hook_input_with_home(hook_input, temp.path()).unwrap();

        let heartbeat_path = temp.path().join(HEARTBEAT_FILE);
        assert!(
            !heartbeat_path.exists(),
            "Heartbeat should not be touched for tombstoned sessions"
        );
        assert!(
            !temp.path().join(STATE_FILE).exists(),
            "State file should not be created when skipping tombstoned events"
        );
    }

    #[test]
    fn test_handle_hook_input_missing_session_id_does_not_touch_heartbeat() {
        let temp = tempdir().unwrap();
        let hook_input = make_hook_input("UserPromptSubmit", None, Some("/tmp/test"));

        handle_hook_input_with_home(hook_input, temp.path()).unwrap();

        let heartbeat_path = temp.path().join(HEARTBEAT_FILE);
        assert!(
            !heartbeat_path.exists(),
            "Heartbeat should not be touched when session_id is missing"
        );
    }

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

    #[test]
    fn test_record_file_activity_migrates_legacy_relative_paths() {
        let temp = tempdir().unwrap();
        let project_dir = temp.path().join("project");
        let src_dir = project_dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        fs::write(project_dir.join("CLAUDE.md"), "# test").unwrap();

        let legacy_file = src_dir.join("main.rs");
        fs::write(&legacy_file, "fn main() {}").unwrap();
        let new_file = src_dir.join("lib.rs");
        fs::write(&new_file, "pub fn lib() {}").unwrap();

        let activity_file = temp.path().join("activity.json");
        let legacy_content = serde_json::json!({
            "version": 1,
            "sessions": {
                "session-1": {
                    "cwd": project_dir.to_string_lossy(),
                    "files": [
                        {
                            "file_path": "src/main.rs",
                            "tool": "Edit",
                            "timestamp": "2026-01-30T00:00:00Z"
                        }
                    ]
                }
            }
        });
        fs::write(
            &activity_file,
            serde_json::to_string_pretty(&legacy_content).unwrap(),
        )
        .unwrap();

        record_file_activity(
            &activity_file,
            "session-1",
            project_dir.to_string_lossy().as_ref(),
            "src/lib.rs",
            "Read",
        );

        let updated = fs::read_to_string(&activity_file).unwrap();
        let value: serde_json::Value = serde_json::from_str(&updated).unwrap();
        let session = &value["sessions"]["session-1"];

        assert!(
            session.get("files").is_none(),
            "legacy files array should be removed after migration"
        );

        let activity = session["activity"].as_array().expect("activity array");
        let legacy_path = legacy_file.to_string_lossy().to_string();
        let project_path = project_dir.to_string_lossy().to_string();
        assert!(
            activity
                .iter()
                .any(|entry| entry["file_path"].as_str() == Some(legacy_path.as_str())),
            "legacy entry should be resolved to absolute file path"
        );
        assert!(
            activity
                .iter()
                .any(|entry| entry["project_path"].as_str() == Some(project_path.as_str())),
            "migrated entry should include project_path"
        );
    }

    #[test]
    fn test_record_file_activity_merges_legacy_files_with_existing_activity() {
        let temp = tempdir().unwrap();
        let project_dir = temp.path().join("project");
        let src_dir = project_dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        fs::write(project_dir.join("CLAUDE.md"), "# test").unwrap();

        let main_file = src_dir.join("main.rs");
        let lib_file = src_dir.join("lib.rs");
        let new_file = src_dir.join("new.rs");
        fs::write(&main_file, "fn main() {}").unwrap();
        fs::write(&lib_file, "pub fn lib() {}").unwrap();
        fs::write(&new_file, "pub fn new() {}").unwrap();

        let activity_file = temp.path().join("activity.json");
        let legacy_timestamp = "2026-01-30T00:00:00Z";
        let legacy_content = serde_json::json!({
            "version": 1,
            "sessions": {
                "session-1": {
                    "cwd": project_dir.to_string_lossy(),
                    "activity": [
                        {
                            "project_path": project_dir.to_string_lossy(),
                            "file_path": main_file.to_string_lossy(),
                            "tool": "Edit",
                            "timestamp": legacy_timestamp
                        }
                    ],
                    "files": [
                        {
                            "file_path": "src/main.rs",
                            "tool": "Edit",
                            "timestamp": legacy_timestamp
                        },
                        {
                            "file_path": "src/lib.rs",
                            "tool": "Read",
                            "timestamp": "2026-01-30T00:01:00Z"
                        }
                    ]
                }
            }
        });
        fs::write(
            &activity_file,
            serde_json::to_string_pretty(&legacy_content).unwrap(),
        )
        .unwrap();

        record_file_activity(
            &activity_file,
            "session-1",
            project_dir.to_string_lossy().as_ref(),
            "src/new.rs",
            "Write",
        );

        let updated = fs::read_to_string(&activity_file).unwrap();
        let value: serde_json::Value = serde_json::from_str(&updated).unwrap();
        let session = &value["sessions"]["session-1"];

        assert!(
            session.get("files").is_none(),
            "legacy files array should be removed after migration"
        );

        let activity = session["activity"].as_array().expect("activity array");
        let new_path = new_file.to_string_lossy().to_string();
        assert_eq!(activity[0]["file_path"].as_str(), Some(new_path.as_str()));
        assert_eq!(activity[0]["tool"].as_str(), Some("Write"));

        let main_path = main_file.to_string_lossy().to_string();
        let lib_path = lib_file.to_string_lossy().to_string();
        let main_count = activity
            .iter()
            .filter(|entry| entry["file_path"].as_str() == Some(main_path.as_str()))
            .count();
        assert_eq!(main_count, 1, "duplicate legacy entry should be deduped");
        assert!(
            activity
                .iter()
                .any(|entry| entry["file_path"].as_str() == Some(lib_path.as_str())),
            "legacy lib.rs entry should be migrated"
        );
    }

    #[test]
    fn test_record_file_activity_migrates_legacy_absolute_paths() {
        let temp = tempdir().unwrap();
        let project_dir = temp.path().join("project");
        let src_dir = project_dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        fs::write(project_dir.join("CLAUDE.md"), "# test").unwrap();

        let legacy_file = src_dir.join("main.rs");
        let new_file = src_dir.join("lib.rs");
        fs::write(&legacy_file, "fn main() {}").unwrap();
        fs::write(&new_file, "pub fn lib() {}").unwrap();

        let activity_file = temp.path().join("activity.json");
        let legacy_path = legacy_file.to_string_lossy().to_string();
        let project_path = project_dir.to_string_lossy().to_string();
        let legacy_content = serde_json::json!({
            "version": 1,
            "sessions": {
                "session-1": {
                    "cwd": project_path,
                    "files": [
                        {
                            "file_path": legacy_path,
                            "tool": "Edit",
                            "timestamp": "2026-01-30T00:00:00Z"
                        }
                    ]
                }
            }
        });
        fs::write(
            &activity_file,
            serde_json::to_string_pretty(&legacy_content).unwrap(),
        )
        .unwrap();

        record_file_activity(
            &activity_file,
            "session-1",
            project_dir.to_string_lossy().as_ref(),
            "src/lib.rs",
            "Read",
        );

        let updated = fs::read_to_string(&activity_file).unwrap();
        let value: serde_json::Value = serde_json::from_str(&updated).unwrap();
        let session = &value["sessions"]["session-1"];

        assert!(
            session.get("files").is_none(),
            "legacy files array should be removed after migration"
        );

        let activity = session["activity"].as_array().expect("activity array");
        assert!(
            activity
                .iter()
                .any(|entry| entry["file_path"].as_str()
                    == Some(legacy_file.to_string_lossy().as_ref())),
            "absolute legacy path should be preserved"
        );
        assert!(
            activity.iter().any(|entry| entry["project_path"].as_str()
                == Some(project_dir.to_string_lossy().as_ref())),
            "migrated entry should include project_path"
        );
    }
}
