//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the v2 state store and
//! detecting the current state of Claude Code sessions.
//!
//! Note: Session state files are stored in `~/.capacitor/` (Capacitor's namespace),
//! while lock directories remain in `~/.claude/` (Claude Code's namespace).
//! Locks indicate liveness; state records provide the last known state.

use crate::activity::ActivityStore;
use crate::boundaries::normalize_path;
use crate::state::{resolve_state_with_details, SessionRecord, StateStore};
use crate::storage::StorageConfig;
use crate::types::{ProjectSessionState, SessionState};
use chrono::Utc;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use std::time::SystemTime;

pub(crate) const NO_LOCK_STATE_TTL: Duration = Duration::from_secs(120);
pub(crate) const ACTIVE_TRANSCRIPT_ACTIVITY_TTL: Duration = Duration::from_secs(5);

fn transcript_is_recent(transcript_path: &Path, threshold: Duration) -> Option<bool> {
    let meta = fs::metadata(transcript_path).ok()?;
    let modified = meta.modified().ok()?;
    let age = SystemTime::now().duration_since(modified).ok()?;
    Some(age <= threshold)
}

fn effective_transcript_path(storage: &StorageConfig, record: &SessionRecord) -> Option<PathBuf> {
    if let Some(tp) = record.transcript_path.as_deref() {
        return Some(PathBuf::from(tp));
    }

    // Best-effort: derive transcript path from the Claude project dir + session_id.
    // This matches Claude Code's encoding scheme (lossy '/' -> '-') and is sufficient for local use.
    let base = record.project_dir.as_deref().unwrap_or(&record.cwd);
    let base = normalize_path(base);
    if base.is_empty() {
        return None;
    }

    let encoded = base.replace('/', "-");
    Some(
        storage
            .claude_projects_dir()
            .join(encoded)
            .join(format!("{}.jsonl", record.session_id)),
    )
}

fn downshift_busy_if_transcript_quiet(
    storage: &StorageConfig,
    record: &SessionRecord,
    state: SessionState,
    threshold: Duration,
) -> Option<SessionState> {
    if !matches!(state, SessionState::Working | SessionState::Compacting) {
        return None;
    }

    if record.active_subagent_count > 0 {
        return None;
    }

    if record
        .last_event
        .as_ref()
        .and_then(|event| event.hook_event_name.as_deref())
        == Some("PreToolUse")
    {
        return None;
    }

    let tp = effective_transcript_path(storage, record)?;
    match transcript_is_recent(&tp, threshold) {
        Some(true) => None,
        Some(false) => Some(SessionState::Ready),
        None => None,
    }
}

fn record_is_recent(record: &SessionRecord, threshold: Duration) -> bool {
    let age_secs = Utc::now()
        .signed_duration_since(record.updated_at)
        .num_seconds();
    if age_secs < 0 {
        return true;
    }
    age_secs as u64 <= threshold.as_secs()
}

fn is_parent_fallback(record_cwd: &str, project_path: &str) -> bool {
    let record_norm = normalize_path(record_cwd);
    let project_norm = normalize_path(project_path);
    if record_norm == project_norm {
        return false;
    }
    if record_norm == "/" {
        return project_norm != "/";
    }
    let prefix = format!("{}/", record_norm);
    project_norm.starts_with(&prefix)
}

pub(crate) fn recent_session_record_for_project<'a>(
    store: &'a StateStore,
    project_path: &str,
    threshold: Duration,
) -> Option<&'a SessionRecord> {
    let record = store.find_by_cwd(project_path)?;
    let record_cwd_norm = normalize_path(&record.cwd);
    let project_norm = normalize_path(project_path);
    let record_is_exact = record_cwd_norm == project_norm;
    let record_is_child = if project_norm == "/" {
        record_cwd_norm != "/" && record_cwd_norm.starts_with("/")
    } else {
        record_cwd_norm.starts_with(&format!("{}/", project_norm))
    };
    let record_path_for_fallback = if record_is_exact || record_is_child {
        record.cwd.as_str()
    } else {
        record.project_dir.as_deref().unwrap_or(&record.cwd)
    };
    if is_parent_fallback(record_path_for_fallback, project_path) {
        return None;
    }
    if !record_is_recent(record, threshold) {
        return None;
    }
    Some(record)
}

