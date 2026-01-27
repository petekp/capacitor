//! Smart project path validation and CLAUDE.md generation.
//!
//! Validates paths when users add projects to the HUD, providing helpful
//! suggestions and offering to create CLAUDE.md files where missing.
//!
//! ## User Experience Goals
//!
//! - Guide users to pin at correct project boundaries
//! - Offer to create CLAUDE.md for better Claude Code integration
//! - Warn about paths that are too broad or problematic
//! - Be helpful, not blocking (validation is advisory)
//! - **Advisory**: Callers should treat results as guidance, not as hard errors.

use crate::boundaries::{
    canonicalize_path, find_project_boundary, is_dangerous_path, PROJECT_MARKERS,
};
use crate::error::Result;
use std::path::Path;

/// FFI-friendly validation result for Swift/Kotlin/Python.
///
/// Uses flat structure instead of enum variants for better FFI compatibility.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ValidationResultFfi {
    /// Result type: "valid", "suggest_parent", "missing_claude_md", "not_a_project", "path_not_found", "dangerous_path"
    pub result_type: String,
    /// The path (canonical or as provided, depending on result type)
    pub path: String,
    /// For suggest_parent: the suggested project path
    pub suggested_path: Option<String>,
    /// Human-readable reason for the result
    pub reason: Option<String>,
    /// Whether the project has a CLAUDE.md file
    pub has_claude_md: bool,
    /// Whether the project has other markers (.git, package.json, etc.)
    pub has_other_markers: bool,
}

impl From<ValidationResult> for ValidationResultFfi {
    fn from(result: ValidationResult) -> Self {
        match result {
            ValidationResult::Valid {
                path,
                has_claude_md,
            } => Self {
                result_type: "valid".to_string(),
                path,
                suggested_path: None,
                reason: None,
                has_claude_md,
                has_other_markers: true,
            },
            ValidationResult::SuggestParent {
                requested_path,
                suggested_path,
                reason,
            } => Self {
                result_type: "suggest_parent".to_string(),
                path: requested_path,
                suggested_path: Some(suggested_path),
                reason: Some(reason),
                has_claude_md: false,
                has_other_markers: false,
            },
            ValidationResult::MissingClaudeMd {
                path,
                has_other_markers,
            } => Self {
                result_type: "missing_claude_md".to_string(),
                path,
                suggested_path: None,
                reason: Some(
                    "Consider creating a CLAUDE.md file for better Claude Code integration."
                        .to_string(),
                ),
                has_claude_md: false,
                has_other_markers,
            },
            ValidationResult::NotAProject { path, reason } => Self {
                result_type: "not_a_project".to_string(),
                path,
                suggested_path: None,
                reason: Some(reason),
                has_claude_md: false,
                has_other_markers: false,
            },
            ValidationResult::PathNotFound { path } => Self {
                result_type: "path_not_found".to_string(),
                path,
                suggested_path: None,
                reason: Some("Path does not exist.".to_string()),
                has_claude_md: false,
                has_other_markers: false,
            },
            ValidationResult::DangerousPath { path, reason } => Self {
                result_type: "dangerous_path".to_string(),
                path,
                suggested_path: None,
                reason: Some(reason),
                has_claude_md: false,
                has_other_markers: false,
            },
            ValidationResult::AlreadyTracked { path, name } => Self {
                result_type: "already_tracked".to_string(),
                path,
                suggested_path: None,
                reason: Some(format!("\"{}\" is already in your HUD.", name)),
                has_claude_md: true,
                has_other_markers: true,
            },
        }
    }
}

/// Result of validating a project path.
#[derive(Debug, Clone, PartialEq)]
pub enum ValidationResult {
    /// Path is a valid project root
    Valid {
        /// Canonical path to the project
        path: String,
        /// Whether the project has a CLAUDE.md file
        has_claude_md: bool,
    },

    /// Path is inside a project - suggest pinning the parent
    SuggestParent {
        /// The path the user requested
        requested_path: String,
        /// The suggested parent project path
        suggested_path: String,
        /// Human-readable reason for the suggestion
        reason: String,
    },

    /// Path is a project root but missing CLAUDE.md
    MissingClaudeMd {
        /// Path to the project
        path: String,
        /// Whether the project has other markers (.git, package.json, etc.)
        has_other_markers: bool,
    },

