//! Project discovery, loading, and management.
//!
//! This module provides functionality for:
//! - Detecting project types from file indicators
//! - Building project metadata from paths
//! - Loading pinned projects with statistics

use crate::runtime_config::{
    load_hud_config_with_storage, load_stats_cache_with_storage, save_stats_cache_with_storage,
};
use crate::runtime_stats::compute_project_stats;
use crate::runtime_storage::StorageConfig;
use crate::runtime_types::{
    ShellProjectCatalogEntry, ShellProjectStats, ShellSuggestedProjectCandidate, StatsCache,
};
use fs_err as fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// Heuristic markers only; absence does not mean a directory is not a project.
/// Project type indicators - files that suggest a directory is a code project.
const PROJECT_INDICATORS: &[&str] = &[
    ".git",
    "package.json",
    "Cargo.toml",
    "pyproject.toml",
    "go.mod",
    "requirements.txt",
    "Gemfile",
    "CMakeLists.txt",
    "Makefile",
    "build.gradle",
    "pom.xml",
    ".gitignore",
    "tsconfig.json",
    "composer.json",
    "mix.exs",
    "pubspec.yaml",
];

/// Checks if a directory contains project indicators.
#[must_use]
pub fn has_project_indicators(project_path: &Path) -> bool {
    PROJECT_INDICATORS
        .iter()
        .any(|indicator| project_path.join(indicator).exists())
}

/// Formats a SystemTime as a human-readable relative time string.
pub fn format_relative_time(system_time: SystemTime) -> String {
    let now = SystemTime::now();
    let duration = now.duration_since(system_time).unwrap_or_default();
    let secs = duration.as_secs();

    if secs < 60 {
        "just now".to_string()
    } else if secs < 3600 {
        let mins = secs / 60;
        if mins == 1 {
            "1 minute ago".to_string()
        } else {
            format!("{} minutes ago", mins)
        }
    } else if secs < 86400 {
        let hours = secs / 3600;
        if hours == 1 {
            "1 hour ago".to_string()
        } else {
            format!("{} hours ago", hours)
        }
    } else if secs < 604800 {
        let days = secs / 86400;
        if days == 1 {
            "yesterday".to_string()
        } else {
            format!("{} days ago", days)
        }
    } else {
        let weeks = secs / 604800;
        if weeks == 1 {
            "1 week ago".to_string()
        } else {
            format!("{} weeks ago", weeks)
        }
    }
}

/// Extracts a preview of a CLAUDE.md file content.
pub fn get_claude_md_preview(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    let preview: String = content.chars().take(200).collect();
    if content.len() > 200 {
        Some(format!("{}...", preview.trim()))
    } else {
        Some(preview.trim().to_string())
    }
}

/// Counts JSONL session files in a project directory.
pub fn count_tasks_in_project(claude_projects_dir: &Path, encoded_name: &str) -> u32 {
    let project_dir = claude_projects_dir.join(encoded_name);
    if !project_dir.exists() {
        return 0;
    }

    fs::read_dir(&project_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                .count() as u32
        })
        .unwrap_or(0)
}

fn latest_session_activity_mtime(claude_project_dir: &Path) -> Option<SystemTime> {
    let mut most_recent_mtime: Option<SystemTime> = None;

    if let Ok(entries) = fs::read_dir(claude_project_dir) {
        for entry in entries.flatten() {
            let entry_path = entry.path();
            if !entry_path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
            {
                continue;
            }

            if entry_path
                .file_stem()
                .is_some_and(|stem| stem.to_string_lossy().starts_with("agent-"))
            {
                continue;
            }

            if let Ok(metadata) = entry_path.metadata() {
                if let Ok(mtime) = metadata.modified() {
                    if most_recent_mtime.map_or(true, |existing| mtime > existing) {
                        most_recent_mtime = Some(mtime);
                    }
                }
            }
        }
    }

    most_recent_mtime
}

/// Encodes a path for use as a Claude projects directory name.
pub fn encode_project_path(path: &str) -> String {
    path.replace('/', "-")
}