/// Detects session state using the v2 state module.
/// Uses session-ID keyed state file and lock detection for reliable state.
pub fn detect_session_state(project_path: &str) -> ProjectSessionState {
    detect_session_state_with_storage(&StorageConfig::default(), project_path)
}

pub fn detect_session_state_with_storage(
    storage: &StorageConfig,
    project_path: &str,
) -> ProjectSessionState {
    // Lock directories are in ~/.claude/sessions/ (Claude Code writes them)
    let lock_dir = storage.claude_root().join("sessions");
    // State file is in ~/.capacitor/sessions.json (Capacitor's namespace)
    let state_file = storage.sessions_file();

    let store = StateStore::load(&state_file).unwrap_or_else(|_| StateStore::new(&state_file));

    let resolved = resolve_state_with_details(&lock_dir, &store, project_path);

    match resolved {
        Some(details) => {
            let record = details
                .session_id
                .as_ref()
                .and_then(|sid| store.get_by_session_id(sid));
            let mut working_on = record.and_then(|r| r.working_on.clone());
            let mut state = details.state;
            let mut state_changed_at = record.map(|r| r.state_changed_at.to_rfc3339());

            // If Claude is running (lock exists) but we never receive a Stop event
            // (e.g. user interrupt/cancel), the state can get stuck in Working.
            // Use transcript activity as a lightweight, read-only signal of "still producing output".
            if let Some(r) = record {
                if r.is_stale() {
                    state = SessionState::Ready;
                    state_changed_at = Some(Utc::now().to_rfc3339());
                    working_on = None;
                } else if let Some(new_state) = downshift_busy_if_transcript_quiet(
                    storage,
                    r,
                    state,
                    ACTIVE_TRANSCRIPT_ACTIVITY_TTL,
                ) {
                    state = new_state;
                    state_changed_at = Some(Utc::now().to_rfc3339());
                }
            }

            ProjectSessionState {
                state,
                state_changed_at,
                session_id: details.session_id,
                working_on,
                context: None,
                is_locked: true,
            }
        }
        None => {
            if let Some(record) =
                recent_session_record_for_project(&store, project_path, NO_LOCK_STATE_TTL)
            {
                let mut state = record.state;
                let mut state_changed_at = Some(record.state_changed_at.to_rfc3339());

                // Even without a lock, avoid "stuck Working" after user interrupts:
                // if the transcript is quiet, treat the session as Ready (awaiting input).
                if let Some(new_state) = downshift_busy_if_transcript_quiet(
                    storage,
                    record,
                    state,
                    ACTIVE_TRANSCRIPT_ACTIVITY_TTL,
                ) {
                    state = new_state;
                    state_changed_at = Some(Utc::now().to_rfc3339());
                }

                return ProjectSessionState {
                    state,
                    state_changed_at,
                    session_id: Some(record.session_id.clone()),
                    working_on: record.working_on.clone(),
                    context: None,
                    is_locked: false,
                };
            }

            // No direct session found - check for file activity in this project
            // This enables monorepo package tracking where cwd != project_path
            let activity_file = storage.file_activity_file();
            let activity_store = ActivityStore::load(&activity_file);

            if activity_store
                .has_recent_activity_in_path(project_path, crate::activity::ACTIVITY_THRESHOLD)
            {
                // Recent file edits in this project from a session elsewhere
                ProjectSessionState {
                    state: SessionState::Working,
                    state_changed_at: None,
                    session_id: None, // We don't know which session (could track in activity)
                    working_on: None,
                    context: None,
                    is_locked: false, // No lock at this path, but still working
                }
            } else {
                ProjectSessionState {
                    state: SessionState::Idle,
                    state_changed_at: None,
                    session_id: None,
                    working_on: None,
                    context: None,
                    is_locked: false,
                }
            }
        }
    }
}

