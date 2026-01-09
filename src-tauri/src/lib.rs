mod config;
mod patterns;
mod stats;
mod types;

pub use types::*;

use config::*;
use patterns::*;
use stats::*;

use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, SystemTime};
use tauri::Emitter;
use walkdir::WalkDir;

#[derive(Debug, Deserialize)]
struct PluginManifest {
    name: String,
    description: Option<String>,
}

#[derive(Debug, Deserialize)]
struct InstalledPluginsRegistry {
    plugins: HashMap<String, Vec<PluginInstallInfo>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginInstallInfo {
    install_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    enabled_plugins: Option<HashMap<String, bool>>,
}


fn count_artifacts_in_dir(dir: &PathBuf, artifact_type: &str) -> usize {
    if !dir.exists() {
        return 0;
    }

    match artifact_type {
        "skills" => WalkDir::new(dir)
            .min_depth(1)
            .max_depth(1)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_dir())
            .filter(|e| {
                let skill_md = e.path().join("SKILL.md");
                let skill_md_lower = e.path().join("skill.md");
                skill_md.exists() || skill_md_lower.exists()
            })
            .count(),
        "commands" | "agents" => WalkDir::new(dir)
            .min_depth(1)
            .max_depth(1)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "md"))
            .count(),
        _ => 0,
    }
}

fn count_hooks_in_dir(dir: &std::path::Path) -> usize {
    let hooks_json = dir.join("hooks").join("hooks.json");
    if hooks_json.exists() {
        1
    } else {
        0
    }
}

fn parse_frontmatter(content: &str) -> Option<(String, String)> {
    let caps = RE_FRONTMATTER.captures(content)?;
    let frontmatter = caps.get(1)?.as_str();

    let name = RE_FRONTMATTER_NAME
        .captures(frontmatter)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    let description = RE_FRONTMATTER_DESC
        .captures(frontmatter)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    Some((name, description))
}

