//! Statistics parsing and caching for Claude Code sessions.
//!
//! Parses token usage and activity data from JSONL session files,
//! with intelligent mtime-based caching to avoid re-parsing unchanged files.
//! Parsing is best-effort; malformed lines simply do not contribute to totals.

use crate::patterns::*;
use crate::types::{CachedFileInfo, CachedProjectStats, ProjectStats, StatsCache};
use fs_err as fs;
use std::collections::HashMap;
use std::path::Path;
use std::time::SystemTime;

/// Parses statistics from session file content and accumulates into stats.
pub fn parse_stats_from_content(content: &str, stats: &mut ProjectStats) {
    for cap in RE_INPUT_TOKENS.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_input_tokens += n;
        }
    }

    for cap in RE_OUTPUT_TOKENS.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_output_tokens += n;
        }
    }

    for cap in RE_CACHE_READ.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_cache_read_tokens += n;
        }
    }

    for cap in RE_CACHE_CREATE.captures_iter(content) {
        if let Ok(n) = cap[1].parse::<u64>() {
            stats.total_cache_creation_tokens += n;
        }
    }

    for cap in RE_MODEL.captures_iter(content) {
        let model = &cap[1];
        if model.contains("opus") {
            stats.opus_messages += 1;
        } else if model.contains("sonnet") {
            stats.sonnet_messages += 1;
        } else if model.contains("haiku") {
            stats.haiku_messages += 1;
        }
    }

    if let Some(cap) = RE_SUMMARY.captures_iter(content).last() {
        stats.latest_summary = Some(cap[1].to_string());
    }

    for cap in RE_TIMESTAMP.captures_iter(content) {
        let ts = &cap[1];
        let date = ts.split('T').next().unwrap_or(ts);

        if stats.first_activity.is_none() || stats.first_activity.as_deref() > Some(date) {
            stats.first_activity = Some(date.to_string());
        }
        if stats.last_activity.is_none() || stats.last_activity.as_deref() < Some(date) {
            stats.last_activity = Some(date.to_string());
        }
    }
}

/// Computes project statistics with intelligent caching.
///
/// Uses file mtime to determine if re-parsing is needed, avoiding
/// redundant file reads for unchanged session files.
pub fn compute_project_stats(
    claude_projects_dir: &Path,
    encoded_name: &str,
    cache: &mut StatsCache,
    project_path: &str,
) -> ProjectStats {
    let project_dir = claude_projects_dir.join(encoded_name);

    if !project_dir.exists() {
        return ProjectStats::default();
    }

    let cached = cache.projects.get(project_path);
    let mut current_files: HashMap<String, CachedFileInfo> = HashMap::new();
    let mut needs_recompute = false;

    if let Ok(entries) = fs::read_dir(&project_dir) {
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "jsonl") {
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
                let is_new_or_modified =
                    cached_file.map_or(true, |cf| cf.size != size || cf.mtime != mtime);

                if is_new_or_modified {
                    needs_recompute = true;
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

    let mut stats = ProjectStats {
        session_count: current_files.len() as u32,
        ..Default::default()
    };

    for entry in fs::read_dir(&project_dir)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "jsonl") {
            if let Ok(content) = fs::read_to_string(&path) {
                parse_stats_from_content(&content, &mut stats);
            }
        }
    }

    cache.projects.insert(
        project_path.to_string(),
        CachedProjectStats {
            files: current_files,
            stats: stats.clone(),
        },
    );

    stats
}