    /// Path doesn't appear to be a project
    NotAProject {
        /// The path that was checked
        path: String,
        /// Human-readable reason
        reason: String,
    },

    /// Path doesn't exist
    PathNotFound {
        /// The path that was checked
        path: String,
    },

    /// Path is too broad (/, ~, /Users, etc.)
    DangerousPath {
        /// The path that was checked
        path: String,
        /// Human-readable reason
        reason: String,
    },

    /// Project is already tracked in the HUD
    AlreadyTracked {
        /// The path that was checked
        path: String,
        /// The project name (for display)
        name: String,
    },
}

/// Validates a path for use as a pinned project.
///
/// Returns a `ValidationResult` indicating whether the path is valid,
/// and if not, what the user should do instead.
///
/// # Arguments
/// * `path` - The path to validate
/// * `pinned_projects` - List of already-pinned project paths (to detect duplicates)
pub fn validate_project_path(path: &str, pinned_projects: &[String]) -> ValidationResult {
    // Normalize trailing slashes
    let normalized = path.trim_end_matches('/');
    let normalized = if normalized.is_empty() {
        "/"
    } else {
        normalized
    };

    // Check if path exists first (needed for canonical comparison)
    let canonical = match canonicalize_path(normalized) {
        Ok(p) => p,
        Err(_) => {
            return ValidationResult::PathNotFound {
                path: path.to_string(),
            }
        }
    };

    // Check if already tracked (before any other validation)
    for pinned in pinned_projects {
        if let Ok(pinned_canonical) = canonicalize_path(pinned) {
            if pinned_canonical == canonical {
                let name = std::path::Path::new(&canonical)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&canonical)
                    .to_string();
                return ValidationResult::AlreadyTracked {
                    path: canonical,
                    name,
                };
            }
        }
    }

    // Check for dangerous paths
    if let Some(reason) = is_dangerous_path(&canonical) {
        return ValidationResult::DangerousPath {
            path: canonical,
            reason,
        };
    }

    // Check if this path IS a project boundary
    let has_claude = has_claude_md(&canonical);
    let has_markers = has_any_project_marker(&canonical);

    if has_claude {
        // Valid project with CLAUDE.md
        return ValidationResult::Valid {
            path: canonical,
            has_claude_md: true,
        };
    }

    // Check if this path is INSIDE a project (should suggest parent)
    // We look for a boundary starting from the parent of the requested path
    if let Some(boundary) = find_project_boundary(&canonical) {
        // If the boundary is not the same as the requested path, suggest the parent
        if boundary.path != canonical {
            return ValidationResult::SuggestParent {
                requested_path: canonical.clone(),
                suggested_path: boundary.path,
                reason: "This path is inside a project. Consider pinning the project root instead."
                    .to_string(),
            };
        }
    }

    // Path has markers but no CLAUDE.md
    if has_markers {
        return ValidationResult::MissingClaudeMd {
            path: canonical,
            has_other_markers: true,
        };
    }

    // No markers at all - not a project
    ValidationResult::NotAProject {
        path: canonical,
        reason: "No project markers found (CLAUDE.md, .git, package.json, Cargo.toml, etc.)"
            .to_string(),
    }
}

/// Checks if a path has a CLAUDE.md file.
#[must_use]
pub fn has_claude_md(path: &str) -> bool {
    Path::new(path).join("CLAUDE.md").exists()
}

/// Checks if a path has any project markers (.git, package.json, etc.)
#[must_use]
pub fn has_any_project_marker(path: &str) -> bool {
    let dir = Path::new(path);
    PROJECT_MARKERS
        .iter()
        .any(|(marker, _)| dir.join(marker).exists())
}

/// Information extracted from package.json for CLAUDE.md generation.
#[derive(Debug, Clone, Default)]
pub struct PackageInfo {
    pub name: Option<String>,
    pub description: Option<String>,
    pub scripts: Vec<String>,
}

/// Information extracted from Cargo.toml for CLAUDE.md generation.
#[derive(Debug, Clone, Default)]
pub struct CargoInfo {
    pub name: Option<String>,
    pub description: Option<String>,
}

