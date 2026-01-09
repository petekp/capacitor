use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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

fn default_terminal_app() -> String {
    "Ghostty".to_string()
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct HudConfig {
    pub pinned_projects: Vec<String>,
    #[serde(default = "default_terminal_app")]
    pub terminal_app: String,
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
    Working,
    Ready,
    Idle,
    Compacting,
    Waiting,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ContextInfo {
    pub percent_used: u32,
    pub tokens_used: u64,
    pub context_size: u64,
    pub updated_at: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectSessionState {
    pub state: SessionState,
    pub state_changed_at: Option<String>,
    pub session_id: Option<String>,
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub context: Option<ContextInfo>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct SessionStatesFile {
    pub version: u32,
    pub projects: HashMap<String, SessionStateEntry>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ContextInfoEntry {
    pub percent_used: Option<u32>,
    pub tokens_used: Option<u64>,
    pub context_size: Option<u64>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct SessionStateEntry {
    #[serde(default)]
    pub state: String,
    pub state_changed_at: Option<String>,
    pub session_id: Option<String>,
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub context: Option<ContextInfoEntry>,
}