fn collect_artifacts_from_dir(dir: &PathBuf, artifact_type: &str, source: &str) -> Vec<Artifact> {
    let mut artifacts = Vec::new();

    if !dir.exists() {
        return artifacts;
    }

    match artifact_type {
        "skill" => {
            for entry in WalkDir::new(dir)
                .min_depth(1)
                .max_depth(1)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                if entry.file_type().is_dir() {
                    let skill_md = entry.path().join("SKILL.md");
                    let skill_path = if skill_md.exists() {
                        skill_md
                    } else {
                        let skill_md_lower = entry.path().join("skill.md");
                        if skill_md_lower.exists() {
                            skill_md_lower
                        } else {
                            continue;
                        }
                    };

                    if let Ok(content) = fs::read_to_string(&skill_path) {
                        let (name, description) =
                            parse_frontmatter(&content).unwrap_or_else(|| {
                                (
                                    entry.file_name().to_string_lossy().to_string(),
                                    String::new(),
                                )
                            });
                        artifacts.push(Artifact {
                            artifact_type: "skill".to_string(),
                            name: if name.is_empty() {
                                entry.file_name().to_string_lossy().to_string()
                            } else {
                                name
                            },
                            description,
                            source: source.to_string(),
                            path: skill_path.to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
        "command" | "agent" => {
            for entry in WalkDir::new(dir)
                .min_depth(1)
                .max_depth(1)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                if entry.path().extension().is_some_and(|ext| ext == "md") {
                    if let Ok(content) = fs::read_to_string(entry.path()) {
                        let (name, description) =
                            parse_frontmatter(&content).unwrap_or_else(|| {
                                let file_stem = entry
                                    .path()
                                    .file_stem()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default();
                                (file_stem, String::new())
                            });
                        artifacts.push(Artifact {
                            artifact_type: artifact_type.to_string(),
                            name: if name.is_empty() {
                                entry
                                    .path()
                                    .file_stem()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default()
                            } else {
                                name
                            },
                            description,
                            source: source.to_string(),
                            path: entry.path().to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
        _ => {}
    }

    artifacts
}

fn strip_markdown(text: &str) -> String {
    let mut result = text.to_string();
    result = RE_MD_BOLD_ASTERISK.replace_all(&result, "$1").to_string();
    result = RE_MD_ITALIC_ASTERISK.replace_all(&result, "$1").to_string();
    result = RE_MD_BOLD_UNDERSCORE.replace_all(&result, "$1").to_string();
    result = RE_MD_ITALIC_UNDERSCORE
        .replace_all(&result, "$1")
        .to_string();
    result = RE_MD_CODE.replace_all(&result, "$1").to_string();
    result = RE_MD_HEADING.replace_all(&result, "").to_string();
    result = RE_MD_LINK.replace_all(&result, "$1").to_string();
    result
}

fn extract_text_from_content(content: &serde_json::Value) -> Option<String> {
    if let Some(s) = content.as_str() {
        return Some(s.to_string());
    }

    if let Some(arr) = content.as_array() {
        let texts: Vec<String> = arr
            .iter()
            .filter_map(|item| {
                if item.get("type").and_then(|t| t.as_str()) == Some("text") {
                    item.get("text")
                        .and_then(|t| t.as_str())
                        .map(|s| s.to_string())
                } else {
                    None
                }
            })
            .collect();
        if !texts.is_empty() {
            return Some(texts.join(" "));
        }
    }
    None
}

struct SessionExtract {
    first_message: Option<String>,
    summary: Option<String>,
}

fn extract_session_data(session_path: &std::path::Path) -> SessionExtract {
    use std::io::{BufRead, BufReader};

    match session_path.file_name().and_then(|f| f.to_str()) {
        Some(f) if !f.starts_with("agent-") => {}
        _ => {
            return SessionExtract {
                first_message: None,
                summary: None,
            }
        }
    }

    let file = match fs::File::open(session_path) {
        Ok(f) => f,
        Err(_) => {
            return SessionExtract {
                first_message: None,
                summary: None,
            }
        }
    };

    let reader = BufReader::new(file);
    let mut first_message: Option<String> = None;
    let mut first_command: Option<String> = None;
    let mut last_summary: Option<String> = None;

    for line in reader.lines().map_while(Result::ok) {
        if let Some(cap) = RE_SUMMARY.captures(&line) {
            last_summary = Some(cap[1].to_string());
        }

        if first_message.is_some() {
            continue;
        }

        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&line) {
            let msg_type = json.get("type").and_then(|t| t.as_str());
            let is_meta = json
                .get("isMeta")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            if is_meta {
                continue;
            }

            if msg_type == Some("user") {
                if let Some(content_val) = json.get("message").and_then(|m| m.get("content")) {
                    if let Some(content) = extract_text_from_content(content_val) {
                        let content_lower = content.to_lowercase();

                        if first_command.is_none() && content.contains("<command-name>") {
                            if let Some(start) = content.find("<command-name>") {
                                if let Some(end) = content.find("</command-name>") {
                                    let cmd = &content[start + 14..end];
                                    first_command = Some(format!("Command: {}", cmd));
                                }
                            }
                        }

                        if content_lower == "warmup"
                            || content_lower.starts_with("warmup")
                            || content.trim().is_empty()
                            || content.len() < 3
                            || content.contains("<command-message>")
                            || content.contains("<command-name>")
                            || content.contains("<local-command-stdout>")
                        {
                            continue;
                        }

                        let cleaned = strip_markdown(&content);
                        let trimmed: String = cleaned.chars().take(80).collect();
                        first_message = Some(if cleaned.len() > 80 {
                            format!("{}...", trimmed.trim())
                        } else {
                            trimmed.trim().to_string()
                        });
                    }
                }
            }
        }
    }

    SessionExtract {
        first_message: first_message.or(first_command),
        summary: last_summary,
    }
}

fn format_relative_time(system_time: SystemTime) -> String {
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

fn get_claude_md_preview(path: &PathBuf) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    let preview: String = content.chars().take(200).collect();
    if content.len() > 200 {
        Some(format!("{}...", preview.trim()))
    } else {
        Some(preview.trim().to_string())
    }
}

fn count_tasks_in_project(claude_projects_dir: &std::path::Path, encoded_name: &str) -> u32 {
    let project_dir = claude_projects_dir.join(encoded_name);
    if !project_dir.exists() {
        return 0;
    }

    // Tasks are stored as .jsonl files directly in the project folder
    fs::read_dir(&project_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                .count() as u32
        })
        .unwrap_or(0)
}

#[tauri::command]
fn load_dashboard() -> Result<DashboardData, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;

    let settings_path = claude_dir.join("settings.json");
    let instructions_path = claude_dir.join("CLAUDE.md");

    let skills_dir = resolve_symlink(&claude_dir.join("skills"));
    let commands_dir = resolve_symlink(&claude_dir.join("commands"));
    let agents_dir = resolve_symlink(&claude_dir.join("agents"));

    let global = GlobalConfig {
        settings_path: settings_path.to_string_lossy().to_string(),
        settings_exists: settings_path.exists(),
        instructions_path: if instructions_path.exists() {
            Some(instructions_path.to_string_lossy().to_string())
        } else {
            None
        },
        skills_dir: skills_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
        commands_dir: commands_dir
            .as_ref()
            .map(|p| p.to_string_lossy().to_string()),
        agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
        skill_count: skills_dir
            .as_ref()
            .map(|d| count_artifacts_in_dir(d, "skills"))
            .unwrap_or(0),
        command_count: commands_dir
            .as_ref()
            .map(|d| count_artifacts_in_dir(d, "commands"))
            .unwrap_or(0),
        agent_count: agents_dir
            .as_ref()
            .map(|d| count_artifacts_in_dir(d, "agents"))
            .unwrap_or(0),
    };

    let plugins = load_plugins(&claude_dir).unwrap_or_default();
    let projects = load_projects_internal(&claude_dir).unwrap_or_default();

    Ok(DashboardData {
        global,
        plugins,
        projects,
    })
}

fn load_plugins(claude_dir: &std::path::Path) -> Result<Vec<Plugin>, String> {
    let registry_path = claude_dir.join("plugins").join("installed_plugins.json");
    if !registry_path.exists() {
        return Ok(Vec::new());
    }

    let registry_content = fs::read_to_string(&registry_path)
        .map_err(|e| format!("Failed to read plugins registry: {}", e))?;

    let registry: InstalledPluginsRegistry = serde_json::from_str(&registry_content)
        .map_err(|e| format!("Failed to parse plugins registry: {}", e))?;

    let settings_path = claude_dir.join("settings.json");
    let enabled_plugins: HashMap<String, bool> = if settings_path.exists() {
        let settings_content = fs::read_to_string(&settings_path).ok();
        settings_content
            .and_then(|c| serde_json::from_str::<Settings>(&c).ok())
            .and_then(|s| s.enabled_plugins)
            .unwrap_or_default()
    } else {
        HashMap::new()
    };

    let mut plugins = Vec::new();

    for (id, versions) in registry.plugins {
        if let Some(latest) = versions.first() {
            let install_path = PathBuf::from(&latest.install_path);
            let manifest_path = install_path.join(".claude-plugin").join("plugin.json");

            let (name, description) = if manifest_path.exists() {
                let manifest_content = fs::read_to_string(&manifest_path).ok();
                manifest_content
                    .and_then(|c| serde_json::from_str::<PluginManifest>(&c).ok())
                    .map(|m| (m.name, m.description.unwrap_or_default()))
                    .unwrap_or_else(|| (id.clone(), String::new()))
            } else {
                (id.clone(), String::new())
            };

            let enabled = enabled_plugins.get(&id).copied().unwrap_or(true);

            plugins.push(Plugin {
                id: id.clone(),
                name,
                description,
                enabled,
                path: install_path.to_string_lossy().to_string(),
                skill_count: count_artifacts_in_dir(&install_path.join("skills"), "skills"),
                command_count: count_artifacts_in_dir(&install_path.join("commands"), "commands"),
                agent_count: count_artifacts_in_dir(&install_path.join("agents"), "agents"),
                hook_count: count_hooks_in_dir(&install_path),
            });
        }
    }

    plugins.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    Ok(plugins)
}

fn has_project_indicators(project_path: &std::path::Path) -> bool {
    let indicators = [
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

    indicators
        .iter()
        .any(|indicator| project_path.join(indicator).exists())
}

fn build_project_from_path(
    path: &str,
    claude_dir: &std::path::Path,
    stats_cache: &mut StatsCache,
) -> Option<Project> {
    let project_path = PathBuf::from(path);
    if !project_path.exists() {
        return None;
    }

    let encoded_name = path.replace('/', "-");
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
    })
}

fn load_projects_internal(claude_dir: &std::path::Path) -> Result<Vec<Project>, String> {
    let config = load_hud_config();
    let projects_dir = claude_dir.join("projects");
    let mut stats_cache = load_stats_cache();

    let mut projects: Vec<(Project, SystemTime)> = Vec::new();

    for path in &config.pinned_projects {
        if let Some(project) = build_project_from_path(path, claude_dir, &mut stats_cache) {
            let encoded_name = path.replace('/', "-");
            let claude_project_dir = projects_dir.join(&encoded_name);
            let sort_time = claude_project_dir
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            projects.push((project, sort_time));
        }
    }

    let _ = save_stats_cache(&stats_cache);

    projects.sort_by(|a, b| b.1.cmp(&a.1));

    Ok(projects.into_iter().map(|(p, _)| p).collect())
}

#[tauri::command]
fn load_projects() -> Result<Vec<Project>, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;
    load_projects_internal(&claude_dir)
}

#[tauri::command]
fn load_project_details(path: String) -> Result<ProjectDetails, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;
    let project_path = PathBuf::from(&path);

    if !project_path.exists() {
        return Err(format!("Project path does not exist: {}", path));
    }

    let encoded_name = path.replace('/', "-");
    let projects_dir = claude_dir.join("projects");

    let display_path = if path.starts_with("/Users/") {
        format!(
            "~/{}",
            path.split('/').skip(3).collect::<Vec<_>>().join("/")
        )
    } else {
        path.clone()
    };

    let project_name = path.split('/').next_back().unwrap_or(&path).to_string();

    let project_folder = projects_dir.join(&encoded_name);

    let mut most_recent_mtime: Option<SystemTime> = None;
    if let Ok(entries) = fs::read_dir(&project_folder) {
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
    let claude_md_content = if claude_md_exists {
        fs::read_to_string(&claude_md_path).ok()
    } else {
        None
    };
    let claude_md_preview = claude_md_content.as_ref().map(|c| {
        let preview: String = c.chars().take(200).collect();
        if c.len() > 200 {
            format!("{}...", preview.trim())
        } else {
            preview.trim().to_string()
        }
    });

    let local_settings_path = project_path.join(".claude").join("settings.local.json");
    let has_local_settings = local_settings_path.exists();

    let task_count = count_tasks_in_project(&projects_dir, &encoded_name);

    let stats_cache = load_stats_cache();
    let stats = stats_cache
        .projects
        .get(&path)
        .map(|c| c.stats.clone())
        .unwrap_or_default();

    let mut tasks_with_time: Vec<(Task, SystemTime)> = Vec::new();
    let claude_project_dir = projects_dir.join(&encoded_name);
    if claude_project_dir.exists() {
        if let Ok(entries) = fs::read_dir(&claude_project_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                let task_path = entry.path();
                if task_path.extension().is_some_and(|ext| ext == "jsonl") {
                    let task_id = entry.file_name().to_string_lossy().to_string();
                    let task_name = task_id.trim_end_matches(".jsonl").to_string();

                    if task_name.starts_with("agent-") {
                        continue;
                    }

                    let mtime = entry
                        .metadata()
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .unwrap_or(SystemTime::UNIX_EPOCH);
                    let task_modified = format_relative_time(mtime);

                    let session_data = extract_session_data(&task_path);
                    let task_path_str = task_path.to_string_lossy().to_string();

                    tasks_with_time.push((
                        Task {
                            id: task_id,
                            name: task_name,
                            path: task_path_str,
                            last_modified: task_modified,
                            summary: session_data.summary,
                            first_message: session_data.first_message,
                        },
                        mtime,
                    ));
                }
            }
        }
    }

    tasks_with_time.sort_by(|a, b| b.1.cmp(&a.1));
    let tasks: Vec<Task> = tasks_with_time.into_iter().map(|(t, _)| t).collect();

    let git_dir = project_path.join(".git");
    let (git_branch, git_dirty) = if git_dir.exists() {
        let head_path = git_dir.join("HEAD");
        let branch = fs::read_to_string(&head_path).ok().map(|content| {
            if content.starts_with("ref: refs/heads/") {
                content
                    .trim_start_matches("ref: refs/heads/")
                    .trim()
                    .to_string()
            } else {
                "detached".to_string()
            }
        });

        let dirty = std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .current_dir(&project_path)
            .output()
            .map(|o| !o.stdout.is_empty())
            .unwrap_or(false);

        (branch, dirty)
    } else {
        (None, false)
    };

    let project = Project {
        name: project_name,
        path,
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
    };

    Ok(ProjectDetails {
        project,
        claude_md_content,
        tasks,
        git_branch,
        git_dirty,
    })
}

#[tauri::command]
fn load_artifacts() -> Result<Vec<Artifact>, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;

    let mut artifacts = Vec::new();

    if let Some(skills_dir) = resolve_symlink(&claude_dir.join("skills")) {
        artifacts.extend(collect_artifacts_from_dir(&skills_dir, "skill", "Global"));
    }

    if let Some(commands_dir) = resolve_symlink(&claude_dir.join("commands")) {
        artifacts.extend(collect_artifacts_from_dir(
            &commands_dir,
            "command",
            "Global",
        ));
    }

    if let Some(agents_dir) = resolve_symlink(&claude_dir.join("agents")) {
        artifacts.extend(collect_artifacts_from_dir(&agents_dir, "agent", "Global"));
    }

    let plugins = load_plugins(&claude_dir).unwrap_or_default();
    for plugin in plugins {
        if plugin.enabled {
            let plugin_path = PathBuf::from(&plugin.path);
            artifacts.extend(collect_artifacts_from_dir(
                &plugin_path.join("skills"),
                "skill",
                &plugin.name,
            ));
            artifacts.extend(collect_artifacts_from_dir(
                &plugin_path.join("commands"),
                "command",
                &plugin.name,
            ));
            artifacts.extend(collect_artifacts_from_dir(
                &plugin_path.join("agents"),
                "agent",
                &plugin.name,
            ));
        }
    }

    artifacts.sort_by(|a, b| {
        let type_order = a.artifact_type.cmp(&b.artifact_type);
        if type_order == std::cmp::Ordering::Equal {
            a.name.to_lowercase().cmp(&b.name.to_lowercase())
        } else {
            type_order
        }
    });

    Ok(artifacts)
}

#[tauri::command]
fn toggle_plugin(plugin_id: String, enabled: bool) -> Result<(), String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;
    let settings_path = claude_dir.join("settings.json");

    let mut settings: serde_json::Value = if settings_path.exists() {
        let content = fs::read_to_string(&settings_path)
            .map_err(|e| format!("Failed to read settings: {}", e))?;
        serde_json::from_str(&content).map_err(|e| format!("Failed to parse settings: {}", e))?
    } else {
        serde_json::json!({})
    };

    if settings.get("enabledPlugins").is_none() {
        settings["enabledPlugins"] = serde_json::json!({});
    }

    settings["enabledPlugins"][&plugin_id] = serde_json::Value::Bool(enabled);

    let content = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;

    fs::write(&settings_path, content).map_err(|e| format!("Failed to write settings: {}", e))?;

    Ok(())
}

#[tauri::command]
fn read_file_content(path: String) -> Result<String, String> {
    fs::read_to_string(&path).map_err(|e| format!("Failed to read file: {}", e))
}

#[tauri::command]
fn open_in_editor(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("-t")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open editor: {}", e))?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", &path])
            .spawn()
            .map_err(|e| format!("Failed to open editor: {}", e))?;
    }

    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open editor: {}", e))?;
    }

    Ok(())
}

