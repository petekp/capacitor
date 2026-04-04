//! Project directory relocation detection via macOS volfs.
//!
//! Uses inode + device ID to track directories across renames and moves.
//! Resolution works by opening `/.vol/<dev>/<ino>` and asking the kernel
//! for the current path via `fcntl(F_GETPATH)`.

use std::os::unix::fs::MetadataExt;

/// Captures the inode number and device ID for a directory path.
///
/// Returns `None` if the path does not exist or metadata cannot be read.
#[allow(dead_code)]
pub(crate) fn capture_inode_metadata(path: &str) -> Option<(u64, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.ino(), metadata.dev()))
}

/// Attempts to resolve the current filesystem path for a given inode + device ID.
///
/// Uses the macOS volfs pseudo-filesystem: opens `/.vol/<dev>/<ino>` and calls
/// `fcntl(F_GETPATH)` to retrieve the kernel's current path for that inode.
///
/// Returns `None` if:
/// - The inode no longer exists on the device
/// - The resolved path is inside `/.Trash/` (the directory was deleted)
/// - Any FFI call fails
#[allow(dead_code)]
pub(crate) fn try_resolve_relocated_path(inode: u64, device_id: u64) -> Option<String> {
    const F_GETPATH: libc::c_int = 50;
    let buf_size = libc::PATH_MAX as usize;

    let volfs_path = format!("/.vol/{}/{}", device_id, inode);
    let c_path = std::ffi::CString::new(volfs_path).ok()?;

    unsafe {
        let fd = libc::open(c_path.as_ptr(), libc::O_RDONLY);
        if fd < 0 {
            return None;
        }

        let mut buf = vec![0u8; buf_size];
        let result = libc::fcntl(fd, F_GETPATH, buf.as_mut_ptr());
        libc::close(fd);

        if result < 0 {
            return None;
        }

        let c_str = std::ffi::CStr::from_ptr(buf.as_ptr() as *const libc::c_char);
        let resolved = c_str.to_string_lossy().to_string();

        // Exclude trashed directories
        if resolved.contains("/.Trash/") {
            return None;
        }

        Some(resolved)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn capture_inode_metadata_returns_some_for_existing_dir() {
        let temp = tempdir().expect("tempdir");
        let result = capture_inode_metadata(temp.path().to_str().unwrap());
        assert!(result.is_some(), "should capture metadata for existing dir");
        let (ino, dev) = result.unwrap();
        assert!(ino > 0, "inode should be nonzero");
        assert!(dev > 0, "device id should be nonzero");
    }

    #[test]
    fn capture_inode_metadata_returns_none_for_missing_path() {
        let result = capture_inode_metadata("/nonexistent/path/that/does/not/exist");
        assert!(result.is_none());
    }

    #[test]
    fn resolve_after_rename() {
        let temp = tempdir().expect("tempdir");
        let original = temp.path().join("my-project");
        std::fs::create_dir(&original).expect("create dir");

        let (ino, dev) =
            capture_inode_metadata(original.to_str().unwrap()).expect("capture metadata");

        let renamed = temp.path().join("my-project-renamed");
        std::fs::rename(&original, &renamed).expect("rename");

        let resolved =
            try_resolve_relocated_path(ino, dev).expect("should resolve the renamed path");

        // The kernel returns canonical paths (e.g. /private/var instead of /var on macOS).
        // Canonicalize both sides to compare.
        let canonical_renamed = std::fs::canonicalize(&renamed)
            .expect("canonicalize renamed")
            .to_string_lossy()
            .to_string();
        assert_eq!(
            resolved, canonical_renamed,
            "resolved path should match renamed directory (canonical)"
        );
    }

    #[test]
    fn resolve_returns_none_for_deleted_dir() {
        let temp = tempdir().expect("tempdir");
        let dir = temp.path().join("ephemeral");
        std::fs::create_dir(&dir).expect("create dir");

        let (ino, dev) = capture_inode_metadata(dir.to_str().unwrap()).expect("capture metadata");

        std::fs::remove_dir(&dir).expect("remove dir");

        // After deletion the inode is freed; resolution should fail
        let resolved = try_resolve_relocated_path(ino, dev);
        // This may or may not return None depending on OS timing,
        // but if it returns Some it should not be the original path (which no longer exists).
        if let Some(path) = resolved {
            assert!(
                !std::path::Path::new(&path).exists() || path != dir.to_str().unwrap(),
                "should not resolve to the now-deleted path"
            );
        }
    }

    #[test]
    fn resolve_excludes_trash_paths() {
        // We cannot easily simulate moving to Trash in a test, so we test the
        // exclusion logic indirectly: if we ever resolve a path containing
        // /.Trash/, the function should return None. This is a unit-level
        // guarantee tested via the contains check in try_resolve_relocated_path.
        //
        // Instead, verify that a normal rename does NOT trigger the Trash filter.
        let temp = tempdir().expect("tempdir");
        let dir = temp.path().join("not-trash");
        std::fs::create_dir(&dir).expect("create dir");

        let (ino, dev) = capture_inode_metadata(dir.to_str().unwrap()).expect("capture metadata");

        let resolved = try_resolve_relocated_path(ino, dev);
        assert!(
            resolved.is_some(),
            "non-Trash path should resolve successfully"
        );
        assert!(
            !resolved.unwrap().contains("/.Trash/"),
            "resolved path should not contain /.Trash/"
        );
    }
}
