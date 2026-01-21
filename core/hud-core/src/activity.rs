//! File activity tracking for project state attribution.
//!
//! Tracks which files have been edited by Claude sessions and attributes
//! that activity to projects using boundary detection. This enables
//! accurate project state even in monorepo scenarios.
//!
//! ## Design Principles (from Rust Engineering guide)
//!
//! - **Durable-first**: Write to disk before returning
//! - **Atomic writes**: Use temp file + rename for crash safety
//! - **Graceful degradation**: Missing/corrupt files → empty state
//! - **Conservative**: Prefer false negatives over false positives
//! Activity is a secondary signal; lock/state data takes precedence when present.

use crate::boundaries::{find_project_boundary, normalize_path};
use crate::error::{HudError, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

/// Activity is considered "recent" if within this threshold.
pub const ACTIVITY_THRESHOLD: Duration = Duration::from_secs(5 * 60); // 5 minutes

/// Entries older than this are cleaned up.
pub const CLEANUP_THRESHOLD: Duration = Duration::from_secs(60 * 60); // 1 hour

/// State file name.
/// Note: Activity data is stored in `~/.capacitor/file-activity.json` (via StorageConfig).
#[deprecated(note = "Use StorageConfig::file_activity_file() instead")]
pub const ACTIVITY_STATE_FILE: &str = "file-activity.json";

/// Current version of the activity store format.
pub const ACTIVITY_STORE_VERSION: u32 = 1;

/// A single file activity event.
///
/// Uses `#[serde(default)]` for forward compatibility - if future versions
/// add fields, old data will still parse correctly.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct FileActivity {
    /// Absolute path to the project this activity is attributed to
    #[serde(default)]
    pub project_path: String,
    /// Absolute path to the file that was accessed
    #[serde(default)]
    pub file_path: String,
    /// The tool that accessed the file (Edit, Write, Read)
    #[serde(default)]
    pub tool: String,
    /// ISO 8601 timestamp of when the activity occurred
    #[serde(default)]
    pub timestamp: String,
}

/// Activity records for a single session.
///
/// Uses `#[serde(default)]` on all fields for forward compatibility.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionActivity {
    /// Working directory where the session started
    #[serde(default)]
    pub cwd: String,
    /// Process ID of the Claude session (if known)
    #[serde(default)]
    pub pid: Option<u32>,
    /// Recent file activity, newest first
    #[serde(default)]
    pub activity: Vec<FileActivity>,
}

/// The complete activity store, persisted to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityStore {
    /// Format version for forward compatibility
    pub version: u32,
    /// Activity by session ID
    #[serde(default)]
    pub sessions: HashMap<String, SessionActivity>,
}

impl Default for ActivityStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ActivityStore {
    /// Creates a new empty activity store.
    pub fn new() -> Self {
        Self {
            version: ACTIVITY_STORE_VERSION,
            sessions: HashMap::new(),
        }
    }

    /// Loads the activity store from a file path.
    ///
    /// Returns an empty store if the file doesn't exist or is corrupt.
    /// This follows the graceful degradation principle.
    ///
    /// Handles two formats:
    /// - Native Rust format: activity array with project_path
    /// - Hook script format: files array with file_path only (boundary detection applied on load)
    ///
    /// Version handling:
    /// - If version > ACTIVITY_STORE_VERSION, returns empty store (future format)
    /// - If version is missing or <= current, attempts to parse
    pub fn load(path: &Path) -> Self {
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => return Self::new(),
        };

        // First, check the version to avoid parsing incompatible future formats
        #[derive(Deserialize)]
        struct VersionCheck {
            #[serde(default)]
            version: u32,
        }

        if let Ok(check) = serde_json::from_str::<VersionCheck>(&content) {
            if check.version > ACTIVITY_STORE_VERSION {
                // Future version - gracefully degrade to empty store
                // This prevents corruption from misinterpreting new formats
                return Self::new();
            }
        }

