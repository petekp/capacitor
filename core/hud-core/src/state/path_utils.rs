//! Path normalization utilities for consistent path comparison.
//!
//! Handles platform-specific quirks:
//! - macOS case-insensitive filesystem
//! - Symlink resolution
//! - Trailing slash normalization

use std::path::Path;

/// Normalizes a path for consistent comparison across the codebase.
///
/// This function handles:
/// 1. Trailing slash removal (except for root "/")
/// 2. Case normalization on macOS (case-insensitive filesystem)
/// 3. Symlink resolution when the path exists
///
/// # Platform Behavior
///
/// - **macOS**: Paths are lowercased because HFS+/APFS are case-insensitive by default.
///   `/Users/Pete/Project` and `/users/pete/project` refer to the same directory.
/// - **Linux**: Paths are case-sensitive, no lowercasing is applied.
///
/// # Symlink Handling
///
/// When the path exists on disk, symlinks are resolved to their canonical form.
/// This ensures that `/link` and `/real` match if `/link -> /real`.
/// If the path doesn't exist, the original path is returned (without resolution).
///
/// # Examples
///
/// ```ignore
/// // Trailing slash removal
/// normalize_path_for_comparison("/project/") -> "/project"
///
/// // Root is preserved
/// normalize_path_for_comparison("/") -> "/"
///
/// // macOS case normalization
/// normalize_path_for_comparison("/Users/Pete/Code") -> "/users/pete/code" // on macOS
/// normalize_path_for_comparison("/Users/Pete/Code") -> "/Users/Pete/Code" // on Linux
/// ```
pub fn normalize_path_for_comparison(path: &str) -> String {
    // Step 1: Resolve symlinks if the path exists
    let resolved = resolve_symlinks(path);

    // Step 2: Strip trailing slashes
    let trimmed = strip_trailing_slashes(&resolved);

    // Step 3: Apply case normalization on macOS
    apply_case_normalization(&trimmed)
}

/// Normalizes a path for hashing (lock directory names).
///
/// Similar to `normalize_path_for_comparison`, but specifically for generating
/// consistent hash inputs. Two paths that should share a lock will produce
/// the same normalized output.
pub fn normalize_path_for_hashing(path: &str) -> String {
    normalize_path_for_comparison(path)
}

/// Simple path normalization without filesystem access.
///
/// Use this for basic normalization when:
/// - You don't need symlink resolution
/// - You're working with paths that may not exist
/// - Performance is critical (no filesystem calls)
///
/// Still applies case normalization on macOS and trailing slash removal.
#[cfg(test)]
fn normalize_path_simple(path: &str) -> String {
    let trimmed = strip_trailing_slashes(path);
    apply_case_normalization(&trimmed)
}

/// Strips trailing slashes from a path, preserving root "/".
fn strip_trailing_slashes(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Resolves symlinks if the path exists on disk.
fn resolve_symlinks(path: &str) -> String {
    let path_obj = Path::new(path);

    // Only resolve if the path exists - canonicalize fails on non-existent paths
    if path_obj.exists() {
        if let Ok(canonical) = path_obj.canonicalize() {
            return canonical.to_string_lossy().to_string();
        }
    }

    path.to_string()
}

/// Applies case normalization based on platform.
///
/// macOS uses case-insensitive filesystem by default (HFS+/APFS),
/// so we lowercase paths for consistent comparison.
fn apply_case_normalization(path: &str) -> String {
    #[cfg(target_os = "macos")]
    {
        path.to_lowercase()
    }
    #[cfg(not(target_os = "macos"))]
    {
        path.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_trailing_slash() {
        assert_eq!(normalize_path_simple("/project/"), "/project");
        assert_eq!(normalize_path_simple("/project//"), "/project");
    }

    #[test]
    fn preserves_root() {
        assert_eq!(normalize_path_simple("/"), "/");
        assert_eq!(normalize_path_simple("//"), "/");
        assert_eq!(normalize_path_simple("///"), "/");
    }

    #[test]
    fn normalizes_regular_paths() {
        let result = normalize_path_simple("/Users/test/Code/project");
        #[cfg(target_os = "macos")]
        assert_eq!(result, "/users/test/code/project");
        #[cfg(not(target_os = "macos"))]
        assert_eq!(result, "/Users/test/Code/project");
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn case_insensitive_on_macos() {
        // These should all normalize to the same value on macOS
        let upper = normalize_path_simple("/Users/Pete/Project");
        let lower = normalize_path_simple("/users/pete/project");
        let mixed = normalize_path_simple("/USERS/pEtE/pRoJeCt");

        assert_eq!(upper, lower);
        assert_eq!(lower, mixed);
    }

    #[test]
    fn resolves_existing_symlinks() {
        use std::fs;
        use tempfile::tempdir;

        let temp = tempdir().unwrap();
        let real_dir = temp.path().join("real");
        let link_path = temp.path().join("link");

        fs::create_dir(&real_dir).unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink(&real_dir, &link_path).unwrap();

        #[cfg(unix)]
        {
            let real_normalized = normalize_path_for_comparison(real_dir.to_str().unwrap());
            let link_normalized = normalize_path_for_comparison(link_path.to_str().unwrap());

            // Both should resolve to the same canonical path
            assert_eq!(real_normalized, link_normalized);
        }
    }

    #[test]
    fn handles_nonexistent_paths() {
        // Should not panic on non-existent paths
        let result = normalize_path_for_comparison("/this/path/does/not/exist/12345");
        #[cfg(target_os = "macos")]
        assert_eq!(result, "/this/path/does/not/exist/12345");
        #[cfg(not(target_os = "macos"))]
        assert_eq!(result, "/this/path/does/not/exist/12345");
    }

    #[test]
    fn hashing_normalization_consistent() {
        let path1 = "/Users/Test/Project/";
        let path2 = "/users/test/project";

        let hash1 = normalize_path_for_hashing(path1);
        let hash2 = normalize_path_for_hashing(path2);

        #[cfg(target_os = "macos")]
        assert_eq!(
            hash1, hash2,
            "Same directory with different casing should hash the same on macOS"
        );
    }
}
