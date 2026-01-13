use std::fs;
use std::path::Path;

use super::types::LockInfo;

fn compute_lock_hash(path: &str) -> String {
    format!("{:x}", md5::compute(path))
}

fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(not(unix))]
    {
        false
    }
}

fn read_lock_info(lock_dir: &Path) -> Option<LockInfo> {
    let pid_path = lock_dir.join("pid");
    let meta_path = lock_dir.join("meta.json");

    let pid_str = fs::read_to_string(&pid_path).ok()?;
    let pid: u32 = pid_str.trim().parse().ok()?;

    let meta_content = fs::read_to_string(&meta_path).ok()?;
    let meta: serde_json::Value = serde_json::from_str(&meta_content).ok()?;

    Some(LockInfo {
        pid,
        path: meta.get("path")?.as_str()?.to_string(),
        started: meta.get("started")?.as_str()?.to_string(),
    })
}

fn check_lock_for_path(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    let hash = compute_lock_hash(project_path);
    let lock_dir = lock_base.join(format!("{}.lock", hash));

    if !lock_dir.is_dir() {
        return None;
    }

    let info = read_lock_info(&lock_dir)?;

    if !is_pid_alive(info.pid) {
        return None;
    }

    Some(info)
}

pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    if check_lock_for_path(lock_base, project_path).is_some() {
        return true;
    }

    let mut current = project_path;
    while let Some(parent) = Path::new(current).parent() {
        let parent_str = parent.to_string_lossy();
        if parent_str.is_empty() || parent_str == "/" {
            break;
        }
        if check_lock_for_path(lock_base, &parent_str).is_some() {
            return true;
        }
        current = parent.to_str().unwrap_or("");
    }

    false
}

pub fn get_lock_info(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    if let Some(info) = check_lock_for_path(lock_base, project_path) {
        return Some(info);
    }

    let mut current = project_path;
    while let Some(parent) = Path::new(current).parent() {
        let parent_str = parent.to_string_lossy();
        if parent_str.is_empty() || parent_str == "/" {
            break;
        }
        if let Some(info) = check_lock_for_path(lock_base, &parent_str) {
            return Some(info);
        }
        current = parent.to_str().unwrap_or("");
    }

    None
}

pub fn find_child_lock(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    let prefix = if project_path.ends_with('/') {
        project_path.to_string()
    } else {
        format!("{}/", project_path)
    };

    let entries = fs::read_dir(lock_base).ok()?;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                if is_pid_alive(info.pid) && info.path.starts_with(&prefix) {
                    return Some(info);
                }
            }
        }
    }

    None
}

#[cfg(test)]
pub mod tests_helper {
    use super::compute_lock_hash;
    use std::fs;
    use std::path::Path;

    pub fn create_lock(lock_base: &Path, pid: u32, path: &str) {
        let hash = compute_lock_hash(path);
        let lock_dir = lock_base.join(format!("{}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();
        fs::write(
            lock_dir.join("meta.json"),
            format!(r#"{{"pid": {}, "path": "{}", "started": "2024-01-01T00:00:00Z"}}"#, pid, path),
        )
        .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::tests_helper::create_lock;
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_no_lock_dir_means_not_running() {
        let temp = tempdir().unwrap();
        assert!(!is_session_running(temp.path(), "/some/project"));
    }

    #[test]
    fn test_lock_with_dead_pid_means_not_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), 99999999, "/project");
        assert!(!is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_lock_with_live_pid_means_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        assert!(is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_child_project_inherits_parent_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        assert!(is_session_running(temp.path(), "/parent/child"));
    }

    #[test]
    fn test_parent_does_not_inherit_child_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent/child");
        assert!(!is_session_running(temp.path(), "/parent"));
    }

    #[test]
    fn test_get_lock_info_returns_info_when_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let info = get_lock_info(temp.path(), "/project").unwrap();
        assert_eq!(info.pid, std::process::id());
        assert_eq!(info.path, "/project");
    }

    #[test]
    fn test_get_lock_info_returns_none_when_not_running() {
        let temp = tempdir().unwrap();
        assert!(get_lock_info(temp.path(), "/project").is_none());
    }

    #[test]
    fn test_get_lock_info_inherits_parent_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        let info = get_lock_info(temp.path(), "/parent/child").unwrap();
        assert_eq!(info.path, "/parent");
    }
}