        // Try to parse as native format first
        if let Ok(store) = serde_json::from_str::<ActivityStore>(&content) {
            // Determine if this is native format by checking structure:
            // - Native format uses "activity" array with "project_path" field
            // - Hook format uses "files" array without "project_path" field
            // - Empty store (no sessions or no activity) is treated as native
            let is_native = store.sessions.is_empty()
                || store.sessions.values().all(|s| {
                    s.activity.is_empty() || s.activity.iter().any(|a| !a.project_path.is_empty())
                });

            if is_native {
                return store;
            }
        }

        // Try to parse as hook script format
        // Hook format: {"version":1,"sessions":{"sid":{"cwd":"...","files":[{"file_path":"...","tool":"...","timestamp":"..."}]}}}
        #[derive(Deserialize)]
        struct HookFileActivity {
            file_path: String,
            #[serde(default)]
            tool: String,
            #[serde(default)]
            timestamp: String,
        }

        #[derive(Deserialize)]
        struct HookSessionActivity {
            #[serde(default)]
            cwd: String,
            #[serde(default)]
            files: Vec<HookFileActivity>,
        }

        #[derive(Deserialize)]
        struct HookActivityStore {
            #[serde(default)]
            sessions: HashMap<String, HookSessionActivity>,
        }

        let hook_store: HookActivityStore = match serde_json::from_str(&content) {
            Ok(s) => s,
            Err(_) => return Self::new(),
        };

        // Convert hook format to native format, performing boundary detection
        let mut native = Self::new();
        for (session_id, hook_session) in hook_store.sessions {
            let mut activity = Vec::new();
            for file in hook_session.files {
                // Determine project path using boundary detection
                let project_path = find_project_boundary(&file.file_path)
                    .map(|b| b.path)
                    .unwrap_or_else(|| hook_session.cwd.clone());

                activity.push(FileActivity {
                    project_path,
                    file_path: file.file_path,
                    tool: file.tool,
                    timestamp: file.timestamp,
                });
            }

            native.sessions.insert(
                session_id,
                SessionActivity {
                    cwd: hook_session.cwd,
                    pid: None,
                    activity,
                },
            );
        }

