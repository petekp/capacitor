//! Storage configuration and path management for Capacitor.
//!
//! This module provides a centralized `StorageConfig` struct that manages all
//! file paths for Capacitor data. This abstraction enables:
//!
//! - Easy path changes without hunting through code
//! - Testability via dependency injection (inject mock/temp paths)
//! - Future flexibility (env var overrides, XDG compliance, alternate backends)
//!
//! ## Design Principles
//!
//! - **Single source of truth**: All path decisions centralized here
//! - **Testable**: `StorageConfig::with_root()` enables test injection
//! - **Forward-compatible**: Easy to add env var overrides, XDG support, etc.
//! Keep callers path-agnostic; avoid hardcoding `~/.capacitor` or `~/.claude` elsewhere.

use std::path::{Path, PathBuf};

/// Central configuration for all Capacitor storage paths.
///
/// Production code uses `StorageConfig::default()` which points to `~/.capacitor/`.
/// Tests use `StorageConfig::with_root(temp_dir)` for isolation.
#[derive(Debug, Clone)]
pub struct StorageConfig {
    /// Root directory for all Capacitor data (default: ~/.capacitor)
    root: PathBuf,
    /// Root directory for Claude Code data (default: ~/.claude)
    /// Used for reading Claude artifacts (JSONL files, plugins, etc.)
    claude_root: PathBuf,
}

impl Default for StorageConfig {
    fn default() -> Self {
        let home = dirs::home_dir().unwrap_or_else(std::env::temp_dir);
        Self {
            root: home.join(".capacitor"),
            claude_root: home.join(".claude"),
        }
    }
}

impl StorageConfig {
    /// Creates a StorageConfig with a custom root directory.
    /// Used for testing with temp directories.
    pub fn with_root(root: PathBuf) -> Self {
        let claude_root = root
            .parent()
            .map(|p| p.join(".claude"))
            .unwrap_or_else(|| PathBuf::from("/tmp/.claude"));
        Self { root, claude_root }
    }

    /// Creates a StorageConfig with both custom root and claude_root.
    /// Used for testing scenarios that need to mock Claude data too.
    pub fn with_roots(root: PathBuf, claude_root: PathBuf) -> Self {
        Self { root, claude_root }
    }