/// Gets all session states using v2 state resolution.
/// Uses session-ID keyed state file and lock detection for reliable state.
/// Parent/child inheritance is handled by the resolver.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    get_all_session_states_with_storage(&StorageConfig::default(), project_paths)
}

pub fn get_all_session_states_with_storage(
    storage: &StorageConfig,
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    for path in project_paths {
        states.insert(
            path.clone(),
            detect_session_state_with_storage(storage, path),
        );
    }

    states
}

/// Project status as stored in .claude/hud-status.json within each project.
#[derive(Debug, serde::Serialize, serde::Deserialize, Clone, Default, uniffi::Record)]
pub struct ProjectStatus {
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub status: Option<String>,
    pub blocker: Option<String>,
    pub updated_at: Option<String>,
}

/// Reads project status from a project's .claude/hud-status.json file.
pub fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
    let status_path = Path::new(project_path)
        .join(".claude")
        .join("hud-status.json");

    if status_path.exists() {
        fs::read_to_string(&status_path)
            .ok()
            .and_then(|content| serde_json::from_str(&content).ok())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration as ChronoDuration, Utc};
    #[cfg(unix)]
    use std::os::unix::ffi::OsStrExt;
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn setup_storage() -> (TempDir, StorageConfig) {
        let temp = TempDir::new().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        fs::create_dir_all(&capacitor_root).unwrap();
        fs::create_dir_all(&claude_root).unwrap();
        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        (temp, storage)
    }

    fn setup_storage_with_sessions_dir() -> (TempDir, StorageConfig, PathBuf) {
        let (temp, storage) = setup_storage();
        let sessions_dir = storage.claude_root().join("sessions");
        fs::create_dir_all(&sessions_dir).unwrap();
        (temp, storage, sessions_dir)
    }

    #[cfg(unix)]
    fn set_mtime_seconds_ago(path: &Path, seconds_ago: u64) {
        use libc::timeval;
        use std::ffi::CString;
        use std::time::{SystemTime, UNIX_EPOCH};

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let target = now.saturating_sub(seconds_ago) as i64;

        let times = [
            timeval {
                tv_sec: target,
                tv_usec: 0,
            },
            timeval {
                tv_sec: target,
                tv_usec: 0,
            },
        ];

        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let rc = unsafe { libc::utimes(c_path.as_ptr(), times.as_ptr()) };
        assert_eq!(rc, 0, "utimes failed for {}", path.display());
    }

    #[test]
    fn test_detect_session_state_downshifts_stale_working_when_transcript_quiet() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions_dir();
        let project_path = "/tmp/hud-core-test-transcript-quiet";

        // Create an active lock for this project
        crate::state::lock::tests_helper::create_lock(
            &sessions_dir,
            std::process::id(),
            project_path,
        );

        // Write a transcript file and make it "old" by setting mtime into the past
        let transcript_path = storage
            .claude_root()
            .join("projects/-tmp-hud-core-test-transcript-quiet/s1.jsonl");
        fs::create_dir_all(transcript_path.parent().unwrap()).unwrap();
        fs::write(&transcript_path, "hello\n").unwrap();

        #[cfg(unix)]
        {
            set_mtime_seconds_ago(
                &transcript_path,
                ACTIVE_TRANSCRIPT_ACTIVITY_TTL.as_secs() + 5,
            );
        }

        // Create a working record with transcript_path (v3 schema)
        let now = Utc::now().to_rfc3339();
        let state_json = format!(
            r#"{{
  "version": 3,
  "sessions": {{
    "s1": {{
      "session_id": "s1",
      "cwd": "{cwd}",
      "state": "working",
      "updated_at": "{now}",
      "state_changed_at": "{now}",
      "transcript_path": "{tp}",
      "project_dir": "{cwd}"
    }}
  }}
}}"#,
            cwd = project_path,
            now = now,
            tp = transcript_path.to_string_lossy()
        );
        fs::write(storage.sessions_file(), state_json).unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);
        assert_eq!(state.state, SessionState::Ready);
        assert!(state.is_locked);
    }

    #[test]
    fn test_detect_session_state_keeps_working_during_tool_use_when_transcript_quiet() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions_dir();
        let project_path = "/tmp/hud-core-test-transcript-tool";

        crate::state::lock::tests_helper::create_lock(
            &sessions_dir,
            std::process::id(),
            project_path,
        );

        let transcript_path = storage
            .claude_root()
            .join("projects/-tmp-hud-core-test-transcript-tool/s1.jsonl");
        fs::create_dir_all(transcript_path.parent().unwrap()).unwrap();
        fs::write(&transcript_path, "hello\n").unwrap();

        #[cfg(unix)]
        {
            set_mtime_seconds_ago(
                &transcript_path,
                ACTIVE_TRANSCRIPT_ACTIVITY_TTL.as_secs() + 5,
            );
        }

        let now = Utc::now().to_rfc3339();
        let state_json = format!(
            r#"{{
  "version": 3,
  "sessions": {{
    "s1": {{
      "session_id": "s1",
      "cwd": "{cwd}",
      "state": "working",
      "updated_at": "{now}",
      "state_changed_at": "{now}",
      "transcript_path": "{tp}",
      "project_dir": "{cwd}",
      "last_event": {{
        "hook_event_name": "PreToolUse",
        "at": "{now}",
        "tool_name": "Bash"
      }}
    }}
  }}
}}"#,
            cwd = project_path,
            now = now,
            tp = transcript_path.to_string_lossy()
        );
        fs::write(storage.sessions_file(), state_json).unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);
        assert_eq!(state.state, SessionState::Working);
        assert!(state.is_locked);
    }

    #[test]
    fn test_detect_session_state_downshifts_stale_working_without_lock_when_transcript_quiet() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-transcript-quiet-unlocked";

        // Write a transcript file and make it "old"
        let transcript_path = storage
            .claude_root()
            .join("projects/-tmp-hud-core-test-transcript-quiet-unlocked/s1.jsonl");
        fs::create_dir_all(transcript_path.parent().unwrap()).unwrap();
        fs::write(&transcript_path, "hello\n").unwrap();

        #[cfg(unix)]
        {
            set_mtime_seconds_ago(
                &transcript_path,
                ACTIVE_TRANSCRIPT_ACTIVITY_TTL.as_secs() + 5,
            );
        }

        // Create a working record with transcript_path (v3 schema)
        let now = Utc::now().to_rfc3339();
        let state_json = format!(
            r#"{{
  "version": 3,
  "sessions": {{
    "s1": {{
      "session_id": "s1",
      "cwd": "{cwd}",
      "state": "working",
      "updated_at": "{now}",
      "state_changed_at": "{now}",
      "transcript_path": "{tp}",
      "project_dir": "{cwd}"
    }}
  }}
}}"#,
            cwd = project_path,
            now = now,
            tp = transcript_path.to_string_lossy()
        );
        fs::write(storage.sessions_file(), state_json).unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);
        assert_eq!(state.state, SessionState::Ready);
        assert!(!state.is_locked);
    }

    #[test]
    fn test_detect_session_state_returns_idle_for_unknown() {
        let (_temp, storage) = setup_storage();
        let state = detect_session_state_with_storage(
            &storage,
            "/definitely/not/a/real/project/path/xyz123",
        );
        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
        assert!(state.working_on.is_none());
    }

    #[test]
    fn test_detect_session_state_ready_without_lock_when_recent() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-recent-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Ready);
        assert!(!state.is_locked);
        assert_eq!(state.session_id.as_deref(), Some("session-1"));
        assert!(state.state_changed_at.is_some());
    }

    #[test]
    fn test_detect_session_state_ignores_stale_record_without_lock() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-stale-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        store.set_timestamp_for_test("session-1", Utc::now() - ChronoDuration::minutes(10));
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
    }

    #[test]
    fn test_detect_session_state_ready_when_record_stale_with_lock() {
        use crate::state::lock::tests_helper::create_lock;

        let (_temp, storage, sessions_dir) = setup_storage_with_sessions_dir();
        let project_path = "/tmp/hud-core-test-stale-locked";
        create_lock(&sessions_dir, std::process::id(), project_path);

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Waiting, project_path);
        let stale_time = Utc::now() - ChronoDuration::minutes(10);
        store.set_timestamp_for_test("session-1", stale_time);
        store.set_state_changed_at_for_test("session-1", stale_time);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Ready);
        assert!(state.is_locked);
        assert_eq!(state.session_id.as_deref(), Some("session-1"));
        assert!(state.working_on.is_none());
        assert!(state.state_changed_at.is_some());
    }

    #[test]
    fn test_detect_session_state_accepts_exact_cwd_when_project_dir_is_parent() {
        let (_temp, storage) = setup_storage();
        let parent_path = "/tmp/hud-core-test-parent-exact";
        let project_path = "/tmp/hud-core-test-parent-exact/child";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        store.set_project_dir_for_test("session-1", Some(parent_path));
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Ready);
        assert!(!state.is_locked);
        assert_eq!(state.session_id.as_deref(), Some("session-1"));
    }

    #[test]
    fn test_detect_session_state_ignores_parent_state_without_lock() {
        let (_temp, storage) = setup_storage();
        let parent_path = "/tmp/hud-core-test-parent";
        let child_path = "/tmp/hud-core-test-parent/child";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, parent_path);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, child_path);

        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
    }

    #[test]
    fn test_detect_session_state_sets_state_changed_at_for_lock() {
        use crate::state::lock::tests_helper::create_lock;

        let (_temp, storage, sessions_dir) = setup_storage_with_sessions_dir();
        let project_path = "/tmp/hud-core-test-locked-ready";
        create_lock(&sessions_dir, std::process::id(), project_path);

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Working, project_path);
        let expected = Utc::now() - ChronoDuration::minutes(2);
        store.set_timestamp_for_test("session-1", expected);
        store.set_state_changed_at_for_test("session-1", expected);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Working);
        assert!(state.is_locked);
        assert_eq!(state.state_changed_at, Some(expected.to_rfc3339()));
    }

    #[test]
    fn test_get_all_session_states_empty_input() {
        let (_temp, storage) = setup_storage();
        let paths: Vec<String> = vec![];
        let states = get_all_session_states_with_storage(&storage, &paths);
        assert!(states.is_empty());
    }

    #[test]
    fn test_get_all_session_states_multiple_paths() {
        let (_temp, storage) = setup_storage();
        let paths = vec![
            "/fake/path/one".to_string(),
            "/fake/path/two".to_string(),
            "/fake/path/three".to_string(),
        ];
        let states = get_all_session_states_with_storage(&storage, &paths);

        assert_eq!(states.len(), 3);
        assert!(states.contains_key("/fake/path/one"));
        assert!(states.contains_key("/fake/path/two"));
        assert!(states.contains_key("/fake/path/three"));
    }

    #[test]
    fn test_project_status_default() {
        let status = ProjectStatus::default();
        assert!(status.working_on.is_none());
        assert!(status.next_step.is_none());
        assert!(status.status.is_none());
        assert!(status.blocker.is_none());
        assert!(status.updated_at.is_none());
    }

    #[test]
    fn test_project_status_serialization() {
        let status = ProjectStatus {
            working_on: Some("Building feature X".to_string()),
            next_step: Some("Write tests".to_string()),
            status: Some("in_progress".to_string()),
            blocker: None,
            updated_at: Some("2024-01-01T00:00:00Z".to_string()),
        };

        let json = serde_json::to_string(&status).unwrap();
        let deserialized: ProjectStatus = serde_json::from_str(&json).unwrap();

        assert_eq!(
            deserialized.working_on,
            Some("Building feature X".to_string())
        );
        assert_eq!(deserialized.next_step, Some("Write tests".to_string()));
        assert!(deserialized.blocker.is_none());
    }

    #[test]
    fn test_read_project_status_missing_file() {
        let result = read_project_status("/definitely/not/a/real/path/xyz");
        assert!(result.is_none());
    }
}