/// Extracts package information from package.json if present.
pub fn extract_package_json_info(project_path: &str) -> Option<PackageInfo> {
    let package_json_path = Path::new(project_path).join("package.json");
    let content = std::fs::read_to_string(&package_json_path).ok()?;

    let parsed: serde_json::Value = serde_json::from_str(&content).ok()?;

    let name = parsed
        .get("name")
        .and_then(|v| v.as_str())
        .map(String::from);
    let description = parsed
        .get("description")
        .and_then(|v| v.as_str())
        .map(String::from);

    let scripts = parsed
        .get("scripts")
        .and_then(|v| v.as_object())
        .map(|obj| obj.keys().cloned().collect())
        .unwrap_or_default();

    Some(PackageInfo {
        name,
        description,
        scripts,
    })
}

/// Extracts crate information from Cargo.toml if present.
pub fn extract_cargo_toml_info(project_path: &str) -> Option<CargoInfo> {
    use once_cell::sync::Lazy;
    use regex::Regex;

    // Match: name = "value" or name = 'value' with flexible whitespace
    // Valid TOML allows: name="value", name = "value", name  =  "value"
    static NAME_RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r#"^\s*name\s*=\s*["']([^"']+)["']"#).unwrap());
    static DESC_RE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r#"^\s*description\s*=\s*["']([^"']+)["']"#).unwrap());

    let cargo_toml_path = Path::new(project_path).join("Cargo.toml");
    let content = std::fs::read_to_string(&cargo_toml_path).ok()?;

    let mut name = None;
    let mut description = None;

    for line in content.lines() {
        if name.is_none() {
            if let Some(caps) = NAME_RE.captures(line) {
                name = caps.get(1).map(|m| m.as_str().to_string());
            }
        }
        if description.is_none() {
            if let Some(caps) = DESC_RE.captures(line) {
                description = caps.get(1).map(|m| m.as_str().to_string());
            }
        }
        if name.is_some() && description.is_some() {
            break;
        }
    }

    // Only return Some if we found at least a name
    if name.is_some() || description.is_some() {
        Some(CargoInfo { name, description })
    } else {
        None
    }
}