/// Attempts to resolve an encoded project path back to a real path.
pub fn try_resolve_encoded_path(encoded_name: &str) -> Option<String> {
    if encoded_name.is_empty() || !encoded_name.starts_with('-') {
        return None;
    }

    let without_leading = &encoded_name[1..];
    let parts: Vec<&str> = without_leading.split('-').collect();

    for num_parts in 1..=parts.len() {
        let prefix = parts[..num_parts].join("/");
        let candidate = format!("/{}", prefix);

        if PathBuf::from(&candidate).exists() {
            if num_parts == parts.len() {
                return Some(candidate);
            }

            let suffix = parts[num_parts..].join("-");
            let full_candidate = format!("{}/{}", candidate, suffix);
            if PathBuf::from(&full_candidate).exists() {
                return Some(full_candidate);
            }
        }
    }

    None
}

fn shell_project_stats(stats: crate::runtime_types::ProjectStats) -> ShellProjectStats {
    ShellProjectStats {
        total_input_tokens: stats.total_input_tokens,
        total_output_tokens: stats.total_output_tokens,
        total_cache_read_tokens: stats.total_cache_read_tokens,
        total_cache_creation_tokens: stats.total_cache_creation_tokens,
        opus_messages: stats.opus_messages,
        sonnet_messages: stats.sonnet_messages,
        haiku_messages: stats.haiku_messages,
        session_count: stats.session_count,
        latest_summary: stats.latest_summary,
        first_activity: stats.first_activity,
        last_activity: stats.last_activity,
    }
}

/// Builds a shell-native catalog entry from a filesystem path.
pub fn build_project_from_path(
    path: &str,
    claude_dir: &Path,
    stats_cache: &mut StatsCache,
) -> Option<ShellProjectCatalogEntry> {
    let project_path = PathBuf::from(path);
    if !project_path.exists() {
        return None;
    }

    let encoded_name = encode_project_path(path);
    let projects_dir = claude_dir.join("projects");

    let display_path = if path.starts_with("/Users/") {
        format!(
            "~/{}",
            path.split('/').skip(3).collect::<Vec<_>>().join("/")
        )
    } else {
        path.to_string()
    };

    let project_name = path.split('/').next_back().unwrap_or(path).to_string();

    let claude_project_dir = projects_dir.join(&encoded_name);

    let most_recent_mtime = latest_session_activity_mtime(&claude_project_dir);
    let last_active = most_recent_mtime.map(format_relative_time);

    let claude_md_path = project_path.join("CLAUDE.md");
    let claude_md_exists = claude_md_path.exists();
    let claude_md_preview = if claude_md_exists {
        get_claude_md_preview(&claude_md_path)
    } else {
        None
    };

    let local_settings_path = project_path.join(".claude").join("settings.local.json");
    let has_local_settings = local_settings_path.exists();

    let task_count = count_tasks_in_project(&projects_dir, &encoded_name);

    let stats = compute_project_stats(&projects_dir, &encoded_name, stats_cache, path);

    Some(ShellProjectCatalogEntry {
        id: path.to_string(),
        display_name: project_name,
        path: path.to_string(),
        display_path,
        last_active_at: last_active,
        claude_md_path: if claude_md_exists {
            Some(claude_md_path.to_string_lossy().to_string())
        } else {
            None
        },
        claude_md_preview,
        has_local_settings,
        task_count,
        stats: Some(shell_project_stats(stats)),
        is_missing: false,
    })
}

/// Builds a minimal shell-native catalog entry for a path that no longer exists on disk.
fn build_missing_project(path: &str) -> ShellProjectCatalogEntry {
    let display_path = if path.starts_with("/Users/") {
        format!(
            "~/{}",
            path.split('/').skip(3).collect::<Vec<_>>().join("/")
        )
    } else {
        path.to_string()
    };

    let project_name = path.split('/').next_back().unwrap_or(path).to_string();

    ShellProjectCatalogEntry {
        id: path.to_string(),
        display_name: project_name,
        path: path.to_string(),
        display_path,
        last_active_at: None,
        claude_md_path: None,
        claude_md_preview: None,
        has_local_settings: false,
        task_count: 0,
        stats: None,
        is_missing: true,
    }
}

/// Loads all pinned projects, sorted by most recent activity.
/// Missing projects (where the directory no longer exists) are included
/// with is_missing=true so they can be displayed with a warning indicator.
pub fn load_projects() -> Result<Vec<ShellProjectCatalogEntry>, String> {
    load_projects_with_storage(&StorageConfig::default())
}

