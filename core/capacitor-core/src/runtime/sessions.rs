//! Session state management for Claude Code sessions.
//!
//! Currently this module only exposes project status file helpers.

use fs_err as fs;
use std::path::Path;

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
pub(crate) fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
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
    use fs_err as fs;
    use tempfile::TempDir;

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

    #[test]
    fn test_read_project_status_existing_file() {
        let temp = TempDir::new().unwrap();
        let project_dir = temp.path().join("project");
        let claude_dir = project_dir.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        let status_path = claude_dir.join("hud-status.json");
        fs::write(
            &status_path,
            r#"{"working_on":"Task A","status":"working","updated_at":"2026-02-23T00:00:00Z"}"#,
        )
        .unwrap();

        let result = read_project_status(project_dir.to_str().unwrap());
        assert_eq!(
            result.as_ref().and_then(|status| status.working_on.clone()),
            Some("Task A".to_string())
        );
        assert_eq!(
            result.as_ref().and_then(|status| status.status.clone()),
            Some("working".to_string())
        );
    }
}
