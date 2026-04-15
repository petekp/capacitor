//! Core types shared across all Capacitor clients.
//!
//! These types are the "lingua franca" of the HUD ecosystem. All clients
//! (Swift desktop, TUI, mobile) use these exact same types, ensuring consistency.
//!
//! **FFI Support:** All types are annotated with UniFFI macros for Swift/Kotlin/Python bindings.
//!
//! **Note:** These types are exported via UniFFI for Swift consumption.
//! Prefer additive changes; renames or removals are breaking for clients.

use crate::domain::{SessionState, StateSource};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ═══════════════════════════════════════════════════════════════════════════════
// Global Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Global Claude Code configuration and artifact counts.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct GlobalConfig {
    pub settings_path: String,
    pub settings_exists: bool,
    pub instructions_path: Option<String>,
    pub skills_dir: Option<String>,
    pub commands_dir: Option<String>,
    pub agents_dir: Option<String>,
    pub skill_count: u32,
    pub command_count: u32,
    pub agent_count: u32,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Plugin Types
// ═══════════════════════════════════════════════════════════════════════════════

/// An installed Claude Code plugin.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct Plugin {
    pub id: String,
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub path: String,
    pub skill_count: u32,
    pub command_count: u32,
    pub agent_count: u32,
    pub hook_count: u32,
}

/// Plugin manifest from plugin.json.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct PluginManifest {
    pub name: String,
    pub description: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Statistics Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Aggregated token usage statistics for a project.
#[derive(Debug, Serialize, Deserialize, Clone, Default, uniffi::Record)]
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

/// Cached file metadata for cache invalidation.
#[derive(Debug, Serialize, Deserialize, Clone, Default, uniffi::Record)]
pub struct CachedFileInfo {
    pub size: u64,
    pub mtime: u64,
}

/// Cached statistics for a single project.
#[derive(Debug, Serialize, Deserialize, Clone, Default, uniffi::Record)]
pub struct CachedProjectStats {
    pub files: HashMap<String, CachedFileInfo>,
    pub stats: ProjectStats,
}

/// The full stats cache, persisted to disk.
#[derive(Debug, Serialize, Deserialize, Clone, Default, uniffi::Record)]
pub struct StatsCache {
    pub projects: HashMap<String, CachedProjectStats>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Project Types
// ═══════════════════════════════════════════════════════════════════════════════

/// A pinned project in the HUD.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
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
    /// True if the project directory no longer exists on disk.
    #[serde(default)]
    pub is_missing: bool,
}

/// A task/session from a project (represents Claude Code sessions).
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct Task {
    pub id: String,
    pub name: String,
    pub path: String,
    pub last_modified: String,
    pub summary: Option<String>,
    pub first_message: Option<String>,
}

/// Detailed project information including tasks and git status.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct ProjectDetails {
    pub project: Project,
    pub claude_md_content: Option<String>,
    pub tasks: Vec<Task>,
    pub git_branch: Option<String>,
    pub git_dirty: bool,
}

/// A project discovered in `~/.claude/projects/` but not yet pinned.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct SuggestedProject {
    pub path: String,
    pub display_path: String,
    pub name: String,
    pub task_count: u32,
    pub has_claude_md: bool,
    pub has_project_indicators: bool,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Artifact Types
// ═══════════════════════════════════════════════════════════════════════════════

