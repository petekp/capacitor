//! Project boundary detection for activity attribution.
//!
//! Walks up from a file path to find the nearest project boundary,
//! identified by markers like CLAUDE.md, .git, package.json, etc.
//!
//! This enables accurate attribution of file activity to projects,
//! especially in monorepo scenarios where Claude runs from the repo
//! root but edits files in specific packages.
//! Boundary detection is intentionally conservative to avoid mis-attribution.

use std::path::Path;

/// Maximum depth to walk up when searching for boundaries.
/// Prevents runaway traversal in deeply nested or misconfigured paths.
pub const MAX_BOUNDARY_DEPTH: usize = 20;

/// Directories that should be skipped during boundary detection.
/// These are typically generated/vendored code, not project roots.
pub const IGNORED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "vendor",
    ".git",
    "__pycache__",
    "target",
    "dist",
    "build",
    ".next",
    ".output",
    "venv",
    ".venv",
    "env",
    ".turbo",
    ".cache",
];

/// Project markers in priority order.
/// Lower number = higher priority.
/// CLAUDE.md is explicit intent, .git is repo boundary, others are package markers.
pub const PROJECT_MARKERS: &[(&str, u8)] = &[
    ("CLAUDE.md", 1),    // Priority 1 (highest) - explicit project marker
    (".git", 2),         // Priority 2 - repository root
    ("package.json", 3), // Priority 3 - package markers
    ("Cargo.toml", 3),
    ("pyproject.toml", 3),
    ("go.mod", 3),
    ("pubspec.yaml", 3), // Dart/Flutter
    ("Project.toml", 3), // Julia
    ("deno.json", 3),    // Deno
    ("Makefile", 4),     // Priority 4 (lowest) - build markers
    ("CMakeLists.txt", 4),
];

/// Paths that are too broad to be meaningful project boundaries.
/// Pinning these would encompass many unrelated projects.
pub const DANGEROUS_PATHS: &[&str] = &["/", "/Users", "/home", "/var", "/tmp", "/opt"];

/// Represents a detected project boundary.
#[derive(Debug, Clone, PartialEq)]
pub struct ProjectBoundary {
    /// Absolute path to the project root
    pub path: String,
    /// The marker file/directory that identified this as a project
    pub marker: String,
    /// Priority of the marker (lower = higher priority)
    pub priority: u8,
}

/// Finds the nearest project boundary by walking up from the given path.
///
/// # Arguments
/// * `file_path` - Path to a file or directory to start from
///
/// # Returns
/// * `Some(ProjectBoundary)` if a boundary is found
/// * `None` if no boundary is found within MAX_BOUNDARY_DEPTH
///
/// # Algorithm
/// 1. Start from the parent of the given path (or the path itself if it's a directory)
/// 2. Walk up, checking for markers at each level
/// 3. Track the highest-priority boundary found so far
/// 4. When we encounter an ignored directory, discard any boundary found so far
///    (it was inside the ignored subtree)
/// 5. CLAUDE.md at any level (outside ignored dirs) immediately wins (priority 1)
/// 6. Otherwise, return the nearest boundary found
/// 7. Stop at root, home directory, or max depth
pub fn find_project_boundary(file_path: &str) -> Option<ProjectBoundary> {
    let path = Path::new(file_path);

    // If path doesn't exist, we can't traverse it
    if !path.exists() {
        return None;
    }

    // Start from the path itself if it's a directory, otherwise its parent
    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()?.to_path_buf()
    };

    let mut current = Some(start);
    let mut depth = 0;
    let mut best_boundary: Option<ProjectBoundary> = None;

    // Get home directory for stopping condition
    let home_dir = dirs::home_dir();

    while let Some(dir) = current {
        // Stop conditions
        if depth >= MAX_BOUNDARY_DEPTH {
            break;
        }

        // Check if this directory is ignored (node_modules, vendor, etc.)
        // If so, discard any boundary we found so far (it was inside the ignored subtree)
        // and continue walking up
        if let Some(dir_name) = dir.file_name().and_then(|n| n.to_str()) {
            if is_ignored_directory(dir_name) {
                // Discard any boundary found so far - it was inside this ignored directory
                best_boundary = None;
                // Continue walking up to find boundaries outside the ignored subtree
                current = dir.parent().map(|p| p.to_path_buf());
                depth += 1;
                continue;
            }
        }

        // Check for markers at this level, in priority order
        for (marker, priority) in PROJECT_MARKERS {
            if has_marker(&dir, marker) {
                let boundary = ProjectBoundary {
                    path: dir.to_string_lossy().to_string(),
                    marker: marker.to_string(),
                    priority: *priority,
                };

                // CLAUDE.md (priority 1) immediately wins - it's explicit intent
                if *priority == 1 {
                    return Some(boundary);
                }

                // Track the best (lowest priority number = highest priority)
                // Prefer nearer boundaries at same priority level
                match &best_boundary {
                    None => best_boundary = Some(boundary),
                    Some(existing) if boundary.priority < existing.priority => {
                        best_boundary = Some(boundary);
                    }
                    _ => {}
                }

                // Found a marker at this level, no need to check lower priority markers
                break;
            }
        }

        // Stop at home directory
        if let Some(ref home) = home_dir {
            if dir == *home {
                break;
            }
        }

        // Move to parent
        current = dir.parent().map(|p| p.to_path_buf());
        depth += 1;
    }

    best_boundary
}