    /// Returns the root directory for Capacitor data.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Returns the root directory for Claude Code data.
    /// Used for reading Claude artifacts (JSONL session files, plugins, etc.)
    pub fn claude_root(&self) -> &Path {
        &self.claude_root
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Global Files
    // ─────────────────────────────────────────────────────────────────────────────

    /// Path to sessions.json (active session states).
    pub fn sessions_file(&self) -> PathBuf {
        self.root.join("sessions.json")
    }

    /// Path to projects.json (tracked projects list).
    pub fn projects_file(&self) -> PathBuf {
        self.root.join("projects.json")
    }

    /// Path to summaries.json (session summaries cache).
    pub fn summaries_file(&self) -> PathBuf {
        self.root.join("summaries.json")
    }

    /// Path to project-summaries.json (AI-generated project descriptions).
    pub fn project_summaries_file(&self) -> PathBuf {
        self.root.join("project-summaries.json")
    }

    /// Path to stats-cache.json (token usage cache).
    pub fn stats_cache_file(&self) -> PathBuf {
        self.root.join("stats-cache.json")
    }

    /// Path to file-activity.json (file activity tracking).
    pub fn file_activity_file(&self) -> PathBuf {
        self.root.join("file-activity.json")
    }

    /// Path to config.json (app preferences).
    pub fn config_file(&self) -> PathBuf {
        self.root.join("config.json")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Directories
    // ─────────────────────────────────────────────────────────────────────────────

    /// Path to sessions/ directory (lock directories).
    pub fn sessions_dir(&self) -> PathBuf {
        self.root.join("sessions")
    }

    /// Path to projects/ directory (per-project data).
    pub fn projects_dir(&self) -> PathBuf {
        self.root.join("projects")
    }

    /// Path to agents/ directory (agent registry).
    pub fn agents_dir(&self) -> PathBuf {
        self.root.join("agents")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Per-Project Paths
    // ─────────────────────────────────────────────────────────────────────────────

    /// Path to a project's data directory.
    /// Example: ~/.capacitor/projects/p2_%2FUsers%2Fpete%2FCode%2Fmy-project/
    pub fn project_data_dir(&self, project_path: &str) -> PathBuf {
        let encoded = Self::encode_path(project_path);
        let new_path = self.root.join("projects").join(&encoded);

        let legacy_encoded = Self::encode_path_legacy(project_path);
        let legacy_path = self.root.join("projects").join(legacy_encoded);

        if legacy_path.exists() && !new_path.exists() {
            legacy_path
        } else {
            new_path
        }
    }

    /// Path to a project's ideas file.
    /// Example: ~/.capacitor/projects/p2_%2FUsers%2Fpete%2FCode%2Fmy-project/ideas.md
    pub fn project_ideas_file(&self, project_path: &str) -> PathBuf {
        self.project_data_dir(project_path).join("ideas.md")
    }

    /// Path to a project's idea order file.
    /// Example: ~/.capacitor/projects/p2_%2FUsers%2Fpete%2FCode%2Fmy-project/ideas-order.json
    pub fn project_order_file(&self, project_path: &str) -> PathBuf {
        self.project_data_dir(project_path).join("ideas-order.json")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Claude Code Paths (Read-Only)
    // ─────────────────────────────────────────────────────────────────────────────

    /// Path to Claude Code's projects directory (JSONL session files).
    /// We read from here but don't write - this is Claude's data.
    pub fn claude_projects_dir(&self) -> PathBuf {
        self.claude_root.join("projects")
    }

    /// Path to Claude Code's plugins directory.
    pub fn claude_plugins_dir(&self) -> PathBuf {
        self.claude_root.join("plugins")
    }

    /// Path to Claude Code's settings file.
    pub fn claude_settings_file(&self) -> PathBuf {
        self.claude_root.join("settings.json")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Path Encoding/Decoding
    // ─────────────────────────────────────────────────────────────────────────────

    /// Encodes a filesystem path for use as a directory name.
    /// Uses a lossless, percent-encoded scheme with a versioned prefix.
    /// Example: `/Users/pete/Code/my-project` -> `p2_%2FUsers%2Fpete%2FCode%2Fmy-project`
    pub fn encode_path(path: &str) -> String {
        Self::encode_path_v2(path)
    }

    /// Decodes an encoded path back to the original filesystem path.
    /// Supports both v2 (lossless) and legacy (lossy) encodings.
    /// For reliable resolution, use `try_resolve_encoded_path` which checks filesystem.
    pub fn decode_path(encoded: &str) -> String {
        if let Some(stripped) = encoded.strip_prefix(Self::ENCODED_PREFIX) {
            return decode_percent(stripped);
        }

        if encoded.is_empty() || !encoded.starts_with('-') {
            return encoded.to_string();
        }

        // Legacy reversal: replace leading `-` and subsequent `-` with `/`.
        // This is lossy if the original path contained `-`.
        format!("/{}", &encoded[1..].replace('-', "/"))
    }

    /// Attempts to resolve an encoded path to a real filesystem path.
    /// Checks the filesystem to handle ambiguous cases (paths with `-` in names).
    pub fn try_resolve_encoded_path(encoded: &str) -> Option<String> {
        if encoded.is_empty() {
            return None;
        }

        if let Some(stripped) = encoded.strip_prefix(Self::ENCODED_PREFIX) {
            let decoded = decode_percent(stripped);
            if PathBuf::from(&decoded).exists() {
                return Some(decoded);
            }
            return None;
        }

        if !encoded.starts_with('-') {
            return None;
        }

        let without_leading = &encoded[1..];
        let parts: Vec<&str> = without_leading.split('-').collect();

        // Try progressively longer path prefixes
        for num_parts in 1..=parts.len() {
            let prefix = parts[..num_parts].join("/");
            let candidate = format!("/{}", prefix);

            if PathBuf::from(&candidate).exists() {
                if num_parts == parts.len() {
                    return Some(candidate);
                }

                // Try the rest as a hyphenated suffix
                let suffix = parts[num_parts..].join("-");
                let full_candidate = format!("{}/{}", candidate, suffix);
                if PathBuf::from(&full_candidate).exists() {
                    return Some(full_candidate);
                }
            }
        }

        None
    }

    const ENCODED_PREFIX: &'static str = "p2_";

    fn encode_path_v2(path: &str) -> String {
        let mut out = String::with_capacity(path.len() + Self::ENCODED_PREFIX.len());
        out.push_str(Self::ENCODED_PREFIX);
        for &b in path.as_bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' | b'-' => {
                    out.push(b as char);
                }
                _ => {
                    out.push('%');
                    out.push(to_hex((b >> 4) & 0x0f));
                    out.push(to_hex(b & 0x0f));
                }
            }
        }
        out
    }

    fn encode_path_legacy(path: &str) -> String {
        path.replace('/', "-")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Directory Creation
    // ─────────────────────────────────────────────────────────────────────────────

    /// Ensures the root directory and standard subdirectories exist.
    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        std::fs::create_dir_all(self.sessions_dir())?;
        std::fs::create_dir_all(self.projects_dir())?;
        std::fs::create_dir_all(self.agents_dir())?;
        Ok(())
    }

    /// Ensures a project's data directory exists.
    pub fn ensure_project_dir(&self, project_path: &str) -> std::io::Result<()> {
        std::fs::create_dir_all(self.project_data_dir(project_path))
    }
}

fn decode_percent(encoded: &str) -> String {
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (from_hex(bytes[i + 1]), from_hex(bytes[i + 2])) {
                out.push((high << 4) | low);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn to_hex(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'A' + (n - 10)) as char,
        _ => '0',
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ─────────────────────────────────────────────────────────────────────────────
    // Default Configuration Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_default_root_is_capacitor() {
        let config = StorageConfig::default();
        assert!(config.root().ends_with(".capacitor"));
    }

    #[test]
    fn test_default_claude_root_is_claude() {
        let config = StorageConfig::default();
        assert!(config.claude_root().ends_with(".claude"));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Custom Root Tests (for test injection)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_with_root_sets_custom_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/test-capacitor"));
        assert_eq!(config.root(), Path::new("/tmp/test-capacitor"));
    }

    #[test]
    fn test_with_roots_sets_both_paths() {
        let config = StorageConfig::with_roots(
            PathBuf::from("/tmp/capacitor"),
            PathBuf::from("/tmp/claude"),
        );
        assert_eq!(config.root(), Path::new("/tmp/capacitor"));
        assert_eq!(config.claude_root(), Path::new("/tmp/claude"));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Global File Path Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_sessions_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.sessions_file(),
            PathBuf::from("/tmp/capacitor/sessions.json")
        );
    }

    #[test]
    fn test_projects_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.projects_file(),
            PathBuf::from("/tmp/capacitor/projects.json")
        );
    }

    #[test]
    fn test_summaries_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.summaries_file(),
            PathBuf::from("/tmp/capacitor/summaries.json")
        );
    }

    #[test]
    fn test_project_summaries_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.project_summaries_file(),
            PathBuf::from("/tmp/capacitor/project-summaries.json")
        );
    }

    #[test]
    fn test_stats_cache_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.stats_cache_file(),
            PathBuf::from("/tmp/capacitor/stats-cache.json")
        );
    }

    #[test]
    fn test_file_activity_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.file_activity_file(),
            PathBuf::from("/tmp/capacitor/file-activity.json")
        );
    }

    #[test]
    fn test_config_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.config_file(),
            PathBuf::from("/tmp/capacitor/config.json")
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Directory Path Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_sessions_dir_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.sessions_dir(),
            PathBuf::from("/tmp/capacitor/sessions")
        );
    }

    #[test]
    fn test_projects_dir_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(
            config.projects_dir(),
            PathBuf::from("/tmp/capacitor/projects")
        );
    }

    #[test]
    fn test_agents_dir_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        assert_eq!(config.agents_dir(), PathBuf::from("/tmp/capacitor/agents"));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Per-Project Path Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_project_data_dir_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        let encoded = StorageConfig::encode_path("/Users/pete/Code/my-project");
        assert_eq!(
            config.project_data_dir("/Users/pete/Code/my-project"),
            PathBuf::from("/tmp/capacitor/projects").join(encoded)
        );
    }

    #[test]
    fn test_project_ideas_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        let encoded = StorageConfig::encode_path("/Users/pete/Code/my-project");
        assert_eq!(
            config.project_ideas_file("/Users/pete/Code/my-project"),
            PathBuf::from("/tmp/capacitor/projects")
                .join(encoded)
                .join("ideas.md")
        );
    }

    #[test]
    fn test_project_order_file_path() {
        let config = StorageConfig::with_root(PathBuf::from("/tmp/capacitor"));
        let encoded = StorageConfig::encode_path("/Users/pete/Code/my-project");
        assert_eq!(
            config.project_order_file("/Users/pete/Code/my-project"),
            PathBuf::from("/tmp/capacitor/projects")
                .join(encoded)
                .join("ideas-order.json")
        );
    }

    #[test]
    fn test_project_data_dir_prefers_legacy_when_present() {
        let temp = TempDir::new().unwrap();
        let config = StorageConfig::with_root(temp.path().to_path_buf());

        let project_path = "/Users/pete/Code/my-project";
        let legacy_encoded = StorageConfig::encode_path_legacy(project_path);
        let legacy_dir = temp.path().join("projects").join(&legacy_encoded);
        fs::create_dir_all(&legacy_dir).unwrap();

        assert_eq!(config.project_data_dir(project_path), legacy_dir);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Claude Path Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_claude_projects_dir_path() {
        let config = StorageConfig::with_roots(
            PathBuf::from("/tmp/capacitor"),
            PathBuf::from("/tmp/claude"),
        );
        assert_eq!(
            config.claude_projects_dir(),
            PathBuf::from("/tmp/claude/projects")
        );
    }

    #[test]
    fn test_claude_plugins_dir_path() {
        let config = StorageConfig::with_roots(
            PathBuf::from("/tmp/capacitor"),
            PathBuf::from("/tmp/claude"),
        );
        assert_eq!(
            config.claude_plugins_dir(),
            PathBuf::from("/tmp/claude/plugins")
        );
    }

    #[test]
    fn test_claude_settings_file_path() {
        let config = StorageConfig::with_roots(
            PathBuf::from("/tmp/capacitor"),
            PathBuf::from("/tmp/claude"),
        );
        assert_eq!(
            config.claude_settings_file(),
            PathBuf::from("/tmp/claude/settings.json")
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Path Encoding/Decoding Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_encode_path_replaces_slashes() {
        assert_eq!(
            StorageConfig::encode_path("/Users/pete/Code/my-project"),
            "p2_%2FUsers%2Fpete%2FCode%2Fmy-project"
        );
    }

    #[test]
    fn test_encode_path_root() {
        assert_eq!(StorageConfig::encode_path("/"), "p2_%2F");
    }

    #[test]
    fn test_decode_path_restores_slashes() {
        assert_eq!(
            StorageConfig::decode_path("p2_%2FUsers%2Fpete%2FCode%2Ffoo"),
            "/Users/pete/Code/foo"
        );
    }

    #[test]
    fn test_decode_path_legacy() {
        assert_eq!(
            StorageConfig::decode_path("-Users-pete-Code-foo"),
            "/Users/pete/Code/foo"
        );
    }

    #[test]
    fn test_decode_path_empty() {
        assert_eq!(StorageConfig::decode_path(""), "");
    }

    #[test]
    fn test_decode_path_no_leading_dash() {
        assert_eq!(StorageConfig::decode_path("no-leading"), "no-leading");
    }

    #[test]
    fn test_encode_decode_roundtrip_simple() {
        // Simple path without hyphens - roundtrip works
        let original = "/Users/pete/Code/project";
        let encoded = StorageConfig::encode_path(original);
        let decoded = StorageConfig::decode_path(&encoded);
        assert_eq!(decoded, original);
    }

    #[test]
    fn test_encode_path_with_hyphens_is_lossless() {
        let original = "/Users/pete/my-project";
        let encoded = StorageConfig::encode_path(original);
        let decoded = StorageConfig::decode_path(&encoded);
        assert_eq!(decoded, original);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Directory Creation Tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_ensure_dirs_creates_structure() {
        let temp = TempDir::new().unwrap();
        let config = StorageConfig::with_root(temp.path().to_path_buf());

        config.ensure_dirs().unwrap();

        assert!(temp.path().exists());
        assert!(config.sessions_dir().exists());
        assert!(config.projects_dir().exists());
        assert!(config.agents_dir().exists());
    }

    #[test]
    fn test_ensure_project_dir_creates_directory() {
        let temp = TempDir::new().unwrap();
        let config = StorageConfig::with_root(temp.path().to_path_buf());

        config.ensure_project_dir("/Users/pete/Code/test").unwrap();

        assert!(config.project_data_dir("/Users/pete/Code/test").exists());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Filesystem Resolution Tests (require actual filesystem)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_try_resolve_encoded_path_with_hyphenated_dir() {
        let temp = TempDir::new().unwrap();
        let hyphenated_dir = temp.path().join("my-project");
        std::fs::create_dir(&hyphenated_dir).unwrap();

        // Encode the path
        let path = hyphenated_dir.to_string_lossy().to_string();
        let encoded = StorageConfig::encode_path(&path);

        // Resolve should find the actual directory
        let resolved = StorageConfig::try_resolve_encoded_path(&encoded);
        assert_eq!(resolved, Some(path));
    }

    #[test]
    fn test_try_resolve_encoded_path_nonexistent() {
        let result = StorageConfig::try_resolve_encoded_path("p2_%2Fnonexistent-path-xyz");
        assert!(result.is_none());
    }

    #[test]
    fn test_try_resolve_encoded_path_empty() {
        assert!(StorageConfig::try_resolve_encoded_path("").is_none());
    }

    #[test]
    fn test_try_resolve_encoded_path_no_leading_dash() {
        assert!(StorageConfig::try_resolve_encoded_path("no-leading-dash").is_none());
    }
}
