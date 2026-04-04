//! Configuration loading and saving utilities.
//!
//! Handles paths and persistence for:
//! - HUD configuration (pinned projects)
//! - Statistics cache
//!
//! Callers provide a `StorageConfig` so path resolution stays explicit and testable.
//! Reads are best-effort; malformed files return defaults to keep the app usable.

use crate::runtime::storage::StorageConfig;
use crate::runtime::types::{HudConfig, StatsCache};
use fs_err as fs;
use std::path::PathBuf;

/// Returns the path to the projects configuration file for a specific storage root.
pub(crate) fn get_projects_config_path_for(storage: &StorageConfig) -> PathBuf {
    storage.projects_file()
}

/// Loads the HUD configuration from a specific storage root.
pub(crate) fn load_hud_config_with_storage(storage: &StorageConfig) -> HudConfig {
    let path = get_projects_config_path_for(storage);
    fs::read_to_string(&path)
        .ok()
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the HUD configuration to disk for a specific storage root.
pub(crate) fn save_hud_config_with_storage(
    storage: &StorageConfig,
    config: &HudConfig,
) -> Result<(), String> {
    let path = get_projects_config_path_for(storage);

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create config directory: {}", e))?;
    }

    let content = serde_json::to_string_pretty(config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;

    let tmp_path = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut file = fs::File::create(&tmp_path)
            .map_err(|e| format!("Failed to create config temp file: {}", e))?;
        file.write_all(content.as_bytes())
            .map_err(|e| format!("Failed to write config temp file: {}", e))?;
        file.sync_all()
            .map_err(|e| format!("Failed to sync config temp file: {}", e))?;
    }
    fs::rename(&tmp_path, &path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path); // Cleanup temp file on rename failure
        format!("Failed to commit config file: {}", e)
    })
}

/// Returns the path to the statistics cache file for a specific storage root.
pub(crate) fn get_stats_cache_path_for(storage: &StorageConfig) -> PathBuf {
    storage.stats_cache_file()
}

/// Loads the statistics cache for a specific storage root.
pub(crate) fn load_stats_cache_with_storage(storage: &StorageConfig) -> StatsCache {
    let path = get_stats_cache_path_for(storage);
    fs::read_to_string(&path)
        .ok()
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the statistics cache to disk for a specific storage root.
pub(crate) fn save_stats_cache_with_storage(
    storage: &StorageConfig,
    cache: &StatsCache,
) -> Result<(), String> {
    let path = get_stats_cache_path_for(storage);

    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create cache directory: {}", e))?;
    }

    let content =
        serde_json::to_string(cache).map_err(|e| format!("Failed to serialize cache: {}", e))?;

    let tmp_path = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut file = fs::File::create(&tmp_path)
            .map_err(|e| format!("Failed to create cache temp file: {}", e))?;
        file.write_all(content.as_bytes())
            .map_err(|e| format!("Failed to write cache temp file: {}", e))?;
        file.sync_all()
            .map_err(|e| format!("Failed to sync cache temp file: {}", e))?;
    }
    fs::rename(&tmp_path, &path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path); // Cleanup temp file on rename failure
        format!("Failed to commit cache file: {}", e)
    })
}

/// Resolves a symlink to its canonical path.
pub(crate) fn resolve_symlink(path: &PathBuf) -> Option<PathBuf> {
    if path.exists() {
        fs::canonicalize(path).ok()
    } else {
        None
    }
}