/// Checks if a directory name should be skipped during boundary detection.
#[must_use]
pub fn is_ignored_directory(name: &str) -> bool {
    IGNORED_DIRECTORIES.contains(&name)
}

/// Checks if a path is too broad to be a meaningful project boundary.
///
/// # Returns
/// * `Some(reason)` if the path is dangerous, with an explanation
/// * `None` if the path is safe
pub fn is_dangerous_path(path: &str) -> Option<String> {
    // Normalize the path for comparison, handling root specially
    let trimmed = path.trim_end_matches('/');
    let normalized = if trimmed.is_empty() { "/" } else { trimmed };

    // Check against explicit dangerous paths
    for dangerous in DANGEROUS_PATHS {
        if normalized == *dangerous {
            return Some(format!(
                "Path '{}' is too broad and would encompass many projects",
                path
            ));
        }
    }

    // Check if it's a home directory
    if let Some(home) = dirs::home_dir() {
        if normalized == home.to_string_lossy() {
            return Some("Home directory is too broad to be a project".to_string());
        }
    }

    // Check if it's directly under /Users or /home (a user's root)
    if normalized.starts_with("/Users/") || normalized.starts_with("/home/") {
        let part_count = normalized.split('/').filter(|s| !s.is_empty()).count();
        if part_count == 2 {
            return Some(format!("User home directory '{}' is too broad", path));
        }
    }

    None
}

/// Resolves a path to its canonical form.
/// - Expands ~ to home directory
/// - Resolves symlinks
/// - Normalizes . and ..
/// - Removes trailing slashes
pub fn canonicalize_path(path: &str) -> std::io::Result<String> {
    // Handle tilde expansion
    let expanded = if let Some(stripped) = path.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            home.join(stripped).to_string_lossy().to_string()
        } else {
            path.to_string()
        }
    } else if path == "~" {
        if let Some(home) = dirs::home_dir() {
            home.to_string_lossy().to_string()
        } else {
            path.to_string()
        }
    } else {
        path.to_string()
    };

    // Canonicalize (resolves symlinks, normalizes . and ..)
    let canonical = std::fs::canonicalize(&expanded)?;

    // Convert to string and remove trailing slash
    let result = canonical.to_string_lossy().to_string();
    Ok(result.trim_end_matches('/').to_string())
}