/// Generates CLAUDE.md content for a project.
///
/// Attempts to extract information from package.json, Cargo.toml, and README.md
/// to pre-populate the template.
pub fn generate_claude_md_content(project_path: &str) -> String {
    // Try to extract project info from package.json or Cargo.toml
    let pkg_info = extract_package_json_info(project_path);
    let cargo_info = extract_cargo_toml_info(project_path);

    // Determine project name and description
    let project_name = pkg_info
        .as_ref()
        .and_then(|p| p.name.clone())
        .or_else(|| cargo_info.as_ref().and_then(|c| c.name.clone()))
        .unwrap_or_else(|| {
            Path::new(project_path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("Project")
                .to_string()
        });

    let description = pkg_info
        .as_ref()
        .and_then(|p| p.description.clone())
        .or_else(|| cargo_info.as_ref().and_then(|c| c.description.clone()));

    // Build the template
    let mut content = format!("# {}\n\n", project_name);

    if let Some(desc) = description {
        content.push_str(&format!("{}\n\n", desc));
    }

    content.push_str("## Overview\n\n");
    content.push_str("<!-- Brief description of what this project does -->\n\n");

    // Add development commands if we found scripts
    if let Some(ref pkg) = pkg_info {
        if !pkg.scripts.is_empty() {
            content.push_str("## Development\n\n");
            content.push_str("```bash\n");
            for script in &pkg.scripts {
                content.push_str(&format!("npm run {}  # TODO: describe\n", script));
            }
            content.push_str("```\n\n");
        }
    } else if cargo_info.is_some() {
        content.push_str("## Development\n\n");
        content.push_str("```bash\n");
        content.push_str("cargo build   # Build the project\n");
        content.push_str("cargo test    # Run tests\n");
        content.push_str("cargo run     # Run the binary\n");
        content.push_str("```\n\n");
    }

    content.push_str("## Architecture\n\n");
    content.push_str("<!-- Key files and their purposes -->\n\n");

    content
}

/// Creates a CLAUDE.md file at the given project path.
///
/// Returns Ok(()) if successful, or an error if the file couldn't be created.
/// Does NOT overwrite existing files.
pub fn create_claude_md(project_path: &str) -> Result<()> {
    use crate::error::HudError;
    use std::io::Write;

    let claude_md_path = Path::new(project_path).join("CLAUDE.md");

    // Check if file already exists - don't overwrite
    if claude_md_path.exists() {
        return Ok(());
    }

    // Generate content
    let content = generate_claude_md_content(project_path);

    // Use atomic write pattern: write to temp file, then rename
    let tmp_path = claude_md_path.with_extension("md.tmp");

    let mut file = std::fs::File::create(&tmp_path).map_err(|e| HudError::Io {
        context: format!("Failed to create temp file for CLAUDE.md at {:?}", tmp_path),
        source: e,
    })?;

    file.write_all(content.as_bytes())
        .map_err(|e| HudError::Io {
            context: "Failed to write CLAUDE.md content".to_string(),
            source: e,
        })?;

    file.flush().map_err(|e| HudError::Io {
        context: "Failed to flush CLAUDE.md".to_string(),
        source: e,
    })?;

    std::fs::rename(&tmp_path, &claude_md_path).map_err(|e| HudError::Io {
        context: format!(
            "Failed to rename temp file to CLAUDE.md at {:?}",
            claude_md_path
        ),
        source: e,
    })?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ========================================
    // Test helpers
    // ========================================

    fn create_test_dir() -> TempDir {
        TempDir::new().expect("Failed to create temp dir")
    }

    fn create_file(dir: &Path, name: &str) {
        fs::write(dir.join(name), "").expect("Failed to create file");
    }

    fn create_file_with_content(dir: &Path, name: &str, content: &str) {
        fs::write(dir.join(name), content).expect("Failed to create file");
    }

    fn create_dir(dir: &Path, name: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        fs::create_dir_all(&path).expect("Failed to create dir");
        path
    }

    // ========================================
    // Valid project tests
    // ========================================

    #[test]
    fn valid_with_claude_md() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::Valid {
                path,
                has_claude_md,
            } => {
                assert!(path.contains(tmp.path().file_name().unwrap().to_str().unwrap()));
                assert!(has_claude_md, "Should detect CLAUDE.md");
            }
            other => panic!("Expected Valid, got {:?}", other),
        }
    }

    #[test]
    fn valid_with_git_only() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::MissingClaudeMd {
                path,
                has_other_markers,
            } => {
                assert!(path.contains(tmp.path().file_name().unwrap().to_str().unwrap()));
                assert!(has_other_markers, "Should detect .git as marker");
            }
            other => panic!("Expected MissingClaudeMd, got {:?}", other),
        }
    }

    #[test]
    fn valid_with_claude_md_and_git() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_dir(tmp.path(), ".git");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::Valid { has_claude_md, .. } => {
                assert!(has_claude_md);
            }
            other => panic!("Expected Valid, got {:?}", other),
        }
    }

    // ========================================
    // Suggest parent tests
    // ========================================

    #[test]
    fn suggests_parent_when_inside_project() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        let src = create_dir(tmp.path(), "src");

        let result = validate_project_path(src.to_str().unwrap(), &[]);

        match result {
            ValidationResult::SuggestParent {
                requested_path,
                suggested_path,
                reason,
            } => {
                assert!(requested_path.contains("src"));
                assert!(suggested_path.contains(tmp.path().file_name().unwrap().to_str().unwrap()));
                assert!(reason.contains("inside"));
            }
            other => panic!("Expected SuggestParent, got {:?}", other),
        }
    }

    #[test]
    fn suggests_package_root_not_src_directory() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        let pkg = create_dir(tmp.path(), "packages/auth");
        create_file(&pkg, "CLAUDE.md");
        create_file(&pkg, "package.json");

        let src = create_dir(&pkg, "src");
        create_file(&src, "index.ts");

        // User tries to pin src/ instead of the package root
        let result = validate_project_path(src.to_str().unwrap(), &[]);

        match result {
            ValidationResult::SuggestParent { suggested_path, .. } => {
                assert!(
                    suggested_path.ends_with("auth") || suggested_path.contains("auth"),
                    "Should suggest auth package, not monorepo root. Got: {}",
                    suggested_path
                );
            }
            other => panic!("Expected SuggestParent, got {:?}", other),
        }
    }

    #[test]
    fn suggests_monorepo_package_not_monorepo_root() {
        // When user tries to pin a deeply nested path, suggest the nearest
        // project boundary, not the top-level monorepo
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");
        create_file(tmp.path(), "CLAUDE.md"); // Monorepo has CLAUDE.md

        let pkg = create_dir(tmp.path(), "packages/auth");
        create_file(&pkg, "CLAUDE.md"); // Package also has CLAUDE.md

        let deep = create_dir(&pkg, "src/components/login");

        let result = validate_project_path(deep.to_str().unwrap(), &[]);

        match result {
            ValidationResult::SuggestParent { suggested_path, .. } => {
                // Should suggest the package, not the monorepo root
                assert!(
                    suggested_path.contains("auth"),
                    "Should suggest nearest project (auth), got: {}",
                    suggested_path
                );
            }
            other => panic!("Expected SuggestParent, got {:?}", other),
        }
    }

    // ========================================
    // Missing CLAUDE.md tests
    // ========================================

    #[test]
    fn detects_missing_claude_md_with_git() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");
        // No CLAUDE.md

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::MissingClaudeMd {
                has_other_markers, ..
            } => {
                assert!(has_other_markers);
            }
            other => panic!("Expected MissingClaudeMd, got {:?}", other),
        }
    }

    #[test]
    fn detects_missing_claude_md_with_package_json() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "package.json");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::MissingClaudeMd {
                has_other_markers, ..
            } => {
                assert!(has_other_markers);
            }
            other => panic!("Expected MissingClaudeMd, got {:?}", other),
        }
    }

    #[test]
    fn detects_missing_claude_md_with_cargo_toml() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "Cargo.toml");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::MissingClaudeMd {
                has_other_markers, ..
            } => {
                assert!(has_other_markers);
            }
            other => panic!("Expected MissingClaudeMd, got {:?}", other),
        }
    }

    // ========================================
    // Not a project tests
    // ========================================

    #[test]
    fn detects_random_directory() {
        let tmp = create_test_dir();
        // No markers at all

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::NotAProject { reason, .. } => {
                assert!(
                    reason.to_lowercase().contains("marker")
                        || reason.to_lowercase().contains("project")
                );
            }
            other => panic!("Expected NotAProject, got {:?}", other),
        }
    }

    #[test]
    fn detects_directory_with_only_files() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "random.txt");
        create_file(tmp.path(), "notes.md");

        let result = validate_project_path(tmp.path().to_str().unwrap(), &[]);

        match result {
            ValidationResult::NotAProject { .. } => {}
            other => panic!("Expected NotAProject, got {:?}", other),
        }
    }

    // ========================================
    // Dangerous path tests
    // ========================================

    #[test]
    fn warns_on_root() {
        let result = validate_project_path("/", &[]);

        match result {
            ValidationResult::DangerousPath { reason, .. } => {
                assert!(
                    reason.to_lowercase().contains("broad")
                        || reason.to_lowercase().contains("many")
                );
            }
            other => panic!("Expected DangerousPath, got {:?}", other),
        }
    }

    #[test]
    fn warns_on_home() {
        if let Some(home) = dirs::home_dir() {
            let result = validate_project_path(home.to_str().unwrap(), &[]);

            match result {
                ValidationResult::DangerousPath { .. } => {}
                // Home might also be NotAProject if it has no markers
                ValidationResult::NotAProject { .. } => {}
                other => panic!(
                    "Expected DangerousPath or NotAProject for home, got {:?}",
                    other
                ),
            }
        }
    }

    #[test]
    fn warns_on_tmp() {
        let result = validate_project_path("/tmp", &[]);

        match result {
            ValidationResult::DangerousPath { .. } => {}
            // /tmp might not exist or might be a project
            ValidationResult::PathNotFound { .. } => {}
            ValidationResult::NotAProject { .. } => {}
            other => panic!(
                "Expected DangerousPath, PathNotFound, or NotAProject, got {:?}",
                other
            ),
        }
    }

    // ========================================
    // Already tracked tests
    // ========================================

    #[test]
    fn detects_already_tracked_project() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        let path = tmp.path().to_str().unwrap().to_string();
        let pinned = vec![path.clone()];

        let result = validate_project_path(&path, &pinned);

        match result {
            ValidationResult::AlreadyTracked { name, .. } => {
                assert!(!name.is_empty(), "Should have project name");
            }
            other => panic!("Expected AlreadyTracked, got {:?}", other),
        }
    }

    #[test]
    fn not_tracked_when_not_in_pinned_list() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        // Different path in pinned list
        let pinned = vec!["/some/other/path".to_string()];

        let result = validate_project_path(tmp.path().to_str().unwrap(), &pinned);

        match result {
            ValidationResult::Valid { .. } => {}
            other => panic!("Expected Valid (not tracked), got {:?}", other),
        }
    }

    // ========================================
    // Path handling tests
    // ========================================

    #[test]
    fn handles_nonexistent_path() {
        let result = validate_project_path("/this/path/definitely/does/not/exist/abc123", &[]);

        match result {
            ValidationResult::PathNotFound { path } => {
                assert!(path.contains("abc123"));
            }
            other => panic!("Expected PathNotFound, got {:?}", other),
        }
    }

    #[test]
    fn normalizes_trailing_slashes() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        let path_with_slash = format!("{}/", tmp.path().display());
        let result = validate_project_path(&path_with_slash, &[]);

        match result {
            ValidationResult::Valid { path, .. } => {
                assert!(!path.ends_with('/'), "Path should not end with slash");
            }
            other => panic!("Expected Valid, got {:?}", other),
        }
    }

    #[test]
    fn handles_symlinks() {
        // This test creates a symlink and verifies it resolves correctly
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        // Create a symlink to the project
        let link_dir = create_test_dir();
        let link_path = link_dir.path().join("project-link");

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(tmp.path(), &link_path).expect("Failed to create symlink");

            let result = validate_project_path(link_path.to_str().unwrap(), &[]);

            match result {
                ValidationResult::Valid { .. } => {}
                other => panic!("Expected Valid for symlink, got {:?}", other),
            }
        }
    }

    // ========================================
    // Helper function tests
    // ========================================

    #[test]
    fn has_claude_md_returns_true_when_present() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        assert!(has_claude_md(tmp.path().to_str().unwrap()));
    }

    #[test]
    fn has_claude_md_returns_false_when_absent() {
        let tmp = create_test_dir();

        assert!(!has_claude_md(tmp.path().to_str().unwrap()));
    }

    #[test]
    fn has_any_project_marker_detects_git() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        assert!(has_any_project_marker(tmp.path().to_str().unwrap()));
    }

    #[test]
    fn has_any_project_marker_detects_package_json() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "package.json");

        assert!(has_any_project_marker(tmp.path().to_str().unwrap()));
    }

    #[test]
    fn has_any_project_marker_returns_false_when_empty() {
        let tmp = create_test_dir();

        assert!(!has_any_project_marker(tmp.path().to_str().unwrap()));
    }

    // ========================================
    // Package info extraction tests
    // ========================================

    #[test]
    fn extracts_name_from_package_json() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "package.json",
            r#"{"name": "@company/auth", "description": "Authentication library"}"#,
        );

        let info = extract_package_json_info(tmp.path().to_str().unwrap());

        assert!(info.is_some());
        let info = info.unwrap();
        assert_eq!(info.name, Some("@company/auth".to_string()));
        assert_eq!(info.description, Some("Authentication library".to_string()));
    }

    #[test]
    fn extracts_scripts_from_package_json() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "package.json",
            r#"{"name": "my-app", "scripts": {"build": "tsc", "test": "vitest"}}"#,
        );

        let info = extract_package_json_info(tmp.path().to_str().unwrap());

        assert!(info.is_some());
        let info = info.unwrap();
        assert!(info.scripts.contains(&"build".to_string()));
        assert!(info.scripts.contains(&"test".to_string()));
    }

    #[test]
    fn handles_missing_package_json() {
        let tmp = create_test_dir();

        let info = extract_package_json_info(tmp.path().to_str().unwrap());

        assert!(info.is_none());
    }

    #[test]
    fn handles_malformed_package_json() {
        let tmp = create_test_dir();
        create_file_with_content(tmp.path(), "package.json", "{ invalid json }");

        let info = extract_package_json_info(tmp.path().to_str().unwrap());

        assert!(info.is_none());
    }

    #[test]
    fn extracts_name_from_cargo_toml() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "Cargo.toml",
            r#"[package]
