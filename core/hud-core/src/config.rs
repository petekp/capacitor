//! Configuration loading and saving utilities.
//!
//! Handles paths and persistence for:
//! - HUD configuration (pinned projects)
//! - Statistics cache
//!
//! Note: This module uses `StorageConfig::default()` for paths. For testing
//! with custom paths, use the `StorageConfig` struct directly.

use crate::types::{HudConfig, StatsCache};
use std::fs;
use std::path::PathBuf;

/// Returns the path to the Claude directory (~/.claude).
///
/// Used for reading Claude Code artifacts (session files, plugins, etc.).
/// Capacitor data lives in `~/.capacitor/` - see `get_capacitor_dir()`.
pub fn get_claude_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude"))
}

/// Returns the path to the Capacitor data directory (~/.capacitor).
///
/// This is where Capacitor stores its own data (projects, sessions, stats).
/// For Claude Code artifacts, use `get_claude_dir()`.
pub fn get_capacitor_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".capacitor"))
}

/// Returns the path to the projects configuration file.
///
/// Formerly `~/.claude/hud.json`, now `~/.capacitor/projects.json`.
pub fn get_projects_config_path() -> Option<PathBuf> {
    get_capacitor_dir().map(|d| d.join("projects.json"))
}

/// Returns the path to the HUD configuration file.
///
/// Deprecated: Use `get_projects_config_path()` instead.
/// This function remains for backward compatibility during migration.
#[deprecated(note = "Use get_projects_config_path() instead")]
pub fn get_hud_config_path() -> Option<PathBuf> {
    get_projects_config_path()
}

/// Loads the HUD configuration, returning defaults if file doesn't exist.
pub fn load_hud_config() -> HudConfig {
    get_projects_config_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the HUD configuration to disk.
pub fn save_hud_config(config: &HudConfig) -> Result<(), String> {
    let path = get_projects_config_path().ok_or("Could not find config path")?;

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create config directory: {}", e))?;
    }

    let content = serde_json::to_string_pretty(config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    fs::write(&path, content).map_err(|e| format!("Failed to write config: {}", e))
}

/// Returns the path to the statistics cache file.
///
/// Formerly `~/.claude/hud-stats-cache.json`, now `~/.capacitor/stats-cache.json`.
pub fn get_stats_cache_path() -> Option<PathBuf> {
    get_capacitor_dir().map(|d| d.join("stats-cache.json"))
}

/// Loads the statistics cache, returning empty cache if file doesn't exist.
pub fn load_stats_cache() -> StatsCache {
    get_stats_cache_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the statistics cache to disk.
pub fn save_stats_cache(cache: &StatsCache) -> Result<(), String> {
    let path = get_stats_cache_path().ok_or("Could not find cache path")?;

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create cache directory: {}", e))?;
    }

    let content =
        serde_json::to_string(cache).map_err(|e| format!("Failed to serialize cache: {}", e))?;
    fs::write(&path, content).map_err(|e| format!("Failed to write cache: {}", e))
}

/// Resolves a symlink to its canonical path.
pub fn resolve_symlink(path: &PathBuf) -> Option<PathBuf> {
    if path.exists() {
        fs::canonicalize(path).ok()
    } else {
        None
    }
}