/// A skill, command, or agent definition.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct Artifact {
    pub artifact_type: String,
    pub name: String,
    pub description: String,
    pub source: String,
    pub path: String,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Dashboard Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Aggregate data for the dashboard view.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct DashboardData {
    pub global: GlobalConfig,
    pub plugins: Vec<Plugin>,
    pub projects: Vec<Project>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Configuration Types
// ═══════════════════════════════════════════════════════════════════════════════

fn default_terminal_app() -> String {
    "Ghostty".to_string()
}

/// HUD configuration (pinned projects, etc.)
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct HudConfig {
    pub pinned_projects: Vec<String>,
    #[serde(default = "default_terminal_app")]
    pub terminal_app: String,
}

impl Default for HudConfig {
    fn default() -> Self {
        Self {
            pinned_projects: Vec::new(),
            terminal_app: default_terminal_app(),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Session State Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Context window usage information.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct ContextInfo {
    pub percent_used: u32,
    pub tokens_used: u64,
    pub context_size: u64,
    pub updated_at: Option<String>,
}

/// Full session state with context information.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct ProjectSessionState {
    pub state: SessionState,
    pub state_changed_at: Option<String>,
    /// Timestamp of last hook event (more recent than state_changed_at).
    /// Use this for activity comparison between sessions.
    pub updated_at: Option<String>,
    pub session_id: Option<String>,
    pub working_on: Option<String>,
    pub context: Option<ContextInfo>,
    /// Whether Claude is currently "thinking" (API call in flight).
    /// This provides real-time status when using the fetch-intercepting launcher.
    pub thinking: Option<bool>,
    /// Whether the runtime considers this project actively running.
    #[serde(default)]
    pub has_session: bool,
    /// Typed provenance of the representative session's current state.
    /// `None` for legacy snapshots without state-source tracking, and when
    /// the session ID cannot be resolved in the session index.
    #[serde(default)]
    pub state_source: Option<StateSource>,
    /// Timestamp (RFC3339) of the most recent DefinitiveTerminal-authority
    /// event observed for the representative session. Used by UI to show
    /// how stale an inferred/ambiguous state is.
    #[serde(default)]
    pub last_authoritative_event_at: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Project Creation Types (Idea → V1 Launcher)
// ═══════════════════════════════════════════════════════════════════════════════

/// Request to create a new project from an idea.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct NewProjectRequest {
    pub name: String,
    pub description: String,
    pub location: String,
    pub language: Option<String>,
    pub framework: Option<String>,
}

/// Status of a project creation.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Default, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum CreationStatus {
    #[default]
    Pending,
    InProgress,
    Completed,
    Failed,
    Cancelled,
}

/// Progress information for a project creation.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct CreationProgress {
    pub phase: String,
    pub message: String,
    pub percent_complete: Option<u8>,
}

/// A project being created via the Idea → V1 flow.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct ProjectCreation {
    pub id: String,
    pub name: String,
    pub path: String,
    pub description: String,
    pub status: CreationStatus,
    pub session_id: Option<String>,
    pub progress: Option<CreationProgress>,
    pub error: Option<String>,
    pub created_at: String,
    pub completed_at: Option<String>,
}

/// Result of starting a project creation.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct CreateProjectResult {
    pub success: bool,
    pub project_path: String,
    pub session_id: Option<String>,
    pub error: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Idea Capture Types
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// Hook Health Types
// ═══════════════════════════════════════════════════════════════════════════════

/// The health status of the hook binary based on service-owned hook activity freshness.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum HookHealthStatus {
    /// Hooks are firing normally (recent hook activity within threshold)
    Healthy,
    /// No recent hook activity has been observed yet
    Unknown,
    /// Hook activity is stale (hooks stopped firing)
    Stale { last_seen_secs: u64 },
}

/// Full health report for hook activity freshness.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HookHealthReport {
    pub status: HookHealthStatus,
    pub signal_source: String,
    pub threshold_secs: u64,
    pub last_hook_event_age_secs: Option<u64>,
}

/// Result of running a comprehensive hook system test.
///
/// This verifies both recent hook activity and local runtime
/// service health. Used by the "Test Hooks" button in the UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HookTestResult {
    /// True if all tests passed
    pub success: bool,
    /// True if recent hook activity is present
    pub hook_activity_ok: bool,
    /// Age of the last hook activity event in seconds (None if unavailable)
    pub hook_activity_age_secs: Option<u64>,
    /// True if the local runtime service health check passed
    pub runtime_service_ok: bool,
    /// Human-readable summary message for display
    pub message: String,
}

/// The primary issue preventing hooks from working correctly.
///
/// Issues are prioritized: policy blocks are shown first (can't auto-fix),
/// then installation issues, then runtime issues.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum HookIssue {
    /// Hooks disabled by policy (disableAllHooks or allowManagedHooksOnly)
    PolicyBlocked { reason: String },
    /// The hud-hook binary is not installed
    BinaryMissing,
    /// The hud-hook binary exists but crashes (e.g., macOS codesigning)
    BinaryBroken { reason: String },
    /// The hud-hook symlink exists but points to a missing target (app moved, cargo clean, etc.)
    SymlinkBroken { target: String, reason: String },
    /// Hook configuration missing or incomplete in settings.json
    ConfigMissing,
    /// Hooks are installed but not firing (activity stale or missing)
    NotFiring { last_seen_secs: Option<u64> },
}