name = "my-crate"
description = "A useful Rust crate"
"#,
        );

        let info = extract_cargo_toml_info(tmp.path().to_str().unwrap());

        assert!(info.is_some());
        let info = info.unwrap();
        assert_eq!(info.name, Some("my-crate".to_string()));
        assert_eq!(info.description, Some("A useful Rust crate".to_string()));
    }

    #[test]
    fn handles_missing_cargo_toml() {
        let tmp = create_test_dir();

        let info = extract_cargo_toml_info(tmp.path().to_str().unwrap());

        assert!(info.is_none());
    }

    #[test]
    fn extracts_name_from_cargo_toml_with_single_quotes() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "Cargo.toml",
            r#"[package]
name = 'single-quoted-crate'
description = 'Uses single quotes'
"#,
        );

        let info = extract_cargo_toml_info(tmp.path().to_str().unwrap());

        assert!(info.is_some(), "Should parse single-quoted values");
        let info = info.unwrap();
        assert_eq!(info.name, Some("single-quoted-crate".to_string()));
        assert_eq!(info.description, Some("Uses single quotes".to_string()));
    }

    #[test]
    fn extracts_name_from_cargo_toml_with_no_spaces() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "Cargo.toml",
            r#"[package]
name="no-spaces"
"#,
        );

        let info = extract_cargo_toml_info(tmp.path().to_str().unwrap());

        assert!(info.is_some(), "Should parse name= with no spaces");
        let info = info.unwrap();
        assert_eq!(info.name, Some("no-spaces".to_string()));
    }

    // ========================================
    // CLAUDE.md generation tests
    // ========================================

    #[test]
    fn generates_basic_template() {
        let tmp = create_test_dir();

        let content = generate_claude_md_content(tmp.path().to_str().unwrap());

        assert!(!content.is_empty(), "Should generate some content");
        assert!(content.contains("#"), "Should have markdown heading");
    }

    #[test]
    fn generates_template_with_package_name() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "package.json",
            r#"{"name": "my-cool-app", "description": "A cool application"}"#,
        );

        let content = generate_claude_md_content(tmp.path().to_str().unwrap());

        assert!(
            content.contains("my-cool-app") || content.contains("cool"),
            "Should include package name or description. Content: {}",
            content
        );
    }

    #[test]
    fn generates_template_with_crate_name() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "Cargo.toml",
            r#"[package]
