use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptDiscovery {
    pub session_id: String,
    pub project_path: String,
    pub file_path: PathBuf,
    pub file_mtime_rfc3339: String,
    pub file_size_bytes: u64,
}

pub fn scan_for_sessions(claude_root: &Path) -> Vec<TranscriptDiscovery> {
    let projects_dir = claude_root.join("projects");
    let entries = match std::fs::read_dir(&projects_dir) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };

    let mut discoveries = Vec::new();

    for entry in entries.flatten() {
        let project_dir = entry.path();
        if !project_dir.is_dir() {
            continue;
        }

        let project_path = resolve_project_path(&project_dir);
        let Ok(files) = std::fs::read_dir(&project_dir) else {
            continue;
        };

        for file_entry in files.flatten() {
            let file_path = file_entry.path();
            if file_path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }

            let session_id = match file_path.file_stem().and_then(|s| s.to_str()) {
                Some(stem) => stem.to_string(),
                None => continue,
            };

            let metadata = match std::fs::metadata(&file_path) {
                Ok(m) => m,
                Err(_) => continue,
            };

            let mtime_rfc3339 = match metadata.modified() {
                Ok(mtime) => {
                    let dt: chrono::DateTime<chrono::Utc> = mtime.into();
                    dt.to_rfc3339()
                }
                Err(_) => continue,
            };

            discoveries.push(TranscriptDiscovery {
                session_id,
                project_path: project_path.clone(),
                file_path,
                file_mtime_rfc3339: mtime_rfc3339,
                file_size_bytes: metadata.len(),
            });
        }
    }

    discoveries
}

fn resolve_project_path(project_dir: &Path) -> String {
    let project_path_file = project_dir.join(".project_path");
    if let Ok(content) = std::fs::read_to_string(&project_path_file) {
        let trimmed = content.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    project_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup_project(root: &Path, slug: &str, project_path: Option<&str>) -> PathBuf {
        let project_dir = root.join("projects").join(slug);
        fs::create_dir_all(&project_dir).unwrap();
        if let Some(pp) = project_path {
            fs::write(project_dir.join(".project_path"), pp).unwrap();
        }
        project_dir
    }

    fn add_session(project_dir: &Path, session_id: &str) {
        fs::write(
            project_dir.join(format!("{session_id}.jsonl")),
            r#"{"type":"user","content":"hello"}"#,
        )
        .unwrap();
    }

    #[test]
    fn scan_finds_sessions_from_jsonl_files() {
        let tmp = TempDir::new().unwrap();
        let project_dir = setup_project(tmp.path(), "my-project", Some("/repo/capacitor"));
        add_session(&project_dir, "session-abc-123");
        add_session(&project_dir, "session-def-456");

        let mut results = scan_for_sessions(tmp.path());
        results.sort_by(|a, b| a.session_id.cmp(&b.session_id));

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].session_id, "session-abc-123");
        assert_eq!(results[0].project_path, "/repo/capacitor");
        assert!(results[0].file_size_bytes > 0);
        assert_eq!(results[1].session_id, "session-def-456");
        assert_eq!(results[1].project_path, "/repo/capacitor");
    }

    #[test]
    fn scan_ignores_non_jsonl_files() {
        let tmp = TempDir::new().unwrap();
        let project_dir = setup_project(tmp.path(), "proj", Some("/repo"));
        add_session(&project_dir, "real-session");
        fs::write(project_dir.join("notes.json"), "{}").unwrap();
        fs::write(project_dir.join("readme.txt"), "hi").unwrap();

        let results = scan_for_sessions(tmp.path());
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "real-session");
    }

    #[test]
    fn scan_uses_directory_name_when_no_project_path_file() {
        let tmp = TempDir::new().unwrap();
        let project_dir = setup_project(tmp.path(), "fallback-slug", None);
        add_session(&project_dir, "sess-1");

        let results = scan_for_sessions(tmp.path());
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].project_path, "fallback-slug");
    }

    #[test]
    fn scan_handles_empty_projects_dir() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("projects")).unwrap();

        let results = scan_for_sessions(tmp.path());
        assert!(results.is_empty());
    }

    #[test]
    fn scan_handles_missing_projects_dir() {
        let tmp = TempDir::new().unwrap();
        let results = scan_for_sessions(tmp.path());
        assert!(results.is_empty());
    }

    #[test]
    fn scan_produces_valid_rfc3339_timestamps() {
        let tmp = TempDir::new().unwrap();
        let project_dir = setup_project(tmp.path(), "proj", Some("/repo"));
        add_session(&project_dir, "sess-ts");

        let results = scan_for_sessions(tmp.path());
        assert_eq!(results.len(), 1);
        chrono::DateTime::parse_from_rfc3339(&results[0].file_mtime_rfc3339)
            .expect("mtime should be valid RFC3339");
    }
}