        native
    }

    /// Saves the activity store to a file path atomically.
    ///
    /// Uses temp file + rename for crash safety.
    pub fn save(&self, path: &Path) -> Result<()> {
        use std::io::Write;

        let content = serde_json::to_string_pretty(self).map_err(|e| HudError::Json {
            context: "Failed to serialize activity store".to_string(),
            source: e,
        })?;

        // Write to temp file in same directory, then rename (atomic on same filesystem)
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        let mut tmp = tempfile::NamedTempFile::new_in(dir).map_err(|e| HudError::Io {
            context: "Failed to create temp file".to_string(),
            source: e,
        })?;

        tmp.write_all(content.as_bytes())
            .map_err(|e| HudError::Io {
                context: "Failed to write temp file".to_string(),
                source: e,
            })?;

        tmp.flush().map_err(|e| HudError::Io {
            context: "Failed to flush temp file".to_string(),
            source: e,
        })?;

        tmp.persist(path).map_err(|e| HudError::Io {
            context: "Failed to persist file".to_string(),
            source: e.error,
        })?;

        Ok(())
    }

    /// Records a file activity event.
    ///
    /// Automatically attributes the activity to a project using boundary detection.
    /// If no project boundary is found, the activity is attributed to the session's cwd.
    pub fn record_activity(
        &mut self,
        session_id: &str,
        cwd: &str,
        file_path: &str,
        tool: &str,
        timestamp: &str,
    ) {
        // Determine which project this file belongs to
        let project_path = find_project_boundary(file_path)
            .map(|b| b.path)
            .unwrap_or_else(|| cwd.to_string());

        let activity = FileActivity {
            project_path,
            file_path: file_path.to_string(),
            tool: tool.to_string(),
            timestamp: timestamp.to_string(),
        };

        // Get or create session entry
        let session = self
            .sessions
            .entry(session_id.to_string())
            .or_insert_with(|| SessionActivity {
                cwd: cwd.to_string(),
                pid: None,
                activity: Vec::new(),
            });

        // Add activity (newest first)
        session.activity.insert(0, activity);
    }

    /// Checks if a project has activity within the given threshold.
    ///
    /// Returns true if any session has recent activity attributed to this project.
    /// Uses normalized path comparison to handle trailing slash inconsistencies.
    pub fn has_recent_activity(&self, project_path: &str, threshold: Duration) -> bool {
        let normalized_query = normalize_path(project_path);
        for session in self.sessions.values() {
            for activity in &session.activity {
                if normalize_path(&activity.project_path) == normalized_query
                    && is_within_threshold(&activity.timestamp, threshold)
                {
                    return true;
                }
            }
        }
        false
    }

    /// Checks if a project has recent activity with file paths inside the project.
    ///
    /// This is stricter than `has_recent_activity`, guarding against
    /// misattributed project paths by verifying the file path as well.
    pub fn has_recent_activity_in_path(&self, project_path: &str, threshold: Duration) -> bool {
        let normalized_query = normalize_path(project_path);
        let prefix = if normalized_query == "/" {
            "/".to_string()
        } else {
            format!("{}/", normalized_query)
        };

        for session in self.sessions.values() {
            for activity in &session.activity {
                if normalize_path(&activity.project_path) != normalized_query {
                    continue;
                }

                if !is_within_threshold(&activity.timestamp, threshold) {
                    continue;
                }

                let activity_path = normalize_path(&activity.file_path);
                let matches_path = if normalized_query == "/" {
                    activity_path.starts_with('/')
                } else {
                    activity_path == normalized_query || activity_path.starts_with(&prefix)
                };

                if matches_path {
                    return true;
                }
            }
        }

        false
    }

    /// Gets all projects with recent activity for a session.
    pub fn active_projects_for_session(
        &self,
        session_id: &str,
        threshold: Duration,
    ) -> Vec<String> {
        let Some(session) = self.sessions.get(session_id) else {
            return Vec::new();
        };

        let mut projects: Vec<String> = session
            .activity
            .iter()
            .filter(|a| is_within_threshold(&a.timestamp, threshold))
            .map(|a| a.project_path.clone())
            .collect();

        // Remove duplicates while preserving order
        let mut seen = std::collections::HashSet::new();
        projects.retain(|p| seen.insert(p.clone()));

        projects
    }

    /// Removes entries older than the cleanup threshold.
    pub fn cleanup_old_entries(&mut self, threshold: Duration) {
        for session in self.sessions.values_mut() {
            session
                .activity
                .retain(|a| is_within_threshold(&a.timestamp, threshold));
        }

        // Remove sessions with no activity left
        self.sessions.retain(|_, s| !s.activity.is_empty());
    }

    /// Removes all activity for a session (called on SessionEnd).
    pub fn remove_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    /// Gets the most recently active project for a session.
    pub fn most_recent_project(&self, session_id: &str) -> Option<String> {
        self.sessions
            .get(session_id)?
            .activity
            .first()
            .map(|a| a.project_path.clone())
    }
}

/// Parses an ISO 8601 timestamp to epoch seconds.
fn parse_timestamp(timestamp: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(timestamp)
        .ok()
        .map(|dt| dt.timestamp())
}