name = "my-rust-lib"
description = "A Rust library"
"#,
        );

        let content = generate_claude_md_content(tmp.path().to_str().unwrap());

        assert!(
            content.contains("my-rust-lib") || content.contains("Rust"),
            "Should include crate name. Content: {}",
            content
        );
    }

    // ========================================
    // CLAUDE.md creation tests
    // ========================================

    #[test]
    fn creates_claude_md_file() {
        let tmp = create_test_dir();

        let result = create_claude_md(tmp.path().to_str().unwrap());

        assert!(result.is_ok(), "Should succeed creating file");
        assert!(
            tmp.path().join("CLAUDE.md").exists(),
            "CLAUDE.md should exist"
        );

        let content = fs::read_to_string(tmp.path().join("CLAUDE.md")).unwrap();
        assert!(!content.is_empty(), "File should have content");
    }

    #[test]
    fn does_not_overwrite_existing() {
        let tmp = create_test_dir();
        create_file_with_content(
            tmp.path(),
            "CLAUDE.md",
            "# My custom content\n\nDon't overwrite!",
        );

        let _result = create_claude_md(tmp.path().to_str().unwrap());

        // Should either return error or silently skip
        let content = fs::read_to_string(tmp.path().join("CLAUDE.md")).unwrap();
        assert!(
            content.contains("My custom content"),
            "Should not overwrite existing content"
        );
    }

    #[test]
    fn handles_permission_denied() {
        // This test is platform-specific and may not work in all environments
        // Skip on non-Unix platforms
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let tmp = create_test_dir();

            // Make directory read-only
            let mut perms = fs::metadata(tmp.path()).unwrap().permissions();
            perms.set_mode(0o444);
            fs::set_permissions(tmp.path(), perms.clone()).unwrap();

            let result = create_claude_md(tmp.path().to_str().unwrap());

            // Restore permissions for cleanup
            perms.set_mode(0o755);
            let _ = fs::set_permissions(tmp.path(), perms);

            assert!(result.is_err(), "Should fail on read-only directory");
        }
    }
}
