//! Project discovery, loading, and management.
//!
//! This module provides functionality for:
//! - Detecting project types from file indicators
//! - Building project metadata from paths
//! - Loading pinned projects with statistics

use crate::config::{
    load_hud_config_with_storage, load_stats_cache_with_storage, save_stats_cache_with_storage,
};
use crate::stats::compute_project_stats;
use crate::storage::StorageConfig;
use crate::types::{Project, StatsCache};
use std::fs;
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

/// Builds a Project from a filesystem path.
pub fn build_project_from_path(
    path: &str,
    claude_dir: &Path,
    stats_cache: &mut StatsCache,
) -> Option<Project> {
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

    let mut most_recent_mtime: Option<SystemTime> = None;
    if let Ok(entries) = fs::read_dir(&claude_project_dir) {
        for entry in entries.flatten() {
            let entry_path = entry.path();
            if entry_path.extension().is_some_and(|e| e == "jsonl") {
                if entry_path
                    .file_stem()
                    .is_some_and(|s| s.to_string_lossy().starts_with("agent-"))
                {
                    continue;
                }
                if let Ok(metadata) = entry_path.metadata() {
                    if let Ok(mtime) = metadata.modified() {
                        if most_recent_mtime.map_or(true, |t| mtime > t) {
                            most_recent_mtime = Some(mtime);
                        }
                    }
                }
            }
        }
    }
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

    Some(Project {
        name: project_name,
        path: path.to_string(),
        display_path,
        last_active,
        claude_md_path: if claude_md_exists {
            Some(claude_md_path.to_string_lossy().to_string())
        } else {
            None
        },
        claude_md_preview,
        has_local_settings,
        task_count,
        stats: Some(stats),
        is_missing: false,
    })
}

/// Builds a minimal Project for a path that no longer exists on disk.
fn build_missing_project(path: &str) -> Project {
    let display_path = if path.starts_with("/Users/") {
        format!(
            "~/{}",
            path.split('/').skip(3).collect::<Vec<_>>().join("/")
        )
    } else {
        path.to_string()
    };

    let project_name = path.split('/').next_back().unwrap_or(path).to_string();

    Project {
        name: project_name,
        path: path.to_string(),
        display_path,
        last_active: None,
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
pub fn load_projects() -> Result<Vec<Project>, String> {
    load_projects_with_storage(&StorageConfig::default())
}

pub fn load_projects_with_storage(storage: &StorageConfig) -> Result<Vec<Project>, String> {
    let claude_dir = storage.claude_root();
    let config = load_hud_config_with_storage(storage);
    let projects_dir = claude_dir.join("projects");
    let mut stats_cache = load_stats_cache_with_storage(storage);

    let mut projects: Vec<(Project, SystemTime)> = Vec::new();

    for path in &config.pinned_projects {
        let project = if let Some(p) = build_project_from_path(path, claude_dir, &mut stats_cache) {
            p
        } else {
            build_missing_project(path)
        };

        let encoded_name = encode_project_path(path);
        let claude_project_dir = projects_dir.join(&encoded_name);
        let sort_time = claude_project_dir
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        projects.push((project, sort_time));
    }

    let _ = save_stats_cache_with_storage(storage, &stats_cache);

    projects.sort_by(|a, b| b.1.cmp(&a.1));

    Ok(projects.into_iter().map(|(p, _)| p).collect())
}