/// Unified diagnostic report combining installation status and runtime health.
///
/// This provides a single source of truth for the UI to determine what to show
/// and whether auto-fix is available.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HookDiagnosticReport {
    /// True if everything is working correctly
    pub is_healthy: bool,
    /// The most critical issue to display (if any)
    pub primary_issue: Option<HookIssue>,
    /// True if "Fix All" can resolve the issue
    pub can_auto_fix: bool,
    /// Whether Capacitor setup has never completed on this machine.
    pub is_first_run: bool,
    /// Detailed status for checklist display
    pub binary_ok: bool,
    pub config_ok: bool,
    pub firing_ok: bool,
    /// Path to the hook binary/symlink (e.g., ~/.local/bin/hud-hook)
    pub symlink_path: String,
    /// Target of the symlink if it is one, None if regular file or doesn't exist
    pub symlink_target: Option<String>,
    /// Age of last hook activity in seconds (for "last seen X ago" display)
    pub last_hook_event_age_secs: Option<u64>,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Idea Capture Types
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// Parent App Types
// ═══════════════════════════════════════════════════════════════════════════════

/// The parent application hosting a shell session.
///
/// This is the authoritative enum for app identification, exported via UniFFI
/// to Swift. All app classification logic should use this type rather than
/// parsing strings directly.
///
/// **JSON serialization:** Uses lowercase strings (e.g., `ParentApp::ITerm` → `"iterm2"`)
/// to match the runtime shell snapshot JSON shape.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default, uniffi::Enum,
)]
#[serde(rename_all = "lowercase")]
pub enum ParentApp {
    // Terminals
    Ghostty,
    #[serde(rename = "iterm2")]
    ITerm,
    Terminal,
    Alacritty,
    Kitty,
    Warp,
    // IDEs
    Cursor,
    #[serde(rename = "vscode")]
    VSCode,
    #[serde(rename = "vscode-insiders")]
    VSCodeInsiders,
    Zed,
    // Multiplexers
    Tmux,
    // Fallback
    #[default]
    Unknown,
}

impl ParentApp {
    /// Parse a parent app identifier string (as stored in JSON).
    pub fn from_string(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "ghostty" => Self::Ghostty,
            "iterm2" => Self::ITerm,
            "terminal" => Self::Terminal,
            "alacritty" => Self::Alacritty,
            "kitty" => Self::Kitty,
            "warp" => Self::Warp,
            "cursor" => Self::Cursor,
            "vscode" => Self::VSCode,
            "vscode-insiders" => Self::VSCodeInsiders,
            "zed" => Self::Zed,
            "tmux" => Self::Tmux,
            _ => Self::Unknown,
        }
    }

    /// Whether this app is a native terminal emulator.
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Ghostty
                | Self::ITerm
                | Self::Terminal
                | Self::Alacritty
                | Self::Kitty
                | Self::Warp
        )
    }

    /// Whether this app is an IDE with an integrated terminal.
    #[must_use]
    pub fn is_ide(&self) -> bool {
        matches!(
            self,
            Self::Cursor | Self::VSCode | Self::VSCodeInsiders | Self::Zed
        )
    }

    /// Whether this app is a terminal multiplexer.
    #[must_use]
    pub fn is_multiplexer(&self) -> bool {
        matches!(self, Self::Tmux)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Idea Capture Types
// ═══════════════════════════════════════════════════════════════════════════════

/// A captured idea stored in `~/.capacitor/projects/{encoded}/ideas.md`.
///
/// Ideas are stored in markdown format with ULID identifiers for stable references.
/// They can be in various states (open, in-progress, done) and have triage status.
#[derive(Debug, Serialize, Deserialize, Clone, uniffi::Record)]
pub struct Idea {
    /// ULID identifier (26 chars, uppercase, sortable)
    pub id: String,
    /// Short title extracted from first line
    pub title: String,
    /// Full description text
    pub description: String,
    /// ISO8601 timestamp when added
    pub added: String,
    /// Effort estimate: unknown, small, medium, large, xl
    pub effort: String,
    /// Status: open, in-progress, done
    pub status: String,
    /// Triage status: pending, validated
    pub triage: String,
    /// Related project name (if associated with a specific project)
    pub related: Option<String>,
}