/// Normalizes a path string for comparison.
/// - Removes trailing slashes (except for root "/")
/// - Does NOT resolve symlinks or check filesystem
///
/// Use this for comparing paths that may come from different sources
/// with inconsistent formatting.
pub fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Checks if a path has a specific marker file or directory.
fn has_marker(dir: &Path, marker: &str) -> bool {
    dir.join(marker).exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ========================================
    // Helper functions for tests
    // ========================================

    fn create_test_dir() -> TempDir {
        TempDir::new().expect("Failed to create temp dir")
    }

    fn create_file(dir: &Path, name: &str) {
        fs::write(dir.join(name), "").expect("Failed to create file");
    }

    fn create_dir(dir: &Path, name: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        fs::create_dir_all(&path).expect("Failed to create dir");
        path
    }

    // ========================================
    // Basic boundary detection tests
    // ========================================

    #[test]
    fn finds_claude_md_as_boundary() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        let file = tmp.path().join("src/main.rs");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "main.rs");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some(), "Should find CLAUDE.md boundary");
        let boundary = result.unwrap();
        assert_eq!(boundary.path, tmp.path().to_string_lossy());
        assert_eq!(boundary.marker, "CLAUDE.md");
        assert_eq!(boundary.priority, 1);
    }

    #[test]
    fn finds_git_directory_as_boundary() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");
        let file = tmp.path().join("src/main.rs");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "main.rs");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some(), "Should find .git boundary");
        let boundary = result.unwrap();
        assert_eq!(boundary.marker, ".git");
        assert_eq!(boundary.priority, 2);
    }

    #[test]
    fn finds_package_json_as_boundary() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "package.json");
        let file = tmp.path().join("src/index.ts");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "index.ts");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some(), "Should find package.json boundary");
        let boundary = result.unwrap();
        assert_eq!(boundary.marker, "package.json");
        assert_eq!(boundary.priority, 3);
    }

    #[test]
    fn finds_cargo_toml_as_boundary() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "Cargo.toml");
        let file = tmp.path().join("src/lib.rs");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "lib.rs");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some(), "Should find Cargo.toml boundary");
        let boundary = result.unwrap();
        assert_eq!(boundary.marker, "Cargo.toml");
        assert_eq!(boundary.priority, 3);
    }

    // ========================================
    // Priority tests
    // ========================================

    #[test]
    fn claude_md_takes_priority_over_git() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_dir(tmp.path(), ".git");
        let file = tmp.path().join("src/main.rs");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "main.rs");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        assert_eq!(
            boundary.marker, "CLAUDE.md",
            "CLAUDE.md should have priority over .git"
        );
        assert_eq!(boundary.priority, 1);
    }

    #[test]
    fn git_takes_priority_over_package_json() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");
        create_file(tmp.path(), "package.json");
        let file = tmp.path().join("src/index.ts");
        create_dir(tmp.path(), "src");
        create_file(tmp.path().join("src").as_path(), "index.ts");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        assert_eq!(
            boundary.marker, ".git",
            ".git should have priority over package.json"
        );
        assert_eq!(boundary.priority, 2);
    }

    #[test]
    fn nearest_high_priority_marker_wins() {
        // Monorepo scenario:
        // /monorepo/.git
        // /monorepo/packages/auth/CLAUDE.md  <- should win
        // /monorepo/packages/auth/src/login.ts  <- file being edited
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        let auth_dir = create_dir(tmp.path(), "packages/auth");
        create_file(&auth_dir, "CLAUDE.md");

        let src_dir = create_dir(&auth_dir, "src");
        create_file(&src_dir, "login.ts");

        let file = src_dir.join("login.ts");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        assert_eq!(boundary.marker, "CLAUDE.md");
        assert_eq!(boundary.path, auth_dir.to_string_lossy());
    }

    // ========================================
    // Walking behavior tests
    // ========================================

    #[test]
    fn walks_up_from_deeply_nested_file() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        // Create deep nesting: a/b/c/d/e/file.txt
        let deep_dir = create_dir(tmp.path(), "a/b/c/d/e");
        create_file(&deep_dir, "file.txt");

        let file = deep_dir.join("file.txt");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(
            result.is_some(),
            "Should find boundary from deeply nested file"
        );
        let boundary = result.unwrap();
        assert_eq!(boundary.path, tmp.path().to_string_lossy());
    }

    #[test]
    fn stops_at_max_depth() {
        // Create a structure deeper than MAX_BOUNDARY_DEPTH without any markers
        let tmp = create_test_dir();

        let mut current = tmp.path().to_path_buf();
        for i in 0..(MAX_BOUNDARY_DEPTH + 5) {
            current = current.join(format!("level{}", i));
        }
        fs::create_dir_all(&current).expect("Failed to create deep dirs");
        create_file(&current, "file.txt");

        let file = current.join("file.txt");

        let result = find_project_boundary(file.to_str().unwrap());

        // Should return None because no marker found within MAX_BOUNDARY_DEPTH
        assert!(
            result.is_none(),
            "Should not find boundary beyond max depth"
        );
    }

    #[test]
    fn returns_none_for_no_markers() {
        let tmp = create_test_dir();
        let src_dir = create_dir(tmp.path(), "src");
        create_file(&src_dir, "file.txt");

        let file = src_dir.join("file.txt");

        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_none(), "Should return None when no markers found");
    }

    // ========================================
    // Ignored directory tests
    // ========================================

    #[test]
    fn skips_node_modules() {
        assert!(is_ignored_directory("node_modules"));
    }

    #[test]
    fn skips_vendor() {
        assert!(is_ignored_directory("vendor"));
    }

    #[test]
    fn skips_target() {
        assert!(is_ignored_directory("target"));
    }

    #[test]
    fn skips_dot_git() {
        assert!(is_ignored_directory(".git"));
    }

    #[test]
    fn does_not_skip_src() {
        assert!(!is_ignored_directory("src"));
    }

    #[test]
    fn does_not_skip_packages() {
        assert!(!is_ignored_directory("packages"));
    }

    #[test]
    fn boundary_detection_skips_node_modules_marker() {
        // Even if there's a package.json inside node_modules, we should skip it
        // and find the project root instead
        let tmp = create_test_dir();
        create_file(tmp.path(), "package.json");

        let node_modules = create_dir(tmp.path(), "node_modules");
        let some_package = create_dir(&node_modules, "some-package");
        create_file(&some_package, "package.json");

        let file_in_package = some_package.join("index.js");
        create_file(&some_package, "index.js");

        let result = find_project_boundary(file_in_package.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        // Should find the root package.json, not the one in node_modules
        assert_eq!(boundary.path, tmp.path().to_string_lossy());
    }

    // ========================================
    // Edge case tests
    // ========================================

    #[test]
    fn handles_nonexistent_path() {
        let result = find_project_boundary("/definitely/does/not/exist/file.txt");
        assert!(result.is_none());
    }

    #[test]
    fn handles_directory_as_input() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        let src_dir = create_dir(tmp.path(), "src");

        // Pass directory instead of file
        let result = find_project_boundary(src_dir.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        assert_eq!(boundary.path, tmp.path().to_string_lossy());
    }

    #[test]
    fn handles_file_at_project_root() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");
        create_file(tmp.path(), "README.md");

        let result = find_project_boundary(tmp.path().join("README.md").to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        assert_eq!(boundary.path, tmp.path().to_string_lossy());
    }

    #[test]
    fn handles_monorepo_nested_packages() {
        // Realistic monorepo structure:
        // /monorepo/
        //   .git/
        //   CLAUDE.md
        //   packages/
        //     auth/
        //       CLAUDE.md
        //       package.json
        //       src/login.ts  <- editing this
        //     api/
        //       CLAUDE.md
        //       package.json
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");
        create_file(tmp.path(), "CLAUDE.md");

        let packages = create_dir(tmp.path(), "packages");

        let auth = create_dir(&packages, "auth");
        create_file(&auth, "CLAUDE.md");
        create_file(&auth, "package.json");
        let auth_src = create_dir(&auth, "src");
        create_file(&auth_src, "login.ts");

        let api = create_dir(&packages, "api");
        create_file(&api, "CLAUDE.md");
        create_file(&api, "package.json");

        // Edit file in auth package
        let auth_file = auth_src.join("login.ts");
        let result = find_project_boundary(auth_file.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        // Should find auth's CLAUDE.md, not the monorepo root
        assert_eq!(boundary.path, auth.to_string_lossy());
        assert_eq!(boundary.marker, "CLAUDE.md");
    }

    #[test]
    fn handles_git_submodule() {
        // Submodule has its own .git (as a file pointing to ../.git/modules/*)
        // but for simplicity we treat .git directory presence as boundary
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        let submodule = create_dir(tmp.path(), "external/library");
        create_dir(&submodule, ".git"); // Submodule .git
        create_file(&submodule, "lib.rs");

        let file = submodule.join("lib.rs");
        let result = find_project_boundary(file.to_str().unwrap());

        assert!(result.is_some());
        let boundary = result.unwrap();
        // Should find the submodule's .git, not the parent
        assert_eq!(boundary.path, submodule.to_string_lossy());
    }

    // ========================================
    // Dangerous path tests
    // ========================================

    #[test]
    fn detects_root_as_dangerous() {
        let result = is_dangerous_path("/");
        assert!(result.is_some());
        assert!(result.unwrap().contains("too broad"));
    }

    #[test]
    fn detects_users_as_dangerous() {
        let result = is_dangerous_path("/Users");
        assert!(result.is_some());
    }

    #[test]
    fn detects_home_as_dangerous() {
        let result = is_dangerous_path("/home");
        assert!(result.is_some());
    }

    #[test]
    fn detects_tmp_as_dangerous() {
        let result = is_dangerous_path("/tmp");
        assert!(result.is_some());
    }

    #[test]
    fn normal_project_path_is_safe() {
        let result = is_dangerous_path("/Users/pete/Code/my-project");
        assert!(result.is_none(), "Normal project path should be safe");
    }

    #[test]
    fn trailing_slash_handled_in_dangerous_check() {
        let result = is_dangerous_path("/Users/");
        assert!(result.is_some());
    }

    // ========================================
    // Path canonicalization tests
    // ========================================

    #[test]
    fn canonicalize_removes_trailing_slash() {
        let tmp = create_test_dir();
        let path_with_slash = format!("{}/", tmp.path().display());

        let result = canonicalize_path(&path_with_slash);

        assert!(result.is_ok());
        assert!(!result.unwrap().ends_with('/'));
    }

    #[test]
    fn canonicalize_expands_tilde() {
        // This test only works if we have a home directory
        if let Some(home) = dirs::home_dir() {
            // We can't easily test ~ expansion without a real path
            // but we can test the logic by checking if ~/. resolves to home
            let result = canonicalize_path("~");
            if result.is_ok() {
                assert_eq!(
                    result.unwrap(),
                    home.to_string_lossy().trim_end_matches('/')
                );
            }
        }
    }

    #[test]
    fn canonicalize_handles_nonexistent_path() {
        let result = canonicalize_path("/this/path/definitely/does/not/exist");
        assert!(result.is_err());
    }

    // ========================================
    // Path normalization tests
    // ========================================

    #[test]
    fn normalize_path_removes_trailing_slash() {
        assert_eq!(
            normalize_path("/Users/pete/Code/project/"),
            "/Users/pete/Code/project"
        );
    }

    #[test]
    fn normalize_path_removes_multiple_trailing_slashes() {
        assert_eq!(
            normalize_path("/Users/pete/Code/project///"),
            "/Users/pete/Code/project"
        );
    }

    #[test]
    fn normalize_path_preserves_root() {
        assert_eq!(normalize_path("/"), "/");
    }

    #[test]
    fn normalize_path_handles_only_slashes() {
        assert_eq!(normalize_path("///"), "/");
    }

    #[test]
    fn normalize_path_preserves_normal_path() {
        assert_eq!(normalize_path("/Users/pete/Code"), "/Users/pete/Code");
    }

    // ========================================
    // Helper function tests
    // ========================================

    /// Gets the priority of a marker, or None if not a known marker.
    /// Test-only helper for verifying constant values.
    fn marker_priority(marker: &str) -> Option<u8> {
        PROJECT_MARKERS
            .iter()
            .find(|(m, _)| *m == marker)
            .map(|(_, p)| *p)
    }

    #[test]
    fn marker_priority_returns_correct_values() {
        assert_eq!(marker_priority("CLAUDE.md"), Some(1));
        assert_eq!(marker_priority(".git"), Some(2));
        assert_eq!(marker_priority("package.json"), Some(3));
        assert_eq!(marker_priority("Cargo.toml"), Some(3));
        assert_eq!(marker_priority("Makefile"), Some(4));
        assert_eq!(marker_priority("unknown.txt"), None);
    }

    #[test]
    fn has_marker_detects_files() {
        let tmp = create_test_dir();
        create_file(tmp.path(), "CLAUDE.md");

        assert!(has_marker(tmp.path(), "CLAUDE.md"));
        assert!(!has_marker(tmp.path(), "package.json"));
    }

    #[test]
    fn has_marker_detects_directories() {
        let tmp = create_test_dir();
        create_dir(tmp.path(), ".git");

        assert!(has_marker(tmp.path(), ".git"));
        assert!(!has_marker(tmp.path(), ".svn"));
    }
}
