//! Artifact discovery and parsing for Claude Code plugins.
//!
//! This module handles:
//! - Counting artifacts (skills, commands, agents)
//! - Parsing frontmatter from markdown files
//! - Collecting artifact metadata
//! - Frontmatter parsing is best-effort; missing fields default to empty strings.

use crate::runtime_patterns::{RE_FRONTMATTER, RE_FRONTMATTER_DESC, RE_FRONTMATTER_NAME};
use std::path::Path;
use walkdir::WalkDir;

/// Counts artifacts of a given type in a directory.
///
/// For skills: counts directories containing SKILL.md or skill.md
/// For commands/agents: counts .md files
///
/// Returns u32 for FFI compatibility (usize is platform-dependent).
pub fn count_artifacts_in_dir(dir: &Path, artifact_type: &str) -> u32 {
    if !dir.exists() {
        return 0;
    }

    let count = match artifact_type {
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
    };
    count as u32
}

/// Counts hooks in a plugin directory.
///
/// Returns u32 for FFI compatibility.
pub fn count_hooks_in_dir(dir: &Path) -> u32 {
    let hooks_json = dir.join("hooks").join("hooks.json");
    if hooks_json.exists() {
        1
    } else {
        0
    }
}

/// Parses YAML frontmatter from markdown content.
///
/// Returns (name, description) tuple if frontmatter exists.
pub fn parse_frontmatter(content: &str) -> Option<(String, String)> {
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