pub fn load_projects_with_storage(
    storage: &StorageConfig,
) -> Result<Vec<ShellProjectCatalogEntry>, String> {
    let claude_dir = storage.claude_root();
    let config = load_hud_config_with_storage(storage);
    let projects_dir = claude_dir.join("projects");
    let mut stats_cache = load_stats_cache_with_storage(storage);

    let mut projects: Vec<(ShellProjectCatalogEntry, SystemTime)> = Vec::new();

    for path in &config.pinned_projects {
        let project = if let Some(p) = build_project_from_path(path, claude_dir, &mut stats_cache) {
            p
        } else {
            build_missing_project(path)
        };

        let encoded_name = encode_project_path(path);
        let claude_project_dir = projects_dir.join(&encoded_name);
        let sort_time =
            latest_session_activity_mtime(&claude_project_dir).unwrap_or(SystemTime::UNIX_EPOCH);
        projects.push((project, sort_time));
    }

    let _ = save_stats_cache_with_storage(storage, &stats_cache);

    projects.sort_by(|a, b| b.1.cmp(&a.1));

    Ok(projects.into_iter().map(|(p, _)| p).collect())
}

pub fn suggest_projects_with_storage(
    storage: &StorageConfig,
) -> Result<Vec<ShellSuggestedProjectCandidate>, String> {
    let projects_dir = storage.claude_projects_dir();
    if !projects_dir.exists() {
        return Ok(Vec::new());
    }

    let config = load_hud_config_with_storage(storage);
    let pinned_set: std::collections::HashSet<_> = config.pinned_projects.iter().collect();

    let mut suggestions: Vec<(ShellSuggestedProjectCandidate, u32)> = Vec::new();

    if let Ok(entries) = fs::read_dir(&projects_dir) {
        for entry in entries.filter_map(|e| e.ok()) {
            if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                continue;
            }

            let encoded_name = entry.file_name().to_string_lossy().to_string();
            if let Some(real_path) = try_resolve_encoded_path(&encoded_name) {
                if pinned_set.contains(&real_path) {
                    continue;
                }

                let project_path = PathBuf::from(&real_path);

                if let Ok(home) = std::env::var("HOME") {
                    if real_path == home {
                        continue;
                    }
                }

                let is_child_of_pinned = config
                    .pinned_projects
                    .iter()
                    .any(|pinned| project_path.starts_with(pinned));
                if is_child_of_pinned {
                    continue;
                }

                let has_indicators = has_project_indicators(&project_path);
                let has_claude_md = project_path.join("CLAUDE.md").exists();

                if !has_indicators && !has_claude_md {
                    continue;
                }

                let task_count = fs::read_dir(entry.path())
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .take(100)
                            .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                            .count() as u32
                    })
                    .unwrap_or(0);

                let display_path = if real_path.starts_with("/Users/") {
                    format!(
                        "~/{}",
                        real_path.split('/').skip(3).collect::<Vec<_>>().join("/")
                    )
                } else {
                    real_path.clone()
                };

                let name = real_path
                    .split('/')
                    .next_back()
                    .unwrap_or(&real_path)
                    .to_string();

                suggestions.push((
                    ShellSuggestedProjectCandidate {
                        id: real_path.clone(),
                        display_name: name,
                        path: real_path,
                        display_path,
                        task_count,
                        has_claude_md,
                        has_project_indicators: has_indicators,
                    },
                    task_count,
                ));
            }
        }
    }

    suggestions.sort_by(|a, b| b.1.cmp(&a.1));
    Ok(suggestions
        .into_iter()
        .take(8)
        .map(|(suggestion, _)| suggestion)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_config::save_hud_config_with_storage;
    use crate::runtime_types::HudConfig;
    use std::time::Duration;
    use tempfile::tempdir;

    #[test]
    fn missing_project_path_is_marked_missing() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&root).expect("create root");
        std::fs::create_dir_all(&claude_root).expect("create claude root");

        let storage = StorageConfig::with_roots(root, claude_root);
        let missing_path = temp.path().join("missing-project");

        let config = HudConfig {
            pinned_projects: vec![missing_path.to_string_lossy().to_string()],
            terminal_app: "Terminal".to_string(),
        };
        save_hud_config_with_storage(&storage, &config).expect("save config");

        let projects = load_projects_with_storage(&storage).expect("load projects");
        assert_eq!(projects.len(), 1);
        assert!(projects[0].is_missing);
        assert_eq!(projects[0].path, missing_path.to_string_lossy());
    }

    #[test]
    fn project_order_uses_latest_session_file_activity_not_directory_mtime() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&root).expect("create root");
        std::fs::create_dir_all(&claude_root).expect("create claude root");

        let storage = StorageConfig::with_roots(root, claude_root.clone());

        let project_a = temp.path().join("project-a");
        let project_b = temp.path().join("project-b");
        std::fs::create_dir_all(&project_a).expect("create project a");
        std::fs::create_dir_all(&project_b).expect("create project b");
        std::fs::write(project_a.join("CLAUDE.md"), "# A").expect("write claude a");
        std::fs::write(project_b.join("CLAUDE.md"), "# B").expect("write claude b");

        let config = HudConfig {
            pinned_projects: vec![
                project_a.to_string_lossy().to_string(),
                project_b.to_string_lossy().to_string(),
            ],
            terminal_app: "Terminal".to_string(),
        };
        save_hud_config_with_storage(&storage, &config).expect("save config");

        let projects_dir = claude_root.join("projects");
        let encoded_a = encode_project_path(&project_a.to_string_lossy());
        let encoded_b = encode_project_path(&project_b.to_string_lossy());
        let claude_project_a = projects_dir.join(encoded_a);
        let claude_project_b = projects_dir.join(encoded_b);
        std::fs::create_dir_all(&claude_project_a).expect("create claude project a");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(claude_project_a.join("session-a.jsonl"), "{}\n").expect("write session a");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::create_dir_all(&claude_project_b).expect("create claude project b");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(claude_project_b.join("session-b.jsonl"), "{}\n").expect("write session b");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(claude_project_a.join("session-a.jsonl"), "{}\n{}\n")
            .expect("append session a");

        let projects = load_projects_with_storage(&storage).expect("load projects");

        assert_eq!(projects.len(), 2);
        assert_eq!(projects[0].path, project_a.to_string_lossy());
        assert_eq!(projects[1].path, project_b.to_string_lossy());
    }

    #[test]
    fn project_order_and_last_active_ignore_agent_session_files() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&root).expect("create root");
        std::fs::create_dir_all(&claude_root).expect("create claude root");

        let storage = StorageConfig::with_roots(root, claude_root.clone());

        let human_project = temp.path().join("project-human");
        let agent_only_project = temp.path().join("project-agent-only");
        std::fs::create_dir_all(&human_project).expect("create human project");
        std::fs::create_dir_all(&agent_only_project).expect("create agent project");
        std::fs::write(human_project.join("CLAUDE.md"), "# Human").expect("write claude human");
        std::fs::write(agent_only_project.join("CLAUDE.md"), "# Agent")
            .expect("write claude agent");

        let config = HudConfig {
            pinned_projects: vec![
                human_project.to_string_lossy().to_string(),
                agent_only_project.to_string_lossy().to_string(),
            ],
            terminal_app: "Terminal".to_string(),
        };
        save_hud_config_with_storage(&storage, &config).expect("save config");

        let projects_dir = claude_root.join("projects");
        let human_encoded = encode_project_path(&human_project.to_string_lossy());
        let agent_encoded = encode_project_path(&agent_only_project.to_string_lossy());
        let human_claude_dir = projects_dir.join(human_encoded);
        let agent_claude_dir = projects_dir.join(agent_encoded);
        std::fs::create_dir_all(&human_claude_dir).expect("create human claude dir");
        std::fs::create_dir_all(&agent_claude_dir).expect("create agent claude dir");

        std::fs::write(human_claude_dir.join("session-human.jsonl"), "{}\n")
            .expect("write human session");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(agent_claude_dir.join("agent-0001.jsonl"), "{}\n")
            .expect("write agent session");

        let projects = load_projects_with_storage(&storage).expect("load projects");

        assert_eq!(projects.len(), 2);
        assert_eq!(
            projects[0].path,
            human_project.to_string_lossy(),
            "A fresh agent transcript should not outrank real session activity."
        );
        assert_eq!(projects[1].path, agent_only_project.to_string_lossy());
        assert_eq!(
            projects[1].last_active_at, None,
            "Projects with only agent transcripts should not report recent session activity."
        );
    }
}
