use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, SystemTime};
use regex::Regex;
use walkdir::WalkDir;
use notify::{Watcher, RecommendedWatcher, RecursiveMode, Event, EventKind};
use tauri::Emitter;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct GlobalConfig {
    pub settings_path: String,
    pub settings_exists: bool,
    pub instructions_path: Option<String>,
    pub skills_dir: Option<String>,
    pub commands_dir: Option<String>,
    pub agents_dir: Option<String>,
    pub skill_count: usize,
    pub command_count: usize,
    pub agent_count: usize,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Plugin {
    pub id: String,
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub path: String,
    pub skill_count: usize,
    pub command_count: usize,
    pub agent_count: usize,
    pub hook_count: usize,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ProjectStats {
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_creation_tokens: u64,
    pub opus_messages: u32,
    pub sonnet_messages: u32,
    pub haiku_messages: u32,
    pub session_count: u32,
    pub latest_summary: Option<String>,
    pub first_activity: Option<String>,
    pub last_activity: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct CachedFileInfo {
    pub size: u64,
    pub mtime: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct CachedProjectStats {
    pub files: HashMap<String, CachedFileInfo>,
    pub stats: ProjectStats,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct StatsCache {
    pub projects: HashMap<String, CachedProjectStats>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Project {
    pub name: String,
    pub path: String,
    pub display_path: String,
    pub last_active: Option<String>,
    pub claude_md_path: Option<String>,
    pub claude_md_preview: Option<String>,
    pub has_local_settings: bool,
    pub task_count: u32,
    pub stats: Option<ProjectStats>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Task {
    pub id: String,
    pub name: String,
    pub path: String,
    pub last_modified: String,
    pub summary: Option<String>,
    pub first_message: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectDetails {
    pub project: Project,
    pub claude_md_content: Option<String>,
    pub tasks: Vec<Task>,
    pub git_branch: Option<String>,
    pub git_dirty: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Artifact {
    pub artifact_type: String,
    pub name: String,
    pub description: String,
    pub source: String,
    pub path: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DashboardData {
    pub global: GlobalConfig,
    pub plugins: Vec<Plugin>,
    pub projects: Vec<Project>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct HudConfig {
    pub pinned_projects: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SuggestedProject {
    pub path: String,
    pub display_path: String,
    pub name: String,
    pub task_count: u32,
    pub has_claude_md: bool,
    pub has_project_indicators: bool,
}

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

fn get_claude_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude"))
}

fn get_hud_config_path() -> Option<PathBuf> {
    get_claude_dir().map(|d| d.join("hud.json"))
}

fn load_hud_config() -> HudConfig {
    get_hud_config_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

fn save_hud_config(config: &HudConfig) -> Result<(), String> {
    let path = get_hud_config_path().ok_or("Could not find config path")?;
    let content = serde_json::to_string_pretty(config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    fs::write(&path, content)
        .map_err(|e| format!("Failed to write config: {}", e))
}

fn get_stats_cache_path() -> Option<PathBuf> {
    get_claude_dir().map(|d| d.join("hud-stats-cache.json"))
}

fn load_stats_cache() -> StatsCache {
    get_stats_cache_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

fn save_stats_cache(cache: &StatsCache) -> Result<(), String> {
    let path = get_stats_cache_path().ok_or("Could not find cache path")?;
    let content = serde_json::to_string(cache)
        .map_err(|e| format!("Failed to serialize cache: {}", e))?;
    fs::write(&path, content)
        .map_err(|e| format!("Failed to write cache: {}", e))
}

fn parse_stats_from_content(content: &str, stats: &mut ProjectStats) {
    let input_re = Regex::new(r#""input_tokens":(\d+)"#).unwrap();
    let output_re = Regex::new(r#""output_tokens":(\d+)"#).unwrap();
    let cache_read_re = Regex::new(r#""cache_read_input_tokens":(\d+)"#).unwrap();
    let cache_create_re = Regex::new(r#""cache_creation_input_tokens":(\d+)"#).unwrap();
    let model_re = Regex::new(r#""model":"claude-([^"]+)"#).unwrap();
    let summary_re = Regex::new(r#""type":"summary","summary":"([^"]+)""#).unwrap();
    let timestamp_re = Regex::new(r#""timestamp":"(\d{4}-\d{2}-\d{2}T[^"]+)""#).unwrap();

    for cap in input_re.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_input_tokens += n;
        }
    }

    for cap in output_re.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_output_tokens += n;
        }
    }

    for cap in cache_read_re.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_cache_read_tokens += n;
        }
    }

    for cap in cache_create_re.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_cache_creation_tokens += n;
        }
    }

    for cap in model_re.captures_iter(content) {
        let model = &cap[1];
        if model.contains("opus") {
            stats.opus_messages += 1;
        } else if model.contains("sonnet") {
            stats.sonnet_messages += 1;
        } else if model.contains("haiku") {
            stats.haiku_messages += 1;
        }
    }

    if let Some(cap) = summary_re.captures_iter(content).last() {
        stats.latest_summary = Some(cap[1].to_string());
    }

    for cap in timestamp_re.captures_iter(content) {
        let ts = &cap[1];
        let date = ts.split('T').next().unwrap_or(ts);

        if stats.first_activity.is_none() || stats.first_activity.as_ref().map(|s| s.as_str()) > Some(date) {
            stats.first_activity = Some(date.to_string());
        }
        if stats.last_activity.is_none() || stats.last_activity.as_ref().map(|s| s.as_str()) < Some(date) {
            stats.last_activity = Some(date.to_string());
        }
    }
}

fn compute_project_stats(claude_projects_dir: &PathBuf, encoded_name: &str, cache: &mut StatsCache, project_path: &str) -> ProjectStats {
    let project_dir = claude_projects_dir.join(encoded_name);

    if !project_dir.exists() {
        return ProjectStats::default();
    }

    let cached = cache.projects.get(project_path);
    let mut current_files: HashMap<String, CachedFileInfo> = HashMap::new();
    let mut needs_recompute = false;
    let mut files_to_parse: Vec<(PathBuf, bool)> = Vec::new();

    if let Ok(entries) = fs::read_dir(&project_dir) {
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "jsonl") {
                let filename = entry.file_name().to_string_lossy().to_string();
                let metadata = entry.metadata().ok();

                let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
                let mtime = metadata
                    .as_ref()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);

                current_files.insert(filename.clone(), CachedFileInfo { size, mtime });

                let cached_file = cached.and_then(|c| c.files.get(&filename));
                let is_new_or_modified = cached_file.map_or(true, |cf| cf.size != size || cf.mtime != mtime);

                if is_new_or_modified {
                    needs_recompute = true;
                    files_to_parse.push((path, true));
                }
            }
        }
    }

    let file_count_changed = cached.map_or(true, |c| c.files.len() != current_files.len());
    if file_count_changed {
        needs_recompute = true;
    }

    if !needs_recompute {
        if let Some(c) = cached {
            return c.stats.clone();
        }
    }

    let mut stats = ProjectStats::default();
    stats.session_count = current_files.len() as u32;

    for entry in fs::read_dir(&project_dir).into_iter().flatten().filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.extension().map_or(false, |ext| ext == "jsonl") {
            if let Ok(content) = fs::read_to_string(&path) {
                parse_stats_from_content(&content, &mut stats);
            }
        }
    }

    cache.projects.insert(project_path.to_string(), CachedProjectStats {
        files: current_files,
        stats: stats.clone(),
    });

    stats
}

fn resolve_symlink(path: &PathBuf) -> Option<PathBuf> {
    if path.exists() {
        fs::canonicalize(path).ok()
    } else {
        None
    }
}

fn count_artifacts_in_dir(dir: &PathBuf, artifact_type: &str) -> usize {
    if !dir.exists() {
        return 0;
    }

    match artifact_type {
        "skills" => {
            WalkDir::new(dir)
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
                .count()
        }
        "commands" | "agents" => {
            WalkDir::new(dir)
                .min_depth(1)
                .max_depth(1)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path().extension().map_or(false, |ext| ext == "md")
                })
                .count()
        }
        _ => 0,
    }
}

fn count_hooks_in_dir(dir: &PathBuf) -> usize {
    let hooks_json = dir.join("hooks").join("hooks.json");
    if hooks_json.exists() {
        1
    } else {
        0
    }
}

fn parse_frontmatter(content: &str) -> Option<(String, String)> {
    let re = Regex::new(r"(?s)^---\s*\n(.*?)\n---").ok()?;
    let caps = re.captures(content)?;
    let frontmatter = caps.get(1)?.as_str();

    let name_re = Regex::new(r"(?m)^name:\s*(.+)$").ok()?;
    let desc_re = Regex::new(r"(?m)^description:\s*(.+)$").ok()?;

    let name = name_re.captures(frontmatter)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    let description = desc_re.captures(frontmatter)
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
            for entry in WalkDir::new(dir).min_depth(1).max_depth(1).into_iter().filter_map(|e| e.ok()) {
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
                        let (name, description) = parse_frontmatter(&content)
                            .unwrap_or_else(|| {
                                (entry.file_name().to_string_lossy().to_string(), String::new())
                            });
                        artifacts.push(Artifact {
                            artifact_type: "skill".to_string(),
                            name: if name.is_empty() { entry.file_name().to_string_lossy().to_string() } else { name },
                            description,
                            source: source.to_string(),
                            path: skill_path.to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
        "command" | "agent" => {
            for entry in WalkDir::new(dir).min_depth(1).max_depth(1).into_iter().filter_map(|e| e.ok()) {
                if entry.path().extension().map_or(false, |ext| ext == "md") {
                    if let Ok(content) = fs::read_to_string(entry.path()) {
                        let (name, description) = parse_frontmatter(&content)
                            .unwrap_or_else(|| {
                                let file_stem = entry.path().file_stem()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default();
                                (file_stem, String::new())
                            });
                        artifacts.push(Artifact {
                            artifact_type: artifact_type.to_string(),
                            name: if name.is_empty() {
                                entry.path().file_stem()
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
    result = Regex::new(r"\*\*([^*]+)\*\*").unwrap().replace_all(&result, "$1").to_string();
    result = Regex::new(r"\*([^*]+)\*").unwrap().replace_all(&result, "$1").to_string();
    result = Regex::new(r"__([^_]+)__").unwrap().replace_all(&result, "$1").to_string();
    result = Regex::new(r"_([^_]+)_").unwrap().replace_all(&result, "$1").to_string();
    result = Regex::new(r"`([^`]+)`").unwrap().replace_all(&result, "$1").to_string();
    result = Regex::new(r"^#+\s*").unwrap().replace_all(&result, "").to_string();
    result = Regex::new(r"\[([^\]]+)\]\([^)]+\)").unwrap().replace_all(&result, "$1").to_string();
    result
}

fn extract_text_from_content(content: &serde_json::Value) -> Option<String> {
    if let Some(s) = content.as_str() {
        return Some(s.to_string());
    }

    if let Some(arr) = content.as_array() {
        let texts: Vec<String> = arr.iter()
            .filter_map(|item| {
                if item.get("type").and_then(|t| t.as_str()) == Some("text") {
                    item.get("text").and_then(|t| t.as_str()).map(|s| s.to_string())
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
        _ => return SessionExtract { first_message: None, summary: None },
    }

    let file = match fs::File::open(session_path) {
        Ok(f) => f,
        Err(_) => return SessionExtract { first_message: None, summary: None },
    };

    let reader = BufReader::new(file);
    let summary_re = Regex::new(r#""type":"summary","summary":"([^"]+)""#).ok();

    let mut first_message: Option<String> = None;
    let mut first_command: Option<String> = None;
    let mut last_summary: Option<String> = None;

    for line in reader.lines().filter_map(|l| l.ok()) {
        if let Some(ref re) = summary_re {
            if let Some(cap) = re.captures(&line) {
                last_summary = Some(cap[1].to_string());
            }
        }

        if first_message.is_some() {
            continue;
        }

        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&line) {
            let msg_type = json.get("type").and_then(|t| t.as_str());
            let is_meta = json.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false);

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
        if mins == 1 { "1 minute ago".to_string() } else { format!("{} minutes ago", mins) }
    } else if secs < 86400 {
        let hours = secs / 3600;
        if hours == 1 { "1 hour ago".to_string() } else { format!("{} hours ago", hours) }
    } else if secs < 604800 {
        let days = secs / 86400;
        if days == 1 { "yesterday".to_string() } else { format!("{} days ago", days) }
    } else {
        let weeks = secs / 604800;
        if weeks == 1 { "1 week ago".to_string() } else { format!("{} weeks ago", weeks) }
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

fn count_tasks_in_project(claude_projects_dir: &PathBuf, encoded_name: &str) -> u32 {
    let project_dir = claude_projects_dir.join(encoded_name);
    if !project_dir.exists() {
        return 0;
    }

    // Tasks are stored as .jsonl files directly in the project folder
    fs::read_dir(&project_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().map_or(false, |ext| ext == "jsonl"))
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
        commands_dir: commands_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
        agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
        skill_count: skills_dir.as_ref().map(|d| count_artifacts_in_dir(d, "skills")).unwrap_or(0),
        command_count: commands_dir.as_ref().map(|d| count_artifacts_in_dir(d, "commands")).unwrap_or(0),
        agent_count: agents_dir.as_ref().map(|d| count_artifacts_in_dir(d, "agents")).unwrap_or(0),
    };

    let plugins = load_plugins(&claude_dir).unwrap_or_default();
    let projects = load_projects_internal(&claude_dir).unwrap_or_default();

    Ok(DashboardData {
        global,
        plugins,
        projects,
    })
}

fn load_plugins(claude_dir: &PathBuf) -> Result<Vec<Plugin>, String> {
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

fn has_project_indicators(project_path: &PathBuf) -> bool {
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

    indicators.iter().any(|indicator| project_path.join(indicator).exists())
}

fn build_project_from_path(path: &str, claude_dir: &PathBuf, stats_cache: &mut StatsCache) -> Option<Project> {
    let project_path = PathBuf::from(path);
    if !project_path.exists() {
        return None;
    }

    let encoded_name = path.replace('/', "-");
    let projects_dir = claude_dir.join("projects");

    let display_path = if path.starts_with("/Users/") {
        format!("~/{}", path.split('/').skip(3).collect::<Vec<_>>().join("/"))
    } else {
        path.to_string()
    };

    let project_name = path.split('/').last().unwrap_or(path).to_string();

    let claude_project_dir = projects_dir.join(&encoded_name);
    let last_modified = claude_project_dir.metadata()
        .ok()
        .and_then(|m| m.modified().ok());
    let last_active = last_modified.map(|t| format_relative_time(t));

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

fn load_projects_internal(claude_dir: &PathBuf) -> Result<Vec<Project>, String> {
    let config = load_hud_config();
    let projects_dir = claude_dir.join("projects");
    let mut stats_cache = load_stats_cache();

    let mut projects: Vec<(Project, SystemTime)> = Vec::new();

    for path in &config.pinned_projects {
        if let Some(project) = build_project_from_path(path, claude_dir, &mut stats_cache) {
            let encoded_name = path.replace('/', "-");
            let claude_project_dir = projects_dir.join(&encoded_name);
            let sort_time = claude_project_dir.metadata()
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
        format!("~/{}", path.split('/').skip(3).collect::<Vec<_>>().join("/"))
    } else {
        path.clone()
    };

    let project_name = path.split('/').last().unwrap_or(&path).to_string();

    let project_folder = projects_dir.join(&encoded_name);
    let last_modified = project_folder.metadata()
        .ok()
        .and_then(|m| m.modified().ok());
    let last_active = last_modified.map(|t| format_relative_time(t));

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
    let stats = stats_cache.projects.get(&path)
        .map(|c| c.stats.clone())
        .unwrap_or_default();

    let mut tasks_with_time: Vec<(Task, SystemTime)> = Vec::new();
    let claude_project_dir = projects_dir.join(&encoded_name);
    if claude_project_dir.exists() {
        if let Ok(entries) = fs::read_dir(&claude_project_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                let task_path = entry.path();
                if task_path.extension().map_or(false, |ext| ext == "jsonl") {
                    let task_id = entry.file_name().to_string_lossy().to_string();
                    let task_name = task_id.trim_end_matches(".jsonl").to_string();

                    if task_name.starts_with("agent-") {
                        continue;
                    }

                    let mtime = entry.metadata()
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
        let branch = fs::read_to_string(&head_path)
            .ok()
            .and_then(|content| {
                if content.starts_with("ref: refs/heads/") {
                    Some(content.trim_start_matches("ref: refs/heads/").trim().to_string())
                } else {
                    Some("detached".to_string())
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
        artifacts.extend(collect_artifacts_from_dir(&commands_dir, "command", "Global"));
    }

    if let Some(agents_dir) = resolve_symlink(&claude_dir.join("agents")) {
        artifacts.extend(collect_artifacts_from_dir(&agents_dir, "agent", "Global"));
    }

    let plugins = load_plugins(&claude_dir).unwrap_or_default();
    for plugin in plugins {
        if plugin.enabled {
            let plugin_path = PathBuf::from(&plugin.path);
            artifacts.extend(collect_artifacts_from_dir(&plugin_path.join("skills"), "skill", &plugin.name));
            artifacts.extend(collect_artifacts_from_dir(&plugin_path.join("commands"), "command", &plugin.name));
            artifacts.extend(collect_artifacts_from_dir(&plugin_path.join("agents"), "agent", &plugin.name));
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
        serde_json::from_str(&content)
            .map_err(|e| format!("Failed to parse settings: {}", e))?
    } else {
        serde_json::json!({})
    };

    if settings.get("enabledPlugins").is_none() {
        settings["enabledPlugins"] = serde_json::json!({});
    }

    settings["enabledPlugins"][&plugin_id] = serde_json::Value::Bool(enabled);

    let content = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Failed to serialize settings: {}", e))?;

    fs::write(&settings_path, content)
        .map_err(|e| format!("Failed to write settings: {}", e))?;

    Ok(())
}

#[tauri::command]
fn read_file_content(path: String) -> Result<String, String> {
    fs::read_to_string(&path)
        .map_err(|e| format!("Failed to read file: {}", e))
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

#[tauri::command]
fn launch_in_terminal(path: String, run_claude: bool) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        if run_claude {
            let script = format!(
                r#"
                tell application "Warp"
                    activate
                    delay 0.2
                    tell application "System Events"
                        keystroke "n" using command down
                        delay 0.3
                        keystroke "cd {} && claude"
                        keystroke return
                    end tell
                end tell
                "#,
                path.replace("\"", "\\\"").replace("'", "'\\''")
            );

            std::process::Command::new("osascript")
                .arg("-e")
                .arg(&script)
                .spawn()
                .map_err(|e| format!("Failed to launch Warp with Claude: {}", e))?;
        } else {
            std::process::Command::new("open")
                .arg("-a")
                .arg("Warp")
                .arg(&path)
                .spawn()
                .map_err(|e| format!("Failed to launch Warp: {}", e))?;
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        return Err("Terminal launch is only supported on macOS currently".to_string());
    }

    Ok(())
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

        if !encoded_name.starts_with('-') || !entry.file_type().map_or(false, |t| t.is_dir()) {
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
            format!("~/{}", path.split('/').skip(3).collect::<Vec<_>>().join("/"))
        } else {
            path.clone()
        };

        let name = path.split('/').last().unwrap_or(&path).to_string();

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

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ProjectStatus {
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub status: Option<String>,
    pub blocker: Option<String>,
    pub updated_at: Option<String>,
}

fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
    let status_path = PathBuf::from(project_path).join(".claude").join("hud-status.json");
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
    let script_path = claude_dir.join("scripts").join("generate-hud-status.sh");

    if !script_path.exists() {
        return Ok(false);
    }

    if !settings_path.exists() {
        return Ok(false);
    }

    let content = fs::read_to_string(&settings_path)
        .map_err(|e| format!("Failed to read settings: {}", e))?;

    let settings: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| format!("Failed to parse settings: {}", e))?;

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
                                .map(|cmd| cmd.contains("generate-hud-status.sh"))
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

    fs::write(&settings_path, content)
        .map_err(|e| format!("Failed to write settings: {}", e))?;

    Ok(())
}

#[tauri::command]
fn start_status_watcher(app: tauri::AppHandle, project_paths: Vec<String>) -> Result<(), String> {
    std::thread::spawn(move || {
        let (tx, rx) = mpsc::channel();

        let mut watcher: RecommendedWatcher = match notify::recommended_watcher(move |res: Result<Event, _>| {
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
                            if path.file_name().map(|n| n == "hud-status.json").unwrap_or(false) {
                                if let Some(project_path) = path.parent().and_then(|p| p.parent()) {
                                    let project_path_str = project_path.to_string_lossy().to_string();
                                    if let Some(status) = read_project_status(&project_path_str) {
                                        let _ = app.emit("status-changed", (&project_path_str, &status));
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
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
            add_project,
            remove_project,
            load_suggested_projects,
            get_project_status,
            check_global_hook_installed,
            install_global_hook,
            start_status_watcher
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