#[tauri::command]
fn open_folder(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open folder: {}", e))?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open folder: {}", e))?;
    }

    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open folder: {}", e))?;
    }

    Ok(())
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FocusedWindow {
    pub app_name: String,
    pub window_type: String,
    pub details: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct BringToFrontResult {
    pub focused_windows: Vec<FocusedWindow>,
    pub launched_terminal: bool,
}

#[cfg(target_os = "macos")]
mod window_management {
    use super::*;
    use std::io::Read;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    const BROWSERS: &[&str] = &["Google Chrome", "Arc", "Safari"];
    const IDES: &[&str] = &["Cursor", "Code", "Visual Studio Code", "Zed"];
    const DEV_SERVER_PORTS: &[u16] = &[3000, 5173, 8080, 4200, 3001, 8000, 4000];

    fn run_applescript_with_timeout(script: &str, timeout_ms: u64) -> Option<String> {
        let mut child = std::process::Command::new("osascript")
            .arg("-e")
            .arg(script)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .ok()?;

        let start = Instant::now();
        let timeout = Duration::from_millis(timeout_ms);

        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    if status.success() {
                        if let Some(stdout) = child.stdout.take() {
                            let mut output = String::new();
                            let mut reader = std::io::BufReader::new(stdout);
                            if reader.read_to_string(&mut output).is_ok() {
                                return Some(output);
                            }
                        }
                    }
                    return None;
                }
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(_) => return None,
            }
        }
    }

    /// Get the tmux session name for a project (uses directory name)
    pub fn get_tmux_session_name(project_path: &str) -> String {
        PathBuf::from(project_path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "default".to_string())
    }

    /// Check if a tmux session exists for this project
    pub fn has_tmux_session(project_path: &str) -> bool {
        let session_name = get_tmux_session_name(project_path);
        let output = std::process::Command::new("tmux")
            .args(["has-session", "-t", &session_name])
            .output()
            .ok();

        output.map(|o| o.status.success()).unwrap_or(false)
    }

    /// Switch the current tmux client to a session
    pub fn switch_to_tmux_session(session_name: &str) -> Result<bool, String> {
        eprintln!("[HUD DEBUG] Switching to tmux session '{}'", session_name);
        let output = std::process::Command::new("tmux")
            .args(["switch-client", "-t", session_name])
            .output()
            .map_err(|e| format!("Failed to switch tmux session: {}", e))?;

        Ok(output.status.success())
    }

    /// Check if tmux is running (has any sessions)
    pub fn is_tmux_running() -> bool {
        std::process::Command::new("tmux")
            .args(["list-sessions"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    /// Get the most recently active tmux session name (if any client is attached)
    pub fn get_current_tmux_session() -> Option<String> {
        let output = std::process::Command::new("tmux")
            .args(["list-clients", "-F", "#{client_activity}:#{session_name}"])
            .output()
            .ok()?;

        if output.status.success() {
            let result = String::from_utf8_lossy(&output.stdout);
            let mut best_activity: u64 = 0;
            let mut best_session: Option<String> = None;

            for line in result.lines() {
                if let Some((activity_str, session)) = line.split_once(':') {
                    if let Ok(activity) = activity_str.parse::<u64>() {
                        if activity > best_activity {
                            best_activity = activity;
                            best_session = Some(session.to_string());
                        }
                    }
                }
            }
            return best_session;
        }
        None
    }

    pub fn focus_app(app_name: &str) -> Result<(), String> {
        let script = format!(r#"tell application "{}" to activate"#, app_name);
        std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .spawn()
            .map_err(|e| format!("Failed to focus {}: {}", app_name, e))?;
        Ok(())
    }

    pub fn find_dev_server_port(project_path: &str) -> Option<u16> {
        for &port in DEV_SERVER_PORTS {
            let output = std::process::Command::new("lsof")
                .args(["-i", &format!(":{}", port), "-t"])
                .output()
                .ok()?;

            let pids = String::from_utf8_lossy(&output.stdout);
            for pid_str in pids.lines() {
                if let Ok(pid) = pid_str.trim().parse::<u32>() {
                    let cwd_output = std::process::Command::new("lsof")
                        .args(["-p", &pid.to_string(), "-Fn"])
                        .output()
                        .ok();

                    if let Some(cwd_out) = cwd_output {
                        let cwd_str = String::from_utf8_lossy(&cwd_out.stdout);
                        if cwd_str.contains(project_path) {
                            log::info!("Found dev server on port {} for project", port);
                            return Some(port);
                        }
                    }
                }
            }
        }
        None
    }

    pub fn find_browser_with_localhost(port: u16) -> Option<String> {
        let (tx, rx) = mpsc::channel();

        for &browser in BROWSERS {
            let tx = tx.clone();
            let browser_name = browser.to_string();

            std::thread::spawn(move || {
                let script = if browser_name == "Safari" {
                    r#"tell application "System Events"
                            if exists process "Safari" then
                                tell application "Safari"
                                    set allURLs to ""
                                    repeat with w in windows
                                        repeat with t in tabs of w
                                            set allURLs to allURLs & URL of t & "\n"
                                        end repeat
                                    end repeat
                                    return allURLs
                                end tell
                            end if
                        end tell"#
                        .to_string()
                } else if browser_name == "Arc" {
                    r#"tell application "System Events"
                        if exists process "Arc" then
                            tell application "Arc"
                                set allURLs to ""
                                repeat with w in windows
                                    repeat with t in tabs of w
                                        set allURLs to allURLs & URL of t & "\n"
                                    end repeat
                                end repeat
                                return allURLs
                            end tell
                        end if
                    end tell"#
                        .to_string()
                } else {
                    format!(
                        r#"tell application "System Events"
                            if exists process "{}" then
                                tell application "{}"
                                    set allURLs to ""
                                    repeat with w in windows
                                        repeat with t in tabs of w
                                            set allURLs to allURLs & URL of t & "\n"
                                        end repeat
                                    end repeat
                                    return allURLs
                                end tell
                            end if
                        end tell"#,
                        browser_name, browser_name
                    )
                };

                if let Some(output) = run_applescript_with_timeout(&script, 2000) {
                    let localhost_pattern = format!("localhost:{}", port);
                    let ip_pattern = format!("127.0.0.1:{}", port);
                    if output.contains(&localhost_pattern) || output.contains(&ip_pattern) {
                        let _ = tx.send(browser_name);
                    }
                }
            });
        }
        drop(tx);

        rx.recv_timeout(Duration::from_millis(2500)).ok()
    }

    pub fn focus_browser_tab_with_url(browser: &str, port: u16) -> Result<(), String> {
        let script = if browser == "Safari" {
            format!(
                r#"tell application "Safari"
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            if URL of t contains "localhost:{}" or URL of t contains "127.0.0.1:{}" then
                                set current tab of w to t
                                set index of w to 1
                                activate
                                return
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end tell"#,
                port, port
            )
        } else if browser == "Arc" {
            format!(
                r#"tell application "Arc"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "localhost:{}" or URL of t contains "127.0.0.1:{}" then
                                tell w to set active tab index to index of t
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end tell"#,
                port, port
            )
        } else {
            format!(
                r#"tell application "{}"
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            if URL of t contains "localhost:{}" or URL of t contains "127.0.0.1:{}" then
                                set active tab index of w to tabIndex
                                set index of w to 1
                                activate
                                return
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end tell"#,
                browser, port, port
            )
        };

        std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .spawn()
            .map_err(|e| format!("Failed to focus browser tab: {}", e))?;

        Ok(())
    }

    pub fn find_ide_for_project(project_path: &str) -> Option<String> {
        let project_name = PathBuf::from(project_path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();

        let (tx, rx) = mpsc::channel();

        for &ide in IDES {
            let tx = tx.clone();
            let ide_name = ide.to_string();
            let path = project_path.to_string();
            let name = project_name.clone();

            std::thread::spawn(move || {
                let script = format!(
                    r#"tell application "System Events"
                        if exists process "{}" then
                            tell process "{}"
                                get name of every window
                            end tell
                        else
                            return ""
                        end if
                    end tell"#,
                    ide_name, ide_name
                );

                if let Some(output) = run_applescript_with_timeout(&script, 1500) {
                    if output.contains(&path) || output.contains(&name) {
                        let _ = tx.send(ide_name);
                    }
                }
            });
        }
        drop(tx);

        rx.recv_timeout(Duration::from_millis(2000)).ok()
    }

    /// Launch terminal app with tmux attached to the project session
    pub fn launch_terminal_with_tmux(
        path: &str,
        terminal_app: &str,
        run_claude: bool,
    ) -> Result<(), String> {
        let session_name = get_tmux_session_name(path);
        eprintln!(
            "[HUD DEBUG] launch_terminal_with_tmux: app='{}' session='{}' path='{}'",
            terminal_app, session_name, path
        );

        // Build the tmux command: attach to existing session or create new one
        let tmux_cmd = if run_claude {
            format!(
                "tmux new-session -A -s '{}' -c '{}' 'claude --continue; exec $SHELL'",
                session_name, path
            )
        } else {
            format!("tmux new-session -A -s '{}' -c '{}'", session_name, path)
        };

        // Launch terminal app with tmux command
        match terminal_app {
            "Ghostty" => {
                // Ghostty's -e expects the command as separate args, use sh -c for complex commands
                std::process::Command::new("open")
                    .args(["-na", "Ghostty.app", "--args", "-e", "sh", "-c", &tmux_cmd])
                    .spawn()
                    .map_err(|e| format!("Failed to launch Ghostty: {}", e))?;
            }
            "iTerm" | "iTerm2" => {
                let script = format!(
                    r#"tell application "iTerm"
                        create window with default profile command "{}"
                        activate
                    end tell"#,
                    tmux_cmd.replace('"', r#"\""#)
                );
                std::process::Command::new("osascript")
                    .arg("-e")
                    .arg(&script)
                    .spawn()
                    .map_err(|e| format!("Failed to launch iTerm: {}", e))?;
            }
            "Alacritty" => {
                std::process::Command::new("open")
                    .args([
                        "-na",
                        "Alacritty.app",
                        "--args",
                        "-e",
                        "sh",
                        "-c",
                        &tmux_cmd,
                    ])
                    .spawn()
                    .map_err(|e| format!("Failed to launch Alacritty: {}", e))?;
            }
            "kitty" => {
                std::process::Command::new("kitty")
                    .args(["sh", "-c", &tmux_cmd])
                    .spawn()
                    .map_err(|e| format!("Failed to launch kitty: {}", e))?;
            }
            "Warp" => {
                std::process::Command::new("open")
                    .args(["-a", "Warp", path])
                    .spawn()
                    .map_err(|e| format!("Failed to launch Warp: {}", e))?;
                // Warp doesn't support -e flag well, so just open the directory
                // User will need to run tmux manually
            }
            _ => {
                // Default to Terminal.app with AppleScript
                let script = format!(
                    r#"tell application "Terminal"
                        activate
                        do script "{}"
                    end tell"#,
                    tmux_cmd.replace('"', r#"\""#)
                );
                std::process::Command::new("osascript")
                    .arg("-e")
                    .arg(&script)
                    .spawn()
                    .map_err(|e| format!("Failed to launch Terminal: {}", e))?;
            }
        }

        Ok(())
    }

    /// Focus the terminal for a project using tmux session switching
    /// Returns true if an existing session was found and switched to
    pub fn focus_terminal_for_project(
        project_path: &str,
        terminal_app: &str,
    ) -> Result<bool, String> {
        let session_name = get_tmux_session_name(project_path);
        eprintln!(
            "[HUD DEBUG] focus_terminal_for_project: session='{}' path='{}'",
            session_name, project_path
        );

        // Check if tmux session exists
        if !has_tmux_session(project_path) {
            eprintln!("[HUD DEBUG] No tmux session '{}' found", session_name);
            return Ok(false);
        }

        // Session exists - check if we have an attached client
        if is_tmux_running() {
            // Try to switch the current client to this session
            if switch_to_tmux_session(&session_name).unwrap_or(false) {
                eprintln!(
                    "[HUD DEBUG] Switched tmux client to session '{}'",
                    session_name
                );
                // Bring the terminal app to front
                let _ = focus_app(terminal_app);
                return Ok(true);
            }
        }

        // No attached client - need to launch terminal and attach
        eprintln!("[HUD DEBUG] No attached tmux client, launching terminal to attach");
        launch_terminal_with_tmux(project_path, terminal_app, false)?;
        Ok(true)
    }
}

#[tauri::command]
fn bring_project_windows_to_front(
    path: String,
    launch_if_none: bool,
) -> Result<BringToFrontResult, String> {
    eprintln!(
        "[HUD DEBUG] bring_project_windows_to_front called: path='{}', launch_if_none={}",
        path, launch_if_none
    );

    #[cfg(target_os = "macos")]
    {
        let config = load_hud_config();
        let terminal_app = config.terminal_app.clone();

        std::thread::spawn(move || {
            use window_management::*;

            // Try to focus existing tmux session
            if has_tmux_session(&path) {
                eprintln!("[HUD DEBUG] tmux session exists, focusing");
                if focus_terminal_for_project(&path, &terminal_app).unwrap_or(false) {
                    eprintln!("[HUD DEBUG] Focused tmux session successfully");
                } else {
                    eprintln!("[HUD DEBUG] Failed to focus tmux session, activating terminal app");
                    let _ = focus_app(&terminal_app);
                }
            } else if launch_if_none {
                eprintln!("[HUD DEBUG] No tmux session, launching new terminal with tmux");
                if let Err(e) = launch_terminal_with_tmux(&path, &terminal_app, true) {
                    eprintln!("[HUD DEBUG] Error launching terminal: {}", e);
                }
            } else {
                eprintln!(
                    "[HUD DEBUG] No tmux session and launch_if_none=false, activating terminal"
                );
                let _ = focus_app(&terminal_app);
            }

            if let Some(port) = find_dev_server_port(&path) {
                if let Some(browser) = find_browser_with_localhost(port) {
                    log::info!("Found browser {} with localhost:{}", browser, port);
                    if let Err(e) = focus_browser_tab_with_url(&browser, port) {
                        eprintln!("[HUD DEBUG] Error focusing browser: {}", e);
                    }
                }
            }

            if let Some(ide) = find_ide_for_project(&path) {
                log::info!("Found IDE {} for project", ide);
                if let Err(e) = focus_app(&ide) {
                    eprintln!("[HUD DEBUG] Error focusing IDE: {}", e);
                }
            }
        });

        Ok(BringToFrontResult {
            focused_windows: Vec::new(),
            launched_terminal: false,
        })
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Window management is only supported on macOS currently".to_string())
    }
}

#[tauri::command]
fn launch_in_terminal(path: String, run_claude: bool) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let config = load_hud_config();
        let terminal_app = config.terminal_app.clone();

        std::thread::spawn(move || {
            use window_management::*;

            // Try to focus existing tmux session first
            if has_tmux_session(&path) {
                eprintln!("[HUD DEBUG] launch_in_terminal: tmux session exists, focusing");
                if focus_terminal_for_project(&path, &terminal_app).unwrap_or(false) {
                    eprintln!("[HUD DEBUG] launch_in_terminal: Focused tmux session successfully");
                    return;
                }
            }

            // Launch new terminal with tmux
            eprintln!("[HUD DEBUG] launch_in_terminal: Launching new terminal with tmux");
            if let Err(e) = launch_terminal_with_tmux(&path, &terminal_app, run_claude) {
                eprintln!("[HUD DEBUG] Error launching terminal: {}", e);
            }
        });
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Terminal launch is only supported on macOS currently".to_string())
    }
}

use std::sync::Mutex;

struct FocusedProjectCache {
    value: Option<String>,
    last_update: std::time::Instant,
    update_in_progress: bool,
}

static FOCUSED_PROJECT_CACHE: Lazy<Mutex<FocusedProjectCache>> = Lazy::new(|| {
    Mutex::new(FocusedProjectCache {
        value: None,
        last_update: std::time::Instant::now(),
        update_in_progress: false,
    })
});

#[tauri::command]
fn get_focused_project_path() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let mut cache = FOCUSED_PROJECT_CACHE.lock().unwrap();
        let elapsed = cache.last_update.elapsed();

        // Return cached value immediately, trigger background update if stale
        if elapsed < std::time::Duration::from_millis(500) || cache.update_in_progress {
            return Ok(cache.value.clone());
        }

        // Mark update in progress and get current cached value
        cache.update_in_progress = true;
        let cached_value = cache.value.clone();
        drop(cache); // Release lock before spawning

        // Spawn background update
        std::thread::spawn(move || {
            let result = compute_focused_project();
            if let Ok(mut cache) = FOCUSED_PROJECT_CACHE.lock() {
                cache.value = result;
                cache.last_update = std::time::Instant::now();
                cache.update_in_progress = false;
            }
        });

        Ok(cached_value)
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

#[cfg(target_os = "macos")]
fn compute_focused_project() -> Option<String> {
    let script = r#"
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
            return frontApp
        end tell
    "#;

    let output = std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .ok()?;

    let frontmost_app = String::from_utf8_lossy(&output.stdout).trim().to_string();

    let terminal_apps = [
        "Warp",
        "Terminal",
        "iTerm2",
        "iTerm",
        "Alacritty",
        "kitty",
        "Ghostty",
    ];
    let hud_apps = ["claude-hud", "Claude HUD", "stable"];

    if hud_apps.iter().any(|&app| frontmost_app.contains(app)) {
        return FOCUSED_PROJECT_CACHE.lock().ok()?.value.clone();
    }

    if !terminal_apps.iter().any(|&app| frontmost_app.contains(app)) {
        return None;
    }

    let config = load_hud_config();

    // First try tmux-based detection (fast and reliable)
    if let Some(session_name) = window_management::get_current_tmux_session() {
        for pinned in &config.pinned_projects {
            let project_name = std::path::PathBuf::from(pinned)
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if session_name == project_name {
                return Some(pinned.clone());
            }
        }
    }

    // Fallback to old TTY-based detection for non-tmux terminals
    get_terminal_working_directory(&frontmost_app, &config.pinned_projects)
        .ok()
        .flatten()
}

#[cfg(target_os = "macos")]
fn get_terminal_working_directory(
    app_name: &str,
    pinned_projects: &[String],
) -> Result<Option<String>, String> {
    if app_name.contains("Warp") {
        let output = std::process::Command::new("lsof")
            .arg("-c")
            .arg("zsh")
            .arg("-c")
            .arg("bash")
            .arg("-d")
            .arg("cwd")
            .arg("-Fn")
            .output()
            .map_err(|e| format!("Failed to run lsof: {}", e))?;

        let result = String::from_utf8_lossy(&output.stdout);
        let mut cwds: Vec<String> = Vec::new();

        for line in result.lines() {
            if let Some(path) = line.strip_prefix('n') {
                if path.starts_with("/Users/") && !path.contains("/Library/") {
                    cwds.push(path.to_string());
                }
            }
        }

        for pinned in pinned_projects {
            for cwd in &cwds {
                if cwd.starts_with(pinned) || cwd == pinned {
                    return Ok(Some(pinned.clone()));
                }
            }
        }

        return Ok(None);
    }

    if app_name.contains("Terminal") {
        let script = r#"
            tell application "Terminal"
                if (count of windows) > 0 then
                    set currentTab to selected tab of window 1
                    set ttyName to tty of currentTab
                    return ttyName
                end if
            end tell
            return ""
        "#;

        let output = std::process::Command::new("osascript")
            .arg("-e")
            .arg(script)
            .output()
            .map_err(|e| format!("Failed to get Terminal tty: {}", e))?;

        let tty = String::from_utf8_lossy(&output.stdout).trim().to_string();

        if !tty.is_empty() {
            if let Some(cwd) = get_cwd_from_tty(&tty) {
                return Ok(Some(cwd));
            }
        }
    }

    if app_name.contains("iTerm") {
        let script = r#"
            tell application "iTerm"
                if (count of windows) > 0 then
                    tell current session of current window
                        return tty
                    end tell
                end if
            end tell
            return ""
        "#;

        let output = std::process::Command::new("osascript")
            .arg("-e")
            .arg(script)
            .output()
            .map_err(|e| format!("Failed to get iTerm tty: {}", e))?;

        let tty = String::from_utf8_lossy(&output.stdout).trim().to_string();

        if !tty.is_empty() {
            if let Some(cwd) = get_cwd_from_tty(&tty) {
                return Ok(Some(cwd));
            }
        }
    }

    Ok(None)
}

#[cfg(target_os = "macos")]
fn get_cwd_from_tty(tty: &str) -> Option<String> {
    let tty_device = if tty.starts_with("/dev/") {
        tty.to_string()
    } else {
        format!("/dev/{}", tty)
    };

    let output = std::process::Command::new("lsof")
        .arg("-t")
        .arg(&tty_device)
        .output()
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let pids: Vec<&str> = stdout.trim().lines().collect();

    if let Some(pid) = pids.first() {
        let cwd_output = std::process::Command::new("lsof")
            .arg("-p")
            .arg(*pid)
            .arg("-d")
            .arg("cwd")
            .arg("-Fn")
            .output()
            .ok()?;

        let result = String::from_utf8_lossy(&cwd_output.stdout);
        for line in result.lines() {
            if let Some(path) = line.strip_prefix('n') {
                return Some(path.to_string());
            }
        }
    }
    None
}

#[tauri::command]
fn add_project(path: String) -> Result<(), String> {
    let mut config = load_hud_config();

    if !config.pinned_projects.contains(&path) {
        config.pinned_projects.push(path);
        save_hud_config(&config)?;
    }

    Ok(())
}

#[tauri::command]
fn remove_project(path: String) -> Result<(), String> {
    let mut config = load_hud_config();
    config.pinned_projects.retain(|p| p != &path);
    save_hud_config(&config)?;
    Ok(())
}

#[tauri::command]
fn load_suggested_projects() -> Result<Vec<SuggestedProject>, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find home directory")?;
    let projects_dir = claude_dir.join("projects");

    if !projects_dir.exists() {
        return Ok(Vec::new());
    }

    let config = load_hud_config();
    let pinned_set: HashSet<&String> = config.pinned_projects.iter().collect();

    let mut suggestions: Vec<(SuggestedProject, u32)> = Vec::new();

    for entry in fs::read_dir(&projects_dir).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let encoded_name = entry.file_name().to_string_lossy().to_string();

        if !encoded_name.starts_with('-') || !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }

        let task_count = count_tasks_in_project(&projects_dir, &encoded_name);
        if task_count == 0 {
            continue;
        }

        // Try to find the actual path by checking common variations
        // The encoded name replaces / with -, but paths might have hyphens
        let decoded_path = encoded_name.replace('-', "/");
        let project_path = PathBuf::from(&decoded_path);

        // Skip if already pinned
        if pinned_set.contains(&decoded_path) {
            continue;
        }

        // Try to resolve the actual path
        let actual_path = if project_path.exists() {
            Some(decoded_path.clone())
        } else {
            // Try to find the path by looking for directories that match
            try_resolve_encoded_path(&encoded_name)
        };

        let Some(path) = actual_path else {
            continue;
        };

        // Skip if this resolved path is already pinned
        if pinned_set.contains(&path) {
            continue;
        }

        let project_path = PathBuf::from(&path);
        let has_claude_md = project_path.join("CLAUDE.md").exists();
        let has_indicators = has_project_indicators(&project_path);

        // Only suggest if it has project indicators or CLAUDE.md
        if !has_indicators && !has_claude_md {
            continue;
        }

        let display_path = if path.starts_with("/Users/") {
            format!(
                "~/{}",
                path.split('/').skip(3).collect::<Vec<_>>().join("/")
            )
        } else {
            path.clone()
        };

        let name = path.split('/').next_back().unwrap_or(&path).to_string();

        suggestions.push((
            SuggestedProject {
                path,
                display_path,
                name,
                task_count,
                has_claude_md,
                has_project_indicators: has_indicators,
            },
            task_count,
        ));
    }

    // Sort by task count (most active first)
    suggestions.sort_by(|a, b| b.1.cmp(&a.1));

    Ok(suggestions.into_iter().map(|(s, _)| s).collect())
}

fn try_resolve_encoded_path(encoded_name: &str) -> Option<String> {
    // The encoding replaces / with -, which is lossy when paths contain hyphens
    // Try to intelligently resolve by checking if directories exist
    let parts: Vec<&str> = encoded_name.split('-').filter(|s| !s.is_empty()).collect();

    // Start building the path, trying to find valid directories
    let mut current_path = PathBuf::new();
    let mut i = 0;

    while i < parts.len() {
        // Try progressively longer combinations
        let mut found = false;
        for end in (i + 1..=parts.len()).rev() {
            let segment = parts[i..end].join("-");
            let test_path = current_path.join(&segment);

            if test_path.exists() {
                current_path = test_path;
                i = end;
                found = true;
                break;
            }
        }

        if !found {
            // Just use the single segment
            current_path = current_path.join(parts[i]);
            i += 1;
        }
    }

    // Prepend / for absolute path
    let path_str = format!("/{}", current_path.to_string_lossy());
    let final_path = PathBuf::from(&path_str);

    if final_path.exists() {
        Some(path_str)
    } else {
        None
    }
}

fn load_session_states_file() -> Option<SessionStatesFile> {
    let claude_dir = get_claude_dir()?;
    let state_file = claude_dir.join("hud-session-states.json");

    if !state_file.exists() {
        return None;
    }

    fs::read_to_string(&state_file)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
}

fn detect_session_state(project_path: &str) -> ProjectSessionState {
    let idle_state = ProjectSessionState {
        state: SessionState::Idle,
        state_changed_at: None,
        session_id: None,
        working_on: None,
        next_step: None,
        context: None,
    };

    if let Some(states_file) = load_session_states_file() {
        if let Some(entry) = states_file.projects.get(project_path) {
            let state = match entry.state.as_str() {
                "working" => SessionState::Working,
                "ready" => SessionState::Ready,
                "compacting" => SessionState::Compacting,
                "waiting" => SessionState::Waiting,
                _ => SessionState::Idle,
            };

            let context = entry.context.as_ref().and_then(|ctx| {
                Some(ContextInfo {
                    percent_used: ctx.percent_used?,
                    tokens_used: ctx.tokens_used?,
                    context_size: ctx.context_size?,
                    updated_at: ctx.updated_at.clone(),
                })
            });

            return ProjectSessionState {
                state,
                state_changed_at: entry.state_changed_at.clone(),
                session_id: entry.session_id.clone(),
                working_on: entry.working_on.clone(),
                next_step: entry.next_step.clone(),
                context,
            };
        }
    }

    idle_state
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ProjectStatus {
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub status: Option<String>,
    pub blocker: Option<String>,
    pub updated_at: Option<String>,
}

fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
    let status_path = PathBuf::from(project_path)
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

#[tauri::command]
fn get_project_status(project_path: String) -> Result<Option<ProjectStatus>, String> {
    Ok(read_project_status(&project_path))
}

#[tauri::command]
fn get_session_state(project_path: String) -> Result<ProjectSessionState, String> {
    Ok(detect_session_state(&project_path))
}

#[tauri::command]
fn get_all_session_states(
    project_paths: Vec<String>,
) -> Result<HashMap<String, ProjectSessionState>, String> {
    let mut states = HashMap::new();
    for path in project_paths {
        states.insert(path.clone(), detect_session_state(&path));
    }
    Ok(states)
}

#[tauri::command]
fn update_project_status(project_path: String, status: String) -> Result<ProjectStatus, String> {
    let status_path = PathBuf::from(&project_path)
        .join(".claude")
        .join("hud-status.json");

    let claude_dir = PathBuf::from(&project_path).join(".claude");
    if !claude_dir.exists() {
        fs::create_dir_all(&claude_dir).map_err(|e| e.to_string())?;
    }

    let mut current_status = read_project_status(&project_path).unwrap_or_default();
    current_status.status = Some(status);
    current_status.updated_at = Some(chrono::Utc::now().to_rfc3339());

    let content = serde_json::to_string_pretty(&current_status).map_err(|e| e.to_string())?;
    fs::write(&status_path, content).map_err(|e| e.to_string())?;

    Ok(current_status)
}

const HUD_STATUS_SCRIPT: &str = r#"#!/bin/bash

# Claude HUD Status Generator
# Generates project status at end of each Claude session

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')

if [ "$stop_hook_active" = "true" ]; then
  echo '{"ok": true}'
  exit 0
fi

if [ -z "$cwd" ] || [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
  echo '{"ok": true}'
  exit 0
fi

echo '{"ok": true}'

(
  mkdir -p "$cwd/.claude"
  context=$(tail -100 "$transcript_path" | grep -E '"type":"(user|assistant)"' | tail -20)

  if [ -z "$context" ]; then
    exit 0
  fi

  claude_cmd=$(command -v claude || echo "/opt/homebrew/bin/claude")

  response=$("$claude_cmd" -p \
    --no-session-persistence \
    --output-format json \
    --model haiku \
    "Summarize this coding session as JSON with fields: working_on (string), next_step (string), status (in_progress/blocked/needs_review/paused/done), blocker (string or null). Context: $context" 2>/dev/null)

  if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    exit 0
  fi

  result_text=$(echo "$response" | jq -r '.result // empty')
  if [ -z "$result_text" ]; then
    exit 0
  fi

  status=$(echo "$result_text" | jq -e . 2>/dev/null)
  if [ -z "$status" ] || [ "$status" = "null" ]; then
    status=$(echo "$result_text" | sed -n '/^```json/,/^```$/p' | sed '1d;$d' | jq -e . 2>/dev/null)
  fi
  if [ -z "$status" ] || [ "$status" = "null" ]; then
    status=$(echo "$result_text" | sed -n '/^```/,/^```$/p' | sed '1d;$d' | jq -e . 2>/dev/null)
  fi
  if [ -z "$status" ] || [ "$status" = "null" ]; then
    exit 0
  fi

  status=$(echo "$status" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {updated_at: $ts}')
  echo "$status" > "$cwd/.claude/hud-status.json"
) &>/dev/null &

disown 2>/dev/null
exit 0
"#;

#[tauri::command]
fn check_global_hook_installed() -> Result<bool, String> {
    let claude_dir = get_claude_dir().ok_or("Could not find Claude directory")?;
    let settings_path = claude_dir.join("settings.json");
    let script_path = claude_dir.join("scripts").join("hud-state-tracker.sh");

    if !script_path.exists() {
        return Ok(false);
    }

    if !settings_path.exists() {
        return Ok(false);
    }

    let content = fs::read_to_string(&settings_path)
        .map_err(|e| format!("Failed to read settings: {}", e))?;

    let settings: serde_json::Value =
        serde_json::from_str(&content).map_err(|e| format!("Failed to parse settings: {}", e))?;

    let has_hook = settings
        .get("hooks")
        .and_then(|h| h.get("Stop"))
        .and_then(|s| s.as_array())
        .map(|arr| {
            arr.iter().any(|item| {
                item.get("hooks")
                    .and_then(|h| h.as_array())
                    .map(|hooks| {
                        hooks.iter().any(|hook| {
                            hook.get("command")
                                .and_then(|c| c.as_str())
                                .map(|cmd| cmd.contains("hud-state-tracker.sh"))
                                .unwrap_or(false)
                        })
                    })
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false);

    Ok(has_hook)
}

#[tauri::command]
fn install_global_hook() -> Result<(), String> {
    let claude_dir = get_claude_dir().ok_or("Could not find Claude directory")?;
    let scripts_dir = claude_dir.join("scripts");
    let script_path = scripts_dir.join("generate-hud-status.sh");
    let settings_path = claude_dir.join("settings.json");

    fs::create_dir_all(&scripts_dir)
        .map_err(|e| format!("Failed to create scripts directory: {}", e))?;

    fs::write(&script_path, HUD_STATUS_SCRIPT)
        .map_err(|e| format!("Failed to write script: {}", e))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&script_path)
            .map_err(|e| format!("Failed to get script metadata: {}", e))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&script_path, perms)
            .map_err(|e| format!("Failed to set script permissions: {}", e))?;
    }

    let mut settings: serde_json::Value = if settings_path.exists() {
        let content = fs::read_to_string(&settings_path)
            .map_err(|e| format!("Failed to read settings: {}", e))?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let hook_config = serde_json::json!([{
        "hooks": [{
            "type": "command",
            "command": "~/.claude/scripts/generate-hud-status.sh"
        }]
    }]);

    if settings.get("hooks").is_none() {
        settings["hooks"] = serde_json::json!({});
    }
    settings["hooks"]["Stop"] = hook_config;

    let content = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;

    fs::write(&settings_path, content).map_err(|e| format!("Failed to write settings: {}", e))?;

    Ok(())
}

#[tauri::command]
fn start_status_watcher(app: tauri::AppHandle, project_paths: Vec<String>) -> Result<(), String> {
    std::thread::spawn(move || {
        let (tx, rx) = mpsc::channel();

        let mut watcher: RecommendedWatcher =
            match notify::recommended_watcher(move |res: Result<Event, _>| {
                if let Ok(event) = res {
                    let _ = tx.send(event);
                }
            }) {
                Ok(w) => w,
                Err(e) => {
                    log::error!("Failed to create watcher: {}", e);
                    return;
                }
            };

        for path in &project_paths {
            let status_path = PathBuf::from(path).join(".claude").join("hud-status.json");
            if let Some(parent) = status_path.parent() {
                if parent.exists() {
                    let _ = watcher.watch(parent, RecursiveMode::NonRecursive);
                }
            }
        }

        loop {
            match rx.recv_timeout(Duration::from_secs(60)) {
                Ok(event) => {
                    if matches!(event.kind, EventKind::Modify(_) | EventKind::Create(_)) {
                        for path in &event.paths {
                            if path
                                .file_name()
                                .map(|n| n == "hud-status.json")
                                .unwrap_or(false)
                            {
                                if let Some(project_path) = path.parent().and_then(|p| p.parent()) {
                                    let project_path_str =
                                        project_path.to_string_lossy().to_string();
                                    if let Some(status) = read_project_status(&project_path_str) {
                                        let _ = app
                                            .emit("status-changed", (&project_path_str, &status));
                                    }
                                }
                            }
                        }
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    });

    Ok(())
}

#[tauri::command]
fn start_session_state_watcher(app: tauri::AppHandle) -> Result<(), String> {
    std::thread::spawn(move || {
        let claude_dir = match get_claude_dir() {
            Some(dir) => dir,
            None => return,
        };

        let state_file = claude_dir.join("hud-session-states.json");

        let (tx, rx) = mpsc::channel();

        let mut watcher: RecommendedWatcher =
            match notify::recommended_watcher(move |res: Result<Event, _>| {
                if let Ok(event) = res {
                    let _ = tx.send(event);
                }
            }) {
                Ok(w) => w,
                Err(e) => {
                    log::error!("Failed to create session state watcher: {}", e);
                    return;
                }
            };

        if let Err(e) = watcher.watch(&claude_dir, RecursiveMode::NonRecursive) {
            log::error!("Failed to watch claude dir: {}", e);
            return;
        }

        loop {
            match rx.recv_timeout(Duration::from_secs(60)) {
                Ok(event) => {
                    if matches!(event.kind, EventKind::Modify(_) | EventKind::Create(_)) {
                        for path in &event.paths {
                            if path
                                .file_name()
                                .map(|n| n == "hud-session-states.json")
                                .unwrap_or(false)
                                || *path == state_file
                            {
                                if let Some(states) = load_session_states_file() {
                                    let _ = app.emit("session-states-changed", &states);
                                }
                                break;
                            }
                        }
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    });

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            load_dashboard,
            load_projects,
            load_project_details,
            load_artifacts,
            toggle_plugin,
            read_file_content,
            open_in_editor,
            open_folder,
            launch_in_terminal,
            bring_project_windows_to_front,
            add_project,
            remove_project,
            load_suggested_projects,
            get_project_status,
            update_project_status,
            get_session_state,
            get_all_session_states,
            check_global_hook_installed,
            install_global_hook,
            start_status_watcher,
            start_session_state_watcher,
            get_focused_project_path
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