/// Gets the current time as an ISO 8601 string.
pub fn now_iso8601() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Checks if a timestamp is within the threshold of now.
fn is_within_threshold(timestamp: &str, threshold: Duration) -> bool {
    let Some(ts) = parse_timestamp(timestamp) else {
        return false;
    };
    let now = chrono::Utc::now().timestamp();
    let age = now.saturating_sub(ts);
    age >= 0 && age <= threshold.as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ========================================
    // Test helpers
    // ========================================

    fn create_test_dir() -> TempDir {
        TempDir::new().expect("Failed to create temp dir")
    }

    fn create_file(dir: &Path, name: &str) {
        fs::write(dir.join(name), "").expect("Failed to create file");
    }

    fn create_dir(dir: &Path, name: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        fs::create_dir_all(&path).expect("Failed to create dir");
        path
    }

    fn recent_timestamp() -> String {
        now_iso8601()
    }

    fn old_timestamp() -> String {
        let old = chrono::Utc::now() - chrono::Duration::hours(2);
        old.to_rfc3339()
    }

    fn stale_timestamp() -> String {
        // Just outside the activity threshold (6 minutes ago)
        let stale = chrono::Utc::now() - chrono::Duration::minutes(6);
        stale.to_rfc3339()
    }

    // ========================================
    // Basic recording tests
    // ========================================

    #[test]
    fn records_file_activity() {
        let mut store = ActivityStore::new();
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        let src = create_dir(tmp.path(), "src");
        create_file(&src, "main.rs");

        let file = src.join("main.rs");
        let timestamp = recent_timestamp();

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            file.to_str().unwrap(),
            "Edit",
            &timestamp,
        );

        // Should have recorded the activity
        let session = store.sessions.get("session-1");
        assert!(session.is_some(), "Session should be created");

        let activity = &session.unwrap().activity;
        assert_eq!(activity.len(), 1, "Should have one activity");
        assert_eq!(activity[0].file_path, file.to_string_lossy());
        assert_eq!(activity[0].tool, "Edit");
    }

    #[test]
    fn attributes_activity_to_correct_project() {
        let mut store = ActivityStore::new();

        // Create a monorepo structure
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        let auth_pkg = create_dir(tmp.path(), "packages/auth");
        create_file(&auth_pkg, "CLAUDE.md");
        let auth_src = create_dir(&auth_pkg, "src");
        create_file(&auth_src, "login.ts");

        let file = auth_src.join("login.ts");
        let timestamp = recent_timestamp();

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(), // Running from monorepo root
            file.to_str().unwrap(),       // Editing auth package file
            "Edit",
            &timestamp,
        );

        let session = store.sessions.get("session-1").unwrap();
        let activity = &session.activity[0];

        // Should be attributed to auth package, not monorepo root
        assert_eq!(
            activity.project_path,
            auth_pkg.to_string_lossy(),
            "Activity should be attributed to the auth package"
        );
    }

    #[test]
    fn tracks_multiple_projects_per_session() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        // Create two packages
        let auth = create_dir(tmp.path(), "packages/auth");
        create_file(&auth, "CLAUDE.md");
        let auth_file = auth.join("index.ts");
        create_file(&auth, "index.ts");

        let api = create_dir(tmp.path(), "packages/api");
        create_file(&api, "CLAUDE.md");
        let api_file = api.join("routes.ts");
        create_file(&api, "routes.ts");

        let ts = recent_timestamp();

        // Edit files in both packages
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            auth_file.to_str().unwrap(),
            "Edit",
            &ts,
        );
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            api_file.to_str().unwrap(),
            "Write",
            &ts,
        );

        let session = store.sessions.get("session-1").unwrap();
        assert_eq!(session.activity.len(), 2, "Should have two activities");

        let projects: Vec<&str> = session
            .activity
            .iter()
            .map(|a| a.project_path.as_str())
            .collect();
        assert!(projects.contains(&auth.to_str().unwrap()));
        assert!(projects.contains(&api.to_str().unwrap()));
    }

    #[test]
    fn falls_back_to_cwd_when_no_boundary() {
        let mut store = ActivityStore::new();

        // Create a directory without any project markers
        let tmp = create_test_dir();
        create_file(tmp.path(), "random.txt");

        let timestamp = recent_timestamp();

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            tmp.path().join("random.txt").to_str().unwrap(),
            "Edit",
            &timestamp,
        );

        let session = store.sessions.get("session-1").unwrap();
        let activity = &session.activity[0];

        // Should fall back to cwd since no boundary found
        assert_eq!(
            activity.project_path,
            tmp.path().to_string_lossy(),
            "Should fall back to cwd when no project boundary"
        );
    }

    // ========================================
    // Activity window tests
    // ========================================

    #[test]
    fn activity_within_threshold_is_active() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_file(tmp.path(), "file.txt");

        let file = tmp.path().join("file.txt");
        let timestamp = recent_timestamp();

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            file.to_str().unwrap(),
            "Edit",
            &timestamp,
        );

        assert!(
            store.has_recent_activity(tmp.path().to_str().unwrap(), ACTIVITY_THRESHOLD),
            "Recent activity should be detected"
        );
    }

    #[test]
    fn activity_beyond_threshold_is_inactive() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_file(tmp.path(), "file.txt");

        let file = tmp.path().join("file.txt");
        let timestamp = stale_timestamp(); // 6 minutes ago

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            file.to_str().unwrap(),
            "Edit",
            &timestamp,
        );

        assert!(
            !store.has_recent_activity(tmp.path().to_str().unwrap(), ACTIVITY_THRESHOLD),
            "Stale activity should not be detected as recent"
        );
    }

    #[test]
    fn cleans_up_old_entries() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_file(tmp.path(), "file.txt");

        let file = tmp.path().join("file.txt");

        // Add an old activity
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            file.to_str().unwrap(),
            "Edit",
            &old_timestamp(),
        );

        // Add a recent activity
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            file.to_str().unwrap(),
            "Write",
            &recent_timestamp(),
        );

        let initial_count = store.sessions.get("session-1").unwrap().activity.len();
        assert_eq!(initial_count, 2);

        // Clean up entries older than 1 hour
        store.cleanup_old_entries(CLEANUP_THRESHOLD);

        let final_count = store.sessions.get("session-1").unwrap().activity.len();
        assert_eq!(final_count, 1, "Old activity should be cleaned up");
    }

    // ========================================
    // Query tests
    // ========================================

    #[test]
    fn finds_active_projects_for_session() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        let pkg1 = create_dir(tmp.path(), "pkg1");
        create_file(&pkg1, "CLAUDE.md");
        create_file(&pkg1, "file.txt");

        let pkg2 = create_dir(tmp.path(), "pkg2");
        create_file(&pkg2, "CLAUDE.md");
        create_file(&pkg2, "file.txt");

        let ts = recent_timestamp();

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            pkg1.join("file.txt").to_str().unwrap(),
            "Edit",
            &ts,
        );
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            pkg2.join("file.txt").to_str().unwrap(),
            "Edit",
            &ts,
        );

        let active = store.active_projects_for_session("session-1", ACTIVITY_THRESHOLD);

        assert_eq!(active.len(), 2);
        assert!(active.contains(&pkg1.to_string_lossy().to_string()));
        assert!(active.contains(&pkg2.to_string_lossy().to_string()));
    }

    #[test]
    fn checks_if_project_has_recent_activity() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        let active_pkg = create_dir(tmp.path(), "active");
        create_file(&active_pkg, "CLAUDE.md");
        create_file(&active_pkg, "file.txt");

        let inactive_pkg = create_dir(tmp.path(), "inactive");
        create_file(&inactive_pkg, "CLAUDE.md");

        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            active_pkg.join("file.txt").to_str().unwrap(),
            "Edit",
            &recent_timestamp(),
        );

        assert!(store.has_recent_activity(active_pkg.to_str().unwrap(), ACTIVITY_THRESHOLD));
        assert!(!store.has_recent_activity(inactive_pkg.to_str().unwrap(), ACTIVITY_THRESHOLD));
    }

    #[test]
    fn recent_activity_requires_file_path_within_project() {
        let mut store = ActivityStore::new();

        let project_path = "/tmp/hud-activity-project";
        let other_path = "/tmp/hud-activity-other/file.txt";

        store.sessions.insert(
            "session-1".to_string(),
            SessionActivity {
                cwd: project_path.to_string(),
                pid: None,
                activity: vec![FileActivity {
                    project_path: project_path.to_string(),
                    file_path: other_path.to_string(),
                    tool: "Edit".to_string(),
                    timestamp: recent_timestamp(),
                }],
            },
        );

        assert!(
            !store.has_recent_activity_in_path(project_path, ACTIVITY_THRESHOLD),
            "Activity outside the project path should not count"
        );
    }

    #[test]
    fn recent_activity_within_project_is_detected() {
        let mut store = ActivityStore::new();

        let project_path = "/tmp/hud-activity-project";
        let file_path = "/tmp/hud-activity-project/src/file.txt";

        store.sessions.insert(
            "session-1".to_string(),
            SessionActivity {
                cwd: project_path.to_string(),
                pid: None,
                activity: vec![FileActivity {
                    project_path: project_path.to_string(),
                    file_path: file_path.to_string(),
                    tool: "Edit".to_string(),
                    timestamp: recent_timestamp(),
                }],
            },
        );

        assert!(
            store.has_recent_activity_in_path(project_path, ACTIVITY_THRESHOLD),
            "Activity inside the project path should count"
        );
    }

    #[test]
    fn most_recent_project_returns_latest() {
        let mut store = ActivityStore::new();

        let tmp = create_test_dir();
        let pkg1 = create_dir(tmp.path(), "pkg1");
        create_file(&pkg1, "CLAUDE.md");
        create_file(&pkg1, "file.txt");

        let pkg2 = create_dir(tmp.path(), "pkg2");
        create_file(&pkg2, "CLAUDE.md");
        create_file(&pkg2, "file.txt");

        // Record pkg1 first, then pkg2
        let earlier = chrono::Utc::now() - chrono::Duration::seconds(30);
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            pkg1.join("file.txt").to_str().unwrap(),
            "Edit",
            &earlier.to_rfc3339(),
        );
        store.record_activity(
            "session-1",
            tmp.path().to_str().unwrap(),
            pkg2.join("file.txt").to_str().unwrap(),
            "Edit",
            &recent_timestamp(),
        );

        let most_recent = store.most_recent_project("session-1");
        assert_eq!(most_recent, Some(pkg2.to_string_lossy().to_string()));
    }

    // ========================================
    // State file tests
    // ========================================

    #[test]
    fn loads_existing_state_file() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("activity.json");

        // Write a valid state file
        let content = r#"{
            "version": 1,
            "sessions": {
                "session-1": {
                    "cwd": "/some/path",
                    "pid": 12345,
                    "activity": [
                        {
                            "project_path": "/some/project",
                            "file_path": "/some/project/file.txt",
                            "tool": "Edit",
                            "timestamp": "2026-01-16T18:00:00Z"
                        }
                    ]
                }
            }
        }"#;
        fs::write(&state_file, content).unwrap();

        let store = ActivityStore::load(&state_file);

        assert_eq!(store.version, 1);
        assert!(store.sessions.contains_key("session-1"));
        let session = store.sessions.get("session-1").unwrap();
        assert_eq!(session.cwd, "/some/path");
        assert_eq!(session.pid, Some(12345));
        assert_eq!(session.activity.len(), 1);
    }

    #[test]
    fn creates_state_file_if_missing() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("nonexistent.json");

        let store = ActivityStore::load(&state_file);

        // Should return empty store, not error
        assert_eq!(store.version, ACTIVITY_STORE_VERSION);
        assert!(store.sessions.is_empty());
    }

    #[test]
    fn handles_corrupted_state_file() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("corrupted.json");

        // Write invalid JSON
        fs::write(&state_file, "{ this is not valid json }").unwrap();

        let store = ActivityStore::load(&state_file);

        // Should return empty store, not error
        assert_eq!(store.version, ACTIVITY_STORE_VERSION);
        assert!(store.sessions.is_empty());
    }

    #[test]
    fn rejects_future_version() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("future.json");

        // Write a future version (higher than current)
        let future_content = format!(
            r#"{{"version": {}, "sessions": {{"session-1": {{"cwd": "/test", "activity": []}}}}}}"#,
            ACTIVITY_STORE_VERSION + 1
        );
        fs::write(&state_file, future_content).unwrap();

        let store = ActivityStore::load(&state_file);

        // Should return empty store to avoid misinterpreting future format
        assert_eq!(store.version, ACTIVITY_STORE_VERSION);
        assert!(store.sessions.is_empty());
    }

    #[test]
    fn accepts_current_version() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("current.json");

        // Write current version with data
        let content = format!(
            r#"{{"version": {}, "sessions": {{"session-1": {{"cwd": "/test", "activity": [{{"project_path": "/project", "file_path": "/project/file.rs", "tool": "Edit", "timestamp": "2026-01-16T18:00:00Z"}}]}}}}}}"#,
            ACTIVITY_STORE_VERSION
        );
        fs::write(&state_file, content).unwrap();

        let store = ActivityStore::load(&state_file);

        // Should load the data
        assert_eq!(store.version, ACTIVITY_STORE_VERSION);
        assert!(store.sessions.contains_key("session-1"));
    }

    #[test]
    fn atomic_write_prevents_corruption() {
        let tmp = create_test_dir();
        let state_file = tmp.path().join("activity.json");

        let mut store = ActivityStore::new();
        store.sessions.insert(
            "session-1".to_string(),
            SessionActivity {
                cwd: "/test".to_string(),
                pid: Some(123),
                activity: vec![],
            },
        );

        // Save should succeed
        let result = store.save(&state_file);
        assert!(result.is_ok());

        // File should exist and be valid JSON
        let content = fs::read_to_string(&state_file).unwrap();
        let parsed: serde_json::Result<ActivityStore> = serde_json::from_str(&content);
        assert!(parsed.is_ok());
    }

    #[test]
    fn removes_session_on_session_end() {
        let mut store = ActivityStore::new();

        store.sessions.insert(
            "session-1".to_string(),
            SessionActivity {
                cwd: "/test".to_string(),
                pid: Some(123),
                activity: vec![],
            },
        );

        assert!(store.sessions.contains_key("session-1"));

        store.remove_session("session-1");

        assert!(!store.sessions.contains_key("session-1"));
    }

    // ========================================
    // Helper function tests
    // ========================================

    #[test]
    fn parse_timestamp_handles_valid_rfc3339() {
        let ts = "2026-01-16T18:30:00Z";
        let result = parse_timestamp(ts);
        assert!(result.is_some());
    }

    #[test]
    fn parse_timestamp_handles_invalid_format() {
        let ts = "not a timestamp";
        let result = parse_timestamp(ts);
        assert!(result.is_none());
    }

    #[test]
    fn is_within_threshold_returns_true_for_recent() {
        let ts = now_iso8601();
        assert!(is_within_threshold(&ts, ACTIVITY_THRESHOLD));
    }

    #[test]
    fn is_within_threshold_returns_false_for_old() {
        let old = chrono::Utc::now() - chrono::Duration::hours(1);
        let ts = old.to_rfc3339();
        assert!(!is_within_threshold(&ts, ACTIVITY_THRESHOLD));
    }

    #[test]
    fn is_within_threshold_handles_invalid_timestamp() {
        assert!(!is_within_threshold("invalid", ACTIVITY_THRESHOLD));
    }
}
